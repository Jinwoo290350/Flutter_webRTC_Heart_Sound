import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audio_session/audio_session.dart';
import '../config/webrtc_config.dart';
import '../config/firebase_config.dart';
import '../models/call_state.dart';
import 'signaling_service.dart';
import '_audio_js_stub.dart'
    if (dart.library.js_interop) '_audio_js_web.dart' as audio_js;

/// WebRTCService — video call + voice (Opus) + heart sound (Opus + PCM DataChannel)
class WebRTCService extends ChangeNotifier {
  CallState _callState = CallState.idle;
  CallState get callState => _callState;

  String? _roomId;
  String? get roomId => _roomId;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCDataChannel? _pcmChannel;     // raw PCM heart sound
  RTCDataChannel? _controlChannel; // command messages (heart stop, etc.)

  // Heart mode state (patient-driven, doctor receives via Firestore)
  bool _heartMode = false;
  String? _heartPosition;
  bool get heartMode => _heartMode;
  String? get heartPosition => _heartPosition;

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  final SignalingService _signaling = SignalingService();
  SignalingService get signaling => _signaling;
  Timer? _iceDisconnectTimer;
  bool _isHangingUp = false;
  bool _iceRestartAttempted = false;
  bool _answerProcessed = false;

  // ==================== Setup ====================

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(WebRTCConfig.iceServers);

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      final role = _callState == CallState.calling ? 'caller' : 'callee';
      // Diagnostic: log candidate type (host/srflx/relay) เพื่อ debug NAT/TURN
      try {
        final c = candidate.candidate!;
        final typeMatch = RegExp(r'typ (host|srflx|prflx|relay)').firstMatch(c);
        final type = typeMatch?.group(1) ?? 'unknown';
        debugPrint('[ICE] local candidate gathered type=$type role=$role');
      } catch (_) {}
      // ICE candidates อาจ fire ก่อน room ถูกสร้าง (race ระหว่าง gathering กับ createRoom)
      // → addIceCandidate ใน signaling จะ no-op ถ้า _roomRef ยัง null. wrap try/catch กัน flood
      try {
        _signaling.addIceCandidate(candidate, role).catchError((e) {
          debugPrint('WebRTCService: addIceCandidate async error: $e');
        });
      } catch (e) {
        debugPrint('WebRTCService: addIceCandidate sync error: $e');
      }
    };

    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('[ICE] gathering state: $state');
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _iceDisconnectTimer?.cancel();
        _iceRestartAttempted = false;
        _setState(CallState.connected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        // Slow networks (Slow 4G/3G) อาจใช้เวลาเป็นสิบวินาทีก่อน Connected → tolerance สูง
        _iceDisconnectTimer?.cancel();
        _iceDisconnectTimer = Timer(const Duration(seconds: 15), () async {
          if (_peerConnection == null || _callState == CallState.ended) return;
          if (!_iceRestartAttempted) {
            try {
              _iceRestartAttempted = true;
              debugPrint('WebRTCService: ICE restart after 15s disconnect');
              await _peerConnection!.restartIce();
              _iceDisconnectTimer = Timer(const Duration(seconds: 20), hangUp);
            } catch (e) {
              debugPrint('WebRTCService: ICE restart failed: $e');
              hangUp();
            }
          } else {
            hangUp();
          }
        });
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        // Failed = ICE หมดทาง — ปล่อยให้ user รู้แล้ว manual retry
        _iceDisconnectTimer?.cancel();
        debugPrint('WebRTCService: ICE failed — hanging up');
        hangUp();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        final newStream = event.streams[0];
        if (_remoteStream?.id == newStream.id) return;
        _remoteStream = newStream;
        notifyListeners();
      }
    };

    // Doctor receives DataChannels (patient creates them)
    _peerConnection!.onDataChannel = (channel) {
      if (channel.label == 'pcm-heart') {
        _pcmChannel = channel;
        channel.onDataChannelState = (state) {
          debugPrint('WebRTCService: PCM DC state=$state');
        };
        debugPrint('WebRTCService: PCM DataChannel received');
      } else if (channel.label == 'control') {
        _controlChannel = channel;
        channel.onMessage = _handleControlMessage;
        debugPrint('WebRTCService: control DataChannel received');
      }
    };

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        _peerConnection!.addTrack(track, _localStream!);
      }
    }
  }

  /// Patient (caller) creates DataChannels ก่อน createOffer
  Future<void> _createDataChannels() async {
    try {
      _pcmChannel = await _peerConnection!.createDataChannel(
        'pcm-heart',
        RTCDataChannelInit()..ordered = true,
      );
      _controlChannel = await _peerConnection!.createDataChannel(
        'control',
        RTCDataChannelInit()..ordered = true,
      );
      _controlChannel!.onMessage = _handleControlMessage;
      debugPrint('WebRTCService: DataChannels created');
    } catch (e) {
      debugPrint('WebRTCService: DC create error: $e');
    }
  }

  /// Patient receives commands จาก doctor (เช่น stop heart sound)
  void _handleControlMessage(RTCDataChannelMessage msg) {
    try {
      final data = jsonDecode(msg.text) as Map<String, dynamic>;
      if (data['type'] == 'stopHeart' && _heartMode) {
        debugPrint('[Control] received stopHeart → stopping');
        stopHeartSound();
      }
    } catch (e) {
      debugPrint('[Control] handle error: $e');
    }
  }

  /// Doctor: ส่งคำสั่งให้ patient หยุดส่งเสียงหัวใจ
  void sendStopHeart() {
    if (_controlChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _controlChannel!.send(RTCDataChannelMessage(
          jsonEncode({'type': 'stopHeart'}),
        ));
        debugPrint('[Control] sent stopHeart');
      } catch (e) {
        debugPrint('[Control] send error: $e');
      }
    }
  }

  // ==================== Audio Session ====================

  static Future<void> configureAudioSession() async {
    if (kIsWeb) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
    } catch (e) {
      debugPrint('AudioSession error (non-fatal): $e');
    }
  }

  // ==================== Local Stream ====================

  Future<bool> initLocalStream() async {
    try {
      _localStream = await navigator.mediaDevices.getUserMedia(
        WebRTCConfig.voiceConstraints,
      );
      // Diagnostic: verify AEC/NS/AGC ทำงานจริงหลัง constraint apply
      final audioTracks = _localStream!.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        try {
          final settings = audioTracks.first.getSettings();
          debugPrint('[Mic] AEC=${settings['echoCancellation']} '
              'NS=${settings['noiseSuppression']} '
              'AGC=${settings['autoGainControl']} '
              'sampleRate=${settings['sampleRate']}');
        } catch (e) {
          debugPrint('[Mic] getSettings error (non-fatal): $e');
        }
      }
      // Diagnostic: video track count + resolution
      // tracks=0 = camera permission denied; tracks=1 + width=null = silent broken track
      final videoTracks = _localStream!.getVideoTracks();
      debugPrint('[Cam] tracks=${videoTracks.length}');
      if (videoTracks.isNotEmpty) {
        try {
          final s = videoTracks.first.getSettings();
          debugPrint('[Cam] ${s['width']}x${s['height']}@${s['frameRate']} '
              'facing=${s['facingMode']} deviceId=${s['deviceId']}');
        } catch (e) {
          debugPrint('[Cam] getSettings error (non-fatal): $e');
        }
      }
      notifyListeners();
      return true;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('NotAllowedError') || msg.contains('PermissionDenied')) {
        _setError('กรุณาอนุญาตเปิดกล้องและไมโครโฟน');
      } else if (msg.contains('NotFoundError') ||
          msg.contains('DevicesNotFound')) {
        _setError('ไม่พบกล้องหรือไมโครโฟน — เช็คว่ามีอุปกรณ์ต่ออยู่');
      } else if (msg.contains('OverconstrainedError')) {
        _setError('กล้องไม่รองรับ resolution ที่ขอ');
      } else {
        _setError('ไม่สามารถเปิดกล้อง/ไมค์: $e');
      }
      return false;
    }
  }

  // ==================== Patient (Caller) ====================

  Future<String?> startCall() async {
    if (_callState != CallState.idle) return null;
    _setState(CallState.calling);

    try {
      await configureAudioSession();
      if (!await initLocalStream()) return null;

      await _createPeerConnection();
      await _createDataChannels(); // patient creates PCM + control DC before offer

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      final modOffer = RTCSessionDescription(
        WebRTCConfig.forceOpusFullband(offer.sdp ?? ''),
        offer.type,
      );
      await _peerConnection!.setLocalDescription(modOffer);

      _roomId = await _signaling.createRoom(modOffer);

      _signaling.listenForAnswer((answer) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        if (_answerProcessed) return;
        _answerProcessed = true;
        try {
          await _peerConnection!.setRemoteDescription(answer);
          debugPrint('[SDP] setRemoteDescription(answer) OK');
        } catch (e) {
          debugPrint('[SDP] setRemoteDescription(answer) FAILED: $e');
        }
      });

      _signaling.listenForRemoteCandidates('callee', (candidate) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        try {
          await _peerConnection!.addCandidate(candidate);
          final c = candidate.candidate ?? '';
          final typeMatch = RegExp(r'typ (host|srflx|prflx|relay)').firstMatch(c);
          final isMdns = c.contains('.local');   // browser host candidates = mDNS .local
          debugPrint('[ICE] remote candidate added type=${typeMatch?.group(1) ?? "?"}'
              '${isMdns ? " MDNS(.local)" : ""}');
        } catch (e) {
          debugPrint('WebRTCService: addCandidate error: $e');
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
      await _localStream?.dispose();
      await _peerConnection?.close();
      _localStream = null;
      _peerConnection = null;
      _pcmChannel = null;
      _signaling.reset();
      return null;
    }
  }

  // ==================== Doctor (Callee) ====================

  Future<bool> joinCall(String roomId) async {
    if (_callState != CallState.idle) return false;
    _setState(CallState.waiting);

    try {
      await configureAudioSession();
      if (!await initLocalStream()) return false;

      await _createPeerConnection();

      final offer = await _signaling.joinRoom(roomId);
      if (offer == null) {
        _setError('ไม่พบ room: $roomId');
        return false;
      }
      try {
        await _peerConnection!.setRemoteDescription(offer);
        debugPrint('[SDP] setRemoteDescription(offer) OK');
      } catch (e) {
        debugPrint('[SDP] setRemoteDescription(offer) FAILED: $e');
        _setError('SDP offer ไม่ถูกต้อง: $e');
        return false;
      }

      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      final modAnswer = RTCSessionDescription(
        WebRTCConfig.forceOpusFullband(answer.sdp ?? ''),
        answer.type,
      );
      await _peerConnection!.setLocalDescription(modAnswer);
      await _signaling.uploadAnswer(modAnswer);

      _signaling.listenForRemoteCandidates('caller', (candidate) async {
        if (_peerConnection == null || _callState == CallState.ended) return;
        try {
          await _peerConnection!.addCandidate(candidate);
          final c = candidate.candidate ?? '';
          final typeMatch = RegExp(r'typ (host|srflx|prflx|relay)').firstMatch(c);
          final isMdns = c.contains('.local');   // browser host candidates = mDNS .local
          debugPrint('[ICE] remote candidate added type=${typeMatch?.group(1) ?? "?"}'
              '${isMdns ? " MDNS(.local)" : ""}');
        } catch (e) {
          debugPrint('WebRTCService: addCandidate error: $e');
        }
      });

      _signaling.listenForRoomStatus((status) {
        if (status == FirebaseConfig.statusEnded && _callState != CallState.ended) {
          hangUp();
        }
      });

      // Doctor listens for patient heart mode signal → updates banner
      _signaling.listenForHeartMode((enabled, position) {
        _heartMode = enabled;
        _heartPosition = position;
        notifyListeners();
      });

      _roomId = roomId;
      notifyListeners();
      return true;
    } catch (e) {
      _setError('ไม่สามารถ join call: $e');
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
    notifyListeners();
  }

  void toggleCamera(bool enabled) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = enabled);
    notifyListeners();
  }

  /// Doctor: ฟัง Opus ผ่าน <audio> sink หรือไม่ (local-only mute)
  void setOpusMuted(bool muted) {
    if (kIsWeb) {
      audio_js.setOpusMuted(muted);
    } else {
      _remoteStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
    }
    notifyListeners();
  }

  /// Doctor: ฟัง PCM heart sound ผ่าน DataChannel หรือไม่ (local-only mute)
  void setPcmMuted(bool muted) {
    if (kIsWeb) {
      audio_js.setPcmMuted(muted);
    }
    notifyListeners();
  }

  /// Half-Duplex (walkie-talkie) — auto-mute local mic เมื่อ peer พูด
  /// แก้ acoustic feedback loop (self-echo + whining) บน same-room test
  void setHalfDuplex(bool enabled) {
    if (kIsWeb) {
      audio_js.setHalfDuplex(enabled);
    }
    notifyListeners();
  }

  /// Soft Expander — Web Audio chain ลด level ของ remote audio ที่เบา (~echo feedback)
  /// ลง -20dB โดยไม่แตะ mic. Suppress self-echo แบบ smooth (ไม่ chop conversation)
  void enableSoftExpander() {
    if (kIsWeb) {
      audio_js.enableSoftExpander();
    }
  }

  void disableSoftExpander() {
    if (kIsWeb) {
      audio_js.disableSoftExpander();
    }
  }

  /// Patient: เริ่มส่งเสียงหัวใจ (replace mic with SimAudio + send via PCM DC)
  Future<void> startHeartSound(String assetPath, String positionLabel) async {
    if (!kIsWeb) return; // web-only for now
    await audio_js.startSimAudio(assetPath);
    _heartMode = true;
    _heartPosition = positionLabel;
    await _signaling.setHeartMode(true, positionLabel);
    notifyListeners();
  }

  /// Patient: หยุด heart sound — restore mic
  Future<void> stopHeartSound() async {
    if (!kIsWeb) return;
    await audio_js.stopSimAudio();
    _heartMode = false;
    _heartPosition = null;
    await _signaling.setHeartMode(false);
    notifyListeners();
  }

  /// Patient: live stethoscope mic — filters OFF, raw audio → PCM DC
  Future<void> startStethoscopeMic() async {
    if (!kIsWeb) return;
    await audio_js.startStethMic();
    _heartMode = true;
    _heartPosition = 'Live';
    await _signaling.setHeartMode(true, 'Live');
    notifyListeners();
  }

  Future<void> stopStethoscopeMic() async {
    if (!kIsWeb) return;
    await audio_js.stopStethMic();
    _heartMode = false;
    _heartPosition = null;
    await _signaling.setHeartMode(false);
    notifyListeners();
  }

  /// Doctor: bass boost ON/OFF (display aid only)
  void setBassBoost(bool enabled) {
    if (kIsWeb) audio_js.setBassBoost(enabled);
  }

  // ==================== Lifecycle ====================

  Future<void> hangUp() async {
    if (_isHangingUp) return;
    _isHangingUp = true;
    try {
      _iceDisconnectTimer?.cancel();
      _iceDisconnectTimer = null;
      _answerProcessed = false;
      _iceRestartAttempted = false;
      _heartMode = false;
      _heartPosition = null;
      if (kIsWeb) {
        await audio_js.stopSimAudio();
      }
      _setState(CallState.ended);
      await _signaling.endRoom();
      await _localStream?.dispose();
      await _remoteStream?.dispose();
      await _peerConnection?.close();
      _localStream = null;
      _remoteStream = null;
      _peerConnection = null;
      _pcmChannel = null;
      _controlChannel = null;
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
  }

  @override
  void dispose() {
    _iceDisconnectTimer?.cancel();
    _localStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    _signaling.reset();
    super.dispose();
  }
}
