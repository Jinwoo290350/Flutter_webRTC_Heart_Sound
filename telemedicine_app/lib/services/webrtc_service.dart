import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config/webrtc_config.dart';
import '../config/firebase_config.dart';
import '../models/call_state.dart';
import 'signaling_service.dart';

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

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  bool get hasStethoscope => _stethStream != null;

  final SignalingService _signaling = SignalingService();

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
        _setState(CallState.connected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
                 state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        hangUp();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
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
    _setState(CallState.calling);

    try {
      debugPrint('>>> startCall: step 1 initLocalStream');
      final ok = await initLocalStream();
      if (!ok) return null;

      debugPrint('>>> startCall: step 2 createPeerConnection');
      await _createPeerConnection();

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
        await _peerConnection!.setRemoteDescription(answer);
      });

      _signaling.listenForRemoteCandidates('callee', (candidate) async {
        await _peerConnection!.addCandidate(candidate);
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
      return null;
    }
  }

  // ==================== Doctor (Callee) ====================

  Future<bool> joinCall(String roomId) async {
    _setState(CallState.waiting);

    try {
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
        await _peerConnection!.addCandidate(candidate);
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

  Future<void> hangUp() async {
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
    _roomId = null;
    _signaling.reset();
    notifyListeners();
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
    _localStream?.dispose();
    _stethStream?.dispose();
    _remoteStream?.dispose();
    _peerConnection?.close();
    super.dispose();
  }
}
