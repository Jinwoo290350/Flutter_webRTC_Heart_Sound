import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../config/webrtc_config.dart';
import '../config/firebase_config.dart';
import '../models/call_state.dart';
import 'signaling_service.dart';
import '_audio_js_stub.dart'
    if (dart.library.js_interop) '_audio_js_web.dart' as audio_js;

/// WebRTCService — จัดการ PeerConnection + dual-channel audio
class WebRTCService extends ChangeNotifier {
  // ==================== State ====================

  CallState _callState = CallState.idle;
  CallState get callState => _callState;

  String? _roomId;
  String? get roomId => _roomId;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  // ==================== WebRTC Objects ====================

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;       // voice + video (filter ON)
  MediaStream? _stethStream;       // stethoscope (filter OFF) — Phase 2
  MediaStream? _remoteStream;
  RTCDataChannel? _pcmChannel;     // raw PCM heart sound DataChannel
  RTCDataChannel? _controlChannel; // peer-to-peer mute/control commands
  String? _myRole;                 // 'patient' (caller) | 'doctor' (callee)

  // ==================== Native PCM Capture (Patient side) ====================
  AudioRecorder? _pcmRecorder;
  StreamSubscription<Uint8List>? _pcmStreamSub;

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  RTCDataChannel? get pcmChannel => _pcmChannel;
  RTCDataChannelState? get pcmChannelState => _pcmChannel?.state;
  bool get hasStethoscope => _stethStream != null;

  final SignalingService _signaling = SignalingService();
  SignalingService get signaling => _signaling;
  Timer? _iceDisconnectTimer;
  bool _isHangingUp = false;  // M2: ป้องกัน double hangUp
  bool _iceRestartAttempted = false;  // M4: ICE restart limit (1 attempt per session)
  bool _answerProcessed = false;  // ป้องกัน setRemoteDescription ซ้ำเพราะ Firestore fire หลายครั้ง

  // ==================== Setup ====================

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(WebRTCConfig.iceServers);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        final role = _callState == CallState.calling ? 'caller' : 'callee';
        _signaling.addIceCandidate(candidate, role);
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _iceDisconnectTimer?.cancel();
        _iceRestartAttempted = false;  // reset retry flag on successful connection
        _setState(CallState.connected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        // M4: ลอง ICE restart ก่อน hang up
        debugPrint('ICE disconnected — attempting ICE restart in 3s');
        _iceDisconnectTimer?.cancel();
        _iceDisconnectTimer = Timer(const Duration(seconds: 3), () async {
          if (_peerConnection == null || _callState == CallState.ended) return;
          if (!_iceRestartAttempted) {
            try {
              _iceRestartAttempted = true;
              debugPrint('WebRTCService: attempting ICE restart');
              await _peerConnection!.restartIce();
              // ให้เวลา 5 วิอีกรอบหลัง restart
              _iceDisconnectTimer = Timer(const Duration(seconds: 5), hangUp);
            } catch (e) {
              debugPrint('WebRTCService: ICE restart failed: $e');
              hangUp();
            }
          } else {
            hangUp();
          }
        });
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _iceDisconnectTimer?.cancel();
        hangUp();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        // N1: dedupe — ตรวจ stream id ก่อน replace
        final newStream = event.streams[0];
        if (_remoteStream?.id == newStream.id) return;
        _remoteStream = newStream;
        notifyListeners();
      }
    };

    // เพิ่ม voice+video track
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        _peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Phase 2: เพิ่ม stethoscope audio track (filter ปิดทั้งหมด)
    if (_stethStream != null) {
      for (final track in _stethStream!.getAudioTracks()) {
        _peerConnection!.addTrack(track, _stethStream!);
      }
      debugPrint('WebRTCService: added stethoscope track to PeerConnection');
    }

    // PCM DataChannel — caller (patient) creates, callee (doctor) receives via onDataChannel
    // Web: JS interceptor handles playback automatically
    // Native: ใช้ channel นี้ส่ง Float32 PCM chunks ตรงๆ
    _peerConnection!.onDataChannel = (channel) {
      if (channel.label == 'pcm-heart') {
        _pcmChannel = channel;
        channel.onDataChannelState = (state) {
          debugPrint('WebRTCService: PCM DataChannel state=$state');
          notifyListeners();
        };
        debugPrint('WebRTCService: PCM DataChannel received (doctor side)');
        notifyListeners();
      } else if (channel.label == 'control') {
        _controlChannel = channel;
        channel.onMessage = _handleControlMessage;
        channel.onDataChannelState = (state) {
          debugPrint('WebRTCService: control DataChannel state=$state');
        };
        debugPrint('WebRTCService: control DataChannel received');
      }
    };
  }

  /// สร้าง control DataChannel ฝั่ง patient (caller) — ส่ง mute/command ตรงผ่าน P2P
  /// ไม่พึ่ง Firestore → ทำงานได้แม้ internet flaky
  Future<void> _createControlChannel() async {
    try {
      _controlChannel = await _peerConnection!.createDataChannel(
        'control',
        RTCDataChannelInit()..ordered = true,
      );
      _controlChannel!.onMessage = _handleControlMessage;
      _controlChannel!.onDataChannelState = (state) {
        debugPrint('WebRTCService: control DataChannel state=$state');
      };
      debugPrint('WebRTCService: control DataChannel created (patient side)');
    } catch (e) {
      debugPrint('WebRTCService: control DataChannel create error: $e');
    }
  }

  /// รับคำสั่งจาก peer ผ่าน control channel
  /// Bilateral mute: peer กด mute → เราต้อง (1) หยุดส่ง audio และ (2) mute playback ตัวเองด้วย
  /// ผลคือกด mute ฝั่งใดฝั่งหนึ่ง → ทั้ง 2 ฝั่งเงียบทันที (no propagation delay)
  void _handleControlMessage(RTCDataChannelMessage msg) {
    try {
      final data = jsonDecode(msg.text) as Map<String, dynamic>;
      if (data['type'] == 'mute') {
        final muted = data['muted'] as bool;
        debugPrint('[Control] received mute=$muted → bilateral mute');
        // 1. stop sending audio
        setLocalSenderEnabled(!muted);
        // 2. mute own playback (Opus + PCM)
        if (kIsWeb) {
          audio_js.setRemoteAudioMuted(muted);
          audio_js.setPcmPlaybackMuted(muted);
        } else {
          toggleRemoteAudio(!muted);
        }
      }
    } catch (e) {
      debugPrint('[Control] handle msg error: $e');
    }
  }

  /// ส่งคำสั่ง mute ไปยัง peer — DataChannel ก่อน, fallback Firestore
  Future<void> sendMuteCommand(bool muted) async {
    if (_controlChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _controlChannel!.send(RTCDataChannelMessage(jsonEncode({
          'type': 'mute',
          'muted': muted,
        })));
        debugPrint('[Control] sent mute=$muted via DataChannel');
        return;
      } catch (e) {
        debugPrint('[Control] DC send failed: $e — falling back to Firestore');
      }
    }
    // fallback — Firestore signaling (works once network recovers)
    if (_myRole != null) {
      await _signaling.setRemoteIncomingMute(_myRole!, muted);
    }
  }

  /// สร้าง PCM DataChannel ฝั่ง patient (caller) — เรียกหลัง _createPeerConnection
  Future<void> _createPcmChannel() async {
    // หมายเหตุ: ต้องสร้าง DataChannel ทั้งบน web และ native
    // บน web: flutter_webrtc ส่งผ่าน JS createDataChannel → PatchedPC2 interceptor ใน index.html
    //         จะ set _pcmChannel JS variable → startPcmCapture ส่งข้อมูลได้
    // บน native: สร้าง RTCDataChannel โดยตรง → callee รับผ่าน onDataChannel callback
    try {
      _pcmChannel = await _peerConnection!.createDataChannel(
        'pcm-heart',
        RTCDataChannelInit()
          ..ordered = true,     // TCP-like: ทุก packet ถึงแน่นอน ไม่มี gap ใน WAV
          // ไม่ set maxRetransmits → reliable delivery (สำคัญกว่า latency สำหรับ medical recording)
      );
      _pcmChannel!.onDataChannelState = (state) {
        debugPrint('WebRTCService: PCM DataChannel state=$state');
        notifyListeners();
      };
      debugPrint('WebRTCService: PCM DataChannel created (patient side)');
    } catch (e) {
      debugPrint('WebRTCService: PCM DataChannel create error (non-fatal): $e');
    }
  }

  // ==================== Audio Session ====================

  /// Configure AudioSession ก่อนเริ่ม call
  /// iOS  → measurement mode: ปิด voice processing ทั้งหมด
  /// Android → normal mode: ลด chance ที่ hardware AEC จะทำงาน
  static Future<void> configureAudioSession() async {
    // web ไม่มี native AudioSession
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        // iOS: measurement mode ปิด AEC/NS/AGC ระดับ AVAudioSession
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp,
        avAudioSessionMode: AVAudioSessionMode.measurement,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,

        // Android: ใช้ media mode แทน communication mode
        // communication mode บังคับ hardware AEC เปิดตลอด
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.unknown,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      debugPrint('AudioSession: configured — iOS measurement / Android media mode');
    } catch (e) {
      debugPrint('AudioSession: configure error (non-fatal): $e');
    }
  }

  // ==================== Local Stream ====================

  Future<bool> initLocalStream() async {
    try {
      debugPrint('>>> getUserMedia: requesting...');
      _localStream = await navigator.mediaDevices.getUserMedia(
        WebRTCConfig.voiceConstraints,
      );
      debugPrint('>>> getUserMedia: OK tracks=${_localStream!.getTracks().length}');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('>>> getUserMedia ERROR: $e');
      _setError('ไม่สามารถเปิดกล้อง/ไมค์: $e');
      return false;
    }
  }

  /// Phase 2: เพิ่ม stethoscope stream (ปิด filter ทั้งหมด)
  /// เรียกหลัง initLocalStream() และก่อน startCall()
  Future<bool> initStethoscopeStream({String? deviceId}) async {
    try {
      final constraints = deviceId != null
          ? WebRTCConfig.stethoscopeConstraints(deviceId)
          : {
              'audio': {
                'echoCancellation': {'exact': false},
                'noiseSuppression': {'exact': false},
                'autoGainControl': {'exact': false},
                'googHighpassFilter': false,
                'googNoiseSuppression': false,
                'googAutoGainControl': false,
                'googEchoCancellation': false,
              },
              'video': false,
            };
      _stethStream = await navigator.mediaDevices.getUserMedia(constraints);
      debugPrint('>>> stethoscope stream: OK tracks=${_stethStream!.getTracks().length}');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('>>> stethoscope stream ERROR: $e');
      // ไม่ fatal — call ยังทำงานได้โดยไม่มี stethoscope
      return false;
    }
  }

  // ==================== Patient (Caller) ====================

  Future<String?> startCall() async {
    if (_callState != CallState.idle) {
      debugPrint('WebRTCService: startCall ignored — state=$_callState');
      return null;
    }
    _myRole = 'patient';
    _setState(CallState.calling);

    try {
      debugPrint('>>> startCall: step 0 configureAudioSession');
      await configureAudioSession();

      debugPrint('>>> startCall: step 1 initLocalStream');
      final ok = await initLocalStream();
      if (!ok) return null;

      debugPrint('>>> startCall: step 2 createPeerConnection');
      await _createPeerConnection();
      await _createPcmChannel();     // patient สร้าง PCM DataChannel ก่อน createOffer
      await _createControlChannel(); // patient สร้าง control DataChannel ด้วย

      debugPrint('>>> startCall: step 3 createOffer');
      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      // Phase 2: modify SDP บังคับ Opus fullband 48kHz
      final modifiedOffer = RTCSessionDescription(
        WebRTCConfig.forceOpusFullband(offer.sdp ?? ''),
        offer.type,
      );

      debugPrint('>>> startCall: step 4 setLocalDescription');
      await _peerConnection!.setLocalDescription(modifiedOffer);

      debugPrint('>>> startCall: step 5 createRoom (Firestore)');
      _roomId = await _signaling.createRoom(modifiedOffer);
      debugPrint('>>> startCall: roomId=$_roomId');

      _signaling.listenForAnswer((answer) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        // Firestore snapshot อาจ fire หลายครั้งสำหรับ document เดียวกัน
        // → process answer ครั้งเดียวเท่านั้น
        if (_answerProcessed) return;
        _answerProcessed = true;
        try {
          await _peerConnection!.setRemoteDescription(answer);
        } catch (e) {
          debugPrint('WebRTCService: setRemoteDescription error: $e');
          // อย่า hangUp — InvalidStateError เกิดจาก state mismatch แต่ call ยัง work ได้
          // ถ้า error จริงจัง ICE จะ fail เองและ hangUp ผ่าน onIceConnectionState
        }
      });

      _signaling.listenForRemoteCandidates('callee', (candidate) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        try {
          await _peerConnection!.addCandidate(candidate);
        } catch (e) {
          debugPrint('WebRTCService: addCandidate (callee) error: $e');
        }
      });

      _signaling.listenForRoomStatus((status) {
        if (status == FirebaseConfig.statusEnded && _callState != CallState.ended) {
          hangUp();
        }
      });

      notifyListeners();
      return _roomId;
    } catch (e) {
      _setError('ไม่สามารถเริ่ม call: $e');
      // N3: cleanup partial state เมื่อ exception
      await _localStream?.dispose();
      await _stethStream?.dispose();
      await _peerConnection?.close();
      _localStream = null;
      _stethStream = null;
      _peerConnection = null;
      _pcmChannel = null;
      _signaling.reset();
      return null;
    }
  }

  // ==================== Doctor (Callee) ====================

  Future<bool> joinCall(String roomId) async {
    if (_callState != CallState.idle) {
      debugPrint('WebRTCService: joinCall ignored — state=$_callState');
      return false;
    }
    _myRole = 'doctor';
    _setState(CallState.waiting);

    try {
      await configureAudioSession();
      final ok = await initLocalStream();
      if (!ok) return false;

      await _createPeerConnection();

      final offer = await _signaling.joinRoom(roomId);
      if (offer == null) {
        _setError('ไม่พบ room: $roomId');
        return false;
      }

      await _peerConnection!.setRemoteDescription(offer);

      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });

      // Phase 2: modify SDP
      final modifiedAnswer = RTCSessionDescription(
        WebRTCConfig.forceOpusFullband(answer.sdp ?? ''),
        answer.type,
      );

      await _peerConnection!.setLocalDescription(modifiedAnswer);
      await _signaling.uploadAnswer(modifiedAnswer);

      _signaling.listenForRemoteCandidates('caller', (candidate) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        try {
          await _peerConnection!.addCandidate(candidate);
        } catch (e) {
          debugPrint('WebRTCService: addCandidate (caller) error: $e');
        }
      });

      _signaling.listenForRoomStatus((status) {
        if (status == FirebaseConfig.statusEnded && _callState != CallState.ended) {
          hangUp();
        }
      });

      _roomId = roomId;
      notifyListeners();
      return true;
    } catch (e) {
      _setError('ไม่สามารถ join call: $e');
      // N3: cleanup partial state
      await _localStream?.dispose();
      await _peerConnection?.close();
      _localStream = null;
      _peerConnection = null;
      _signaling.reset();
      return false;
    }
  }

  // ==================== Controls ====================

  void toggleMic(bool enabled) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  }

  void toggleCamera(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
  }

  /// Phase 2: เปิด/ปิด stethoscope track
  void toggleStethoscope(bool enabled) {
    _stethStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  }

  void toggleRemoteAudio(bool enabled) {
    _remoteStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  }

  /// Sender-side mute — เมื่อ peer ขอ mute มา เราหยุดส่ง audio ออก
  ///  - disable audio track senders (Opus หยุดเข้ารหัส)
  ///  - gate PCM DataChannel send (ทั้ง web worklet และ native pcmStreamSub)
  bool _pcmSendEnabled = true;
  bool get pcmSendEnabled => _pcmSendEnabled;

  Future<void> setLocalSenderEnabled(bool enabled) async {
    _pcmSendEnabled = enabled;
    // 1. ปิด audio sender ทุกตัว — Opus track หยุดส่ง
    if (_peerConnection != null) {
      final senders = await _peerConnection!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'audio') {
          s.track!.enabled = enabled;
        }
      }
    }
    // 2. local audio track flag — กัน flutter_webrtc resync
    _localStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
    _stethStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
    // 3. PCM send gate บน web (worklet onmessage จะเช็ค flag นี้)
    //    + JS-side audio sender flag — บังคับ track.enabled แม้หลัง SimAudio replaceTrack
    if (kIsWeb) {
      audio_js.setPcmSendEnabled(enabled);
      audio_js.setAudioSenderEnabled(enabled);
    }
    debugPrint('WebRTCService: local sender enabled=$enabled');
    notifyListeners();
  }

  // ==================== Native PCM Send (Patient → Doctor via DataChannel) ====================

  /// เริ่มจับเสียง mic บน Android แล้วส่งเป็น Float32 PCM ผ่าน DataChannel
  /// เรียกจาก PatientCallScreen เมื่อ connected และ !kIsWeb
  Future<void> startNativePcmCapture() async {
    if (_pcmChannel == null) {
      debugPrint('WebRTCService: PCM DataChannel not ready — skip native capture');
      return;
    }
    if (_pcmRecorder != null) return; // already running

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      debugPrint('WebRTCService: mic permission denied for PCM capture');
      return;
    }

    try {
      _pcmRecorder = AudioRecorder();
      final stream = await _pcmRecorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,  // 16kHz — พอสำหรับ 20–500Hz heart sounds, bandwidth ต่ำ
          numChannels: 1,
          noiseSuppress: false,
          echoCancel: false,
          autoGain: false,
        ),
      );

      _pcmStreamSub = stream.listen((chunk) {
        if (_pcmChannel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
        if (!_pcmSendEnabled) return; // sender-side mute
        // Int16 bytes → Float32 bytes สำหรับ RecordingService._writeWav ที่รับ Float32
        final int16 = chunk.buffer.asInt16List(chunk.offsetInBytes, chunk.lengthInBytes ~/ 2);
        final float32 = Float32List(int16.length);
        for (int i = 0; i < int16.length; i++) {
          float32[i] = int16[i] / 32768.0;
        }
        try {
          _pcmChannel!.send(RTCDataChannelMessage.fromBinary(float32.buffer.asUint8List()));
        } catch (e) {
          debugPrint('WebRTCService: PCM send error: $e');
        }
      }, onError: (e) {
        debugPrint('WebRTCService: PCM stream error: $e');
        _pcmStreamSub?.cancel();
        _pcmStreamSub = null;
      }, cancelOnError: true);

      debugPrint('WebRTCService: native PCM capture started (16kHz mono)');
    } catch (e) {
      debugPrint('WebRTCService: native PCM capture failed: $e');
      await _pcmRecorder?.dispose();
      _pcmRecorder = null;
    }
  }

  Future<void> stopNativePcmCapture() async {
    await _pcmStreamSub?.cancel();
    _pcmStreamSub = null;
    await _pcmRecorder?.stop();
    await _pcmRecorder?.dispose();
    _pcmRecorder = null;
    debugPrint('WebRTCService: native PCM capture stopped');
  }

  Future<void> hangUp() async {
    if (_isHangingUp) {
      debugPrint('WebRTCService: hangUp already in progress — skip');
      return;
    }
    _isHangingUp = true;
    try {
      _iceDisconnectTimer?.cancel();
      _iceDisconnectTimer = null;
      _answerProcessed = false;  // reset เพื่อ call ใหม่ทำงานได้
      _iceRestartAttempted = false;
      await stopNativePcmCapture();
      _setState(CallState.ended);
      await _signaling.endRoom();
      await _localStream?.dispose();
      await _stethStream?.dispose();
      await _remoteStream?.dispose();
      await _peerConnection?.close();
      _localStream = null;
      _stethStream = null;
      _remoteStream = null;
      _peerConnection = null;
      _pcmChannel = null;
      _controlChannel = null;
      _myRole = null;
      _roomId = null;
      _signaling.reset();
      notifyListeners();
    } finally {
      _isHangingUp = false;
    }
  }

  void reset() {
    _callState = CallState.idle;
    _errorMessage = null;
    notifyListeners();
  }

  void _setState(CallState state) {
    _callState = state;
    notifyListeners();
  }

  void _setError(String message) {
    _callState = CallState.error;
    _errorMessage = message;
    notifyListeners();
    debugPrint('WebRTCService Error: $message');
  }

  @override
  void dispose() {
    _iceDisconnectTimer?.cancel();
    _pcmStreamSub?.cancel();
    _pcmRecorder?.dispose();
    _localStream?.dispose();
    _stethStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _signaling.reset();  // A6: ป้องกัน Firestore listeners leak
    super.dispose();
  }
}
