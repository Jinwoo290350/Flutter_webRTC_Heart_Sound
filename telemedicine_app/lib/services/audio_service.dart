import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config/webrtc_config.dart';
import '_audio_js_stub.dart'
    if (dart.library.js_interop) '_audio_js_web.dart';

/// โหมดการฟังของหมอ
enum ListeningMode { voice, heartSound }

extension ListeningModeInfo on ListeningMode {
  String get label =>
      this == ListeningMode.voice ? 'โหมดคุย' : 'โหมดฟังเสียงหัวใจ';
}

/// ตำแหน่งหัวใจ 4 ตำแหน่ง
enum HeartPosition { aortic, mitral, pulmonary, tricuspid }

extension HeartPositionInfo on HeartPosition {
  String get label {
    switch (this) {
      case HeartPosition.aortic:    return 'Aortic';
      case HeartPosition.mitral:    return 'Mitral';
      case HeartPosition.pulmonary: return 'Pulmonary';
      case HeartPosition.tricuspid: return 'Tricuspid';
    }
  }

  String get labelTh {
    switch (this) {
      case HeartPosition.aortic:    return 'ลิ้นหัวใจ Aortic';
      case HeartPosition.mitral:    return 'ลิ้นหัวใจ Mitral';
      case HeartPosition.pulmonary: return 'ลิ้นหัวใจ Pulmonary';
      case HeartPosition.tricuspid: return 'ลิ้นหัวใจ Tricuspid';
    }
  }

  /// รายการ variant ที่มีสำหรับแต่ละตำแหน่ง (index คือ severity)
  List<String> get variants {
    switch (this) {
      case HeartPosition.aortic:
        return ['best', '0', '1', '2', '3', '4', '5'];
      case HeartPosition.mitral:
        return ['best', '0', '2', '3', '4', '5'];
      case HeartPosition.pulmonary:
        return ['best', '0', '1', '2', '3', '4', '5'];
      case HeartPosition.tricuspid:
        return ['best', '0', '1', '3', '4', '5'];
    }
  }

  /// variant ที่ดีที่สุด (top score จาก heart_sound_analysis.csv)
  String get bestVariant {
    switch (this) {
      case HeartPosition.aortic:    return '4';  // SNR 24.6dB, LowFreq 89.6%
      case HeartPosition.mitral:    return '4';  // LowFreq 94.6%
      case HeartPosition.pulmonary: return '2';  // score สูงสุดของ Pulmonary
      case HeartPosition.tricuspid: return '4';  // SNR 26.0dB สูงสุดทั้งหมด
    }
  }

  String assetPath(String variant) {
    // 'best' → ใช้ไฟล์ที่ copy มาจาก top score
    if (variant == 'best') {
      return 'assets/heart_sounds/${name}_best.wav';
    }
    return 'assets/heart_sounds/${name}_$variant.wav';
  }
}

/// AudioService — จัดการ mode, simulation, และ WebRTC audio tracks
class AudioService extends ChangeNotifier {
  // ==================== Listening Mode ====================

  ListeningMode _mode = ListeningMode.voice;
  ListeningMode get mode => _mode;

  void switchMode(ListeningMode newMode) {
    if (_mode == newMode) return;
    _mode = newMode;
    // แจ้ง JS ให้เปิด/ปิด bass boost บน receiver
    setHeartMode(newMode == ListeningMode.heartSound);
    notifyListeners();
  }

  // ==================== Remote stream ====================

  MediaStream? remoteStream;

  void setRemoteAudioEnabled(bool enabled) {
    remoteStream?.getAudioTracks().forEach((t) => t.enabled = enabled);
  }

  // ==================== Stethoscope Stream (Phase 2) ====================

  MediaStream? _stethStream;
  MediaStream? get stethStream => _stethStream;

  /// ขอ stethoscope audio stream โดยปิด filter ทั้งหมด
  /// [deviceId]: device ID ของ stethoscope (null = ใช้ default mic + ปิด filter)
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
      debugPrint('AudioService: steth stream OK, tracks=${_stethStream!.getTracks().length}');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('AudioService: steth stream error: $e');
      return false;
    }
  }

  void disposeStethStream() {
    _stethStream?.dispose();
    _stethStream = null;
  }

  // ==================== Simulation Mode ====================

  /// กำลัง simulate stethoscope ด้วย asset ไหน
  String? _simAsset;
  String? get simAsset => _simAsset;
  bool get isSimulating => _simPlayer.state == PlayerState.playing;

  final AudioPlayer _simPlayer = AudioPlayer();
  HeartPosition _simPosition = HeartPosition.aortic;
  HeartPosition get simPosition => _simPosition;

  String _simVariant = 'best'; // default = top score จาก analysis
  String get simVariant => _simVariant;

  AudioService() {
    _simPlayer.onPlayerStateChanged.listen((_) => notifyListeners());
    _simPlayer.setReleaseMode(ReleaseMode.loop); // เล่นวนซ้ำ
  }

  /// เลือกตำแหน่งหัวใจที่จะ simulate
  void setSimPosition(HeartPosition pos) {
    _simPosition = pos;
    // reset variant ถ้าไม่มีใน list
    if (!pos.variants.contains(_simVariant)) {
      _simVariant = pos.variants.first;
    }
    notifyListeners();
    if (isSimulating) _playSimulation();
  }

  void setSimVariant(String v) {
    _simVariant = v;
    notifyListeners();
    if (isSimulating) _playSimulation();
  }

  /// เริ่ม/หยุด simulation
  Future<void> toggleSimulation() async {
    if (isSimulating) {
      await _simPlayer.stop();
      await stopSimAudio(); // หยุด inject WebRTC + คืน mic track
      _simAsset = null;
    } else {
      await _playSimulation();
    }
    notifyListeners();
  }

  Future<void> _playSimulation() async {
    final asset = _simPosition.assetPath(_simVariant);
    _simAsset = asset;
    // เล่น local (ให้คนไข้ได้ยินด้วย)
    await _simPlayer.play(
      AssetSource(asset.replaceFirst('assets/', '')),
    );
    // inject เข้า WebRTC track → หมอได้ยิน
    // Flutter web วาง asset ที่ /assets/assets/... จึงต้องเพิ่ม prefix
    await startSimAudio('assets/$asset');
  }

  @override
  void dispose() {
    _simPlayer.dispose();
    _stethStream?.dispose();
    super.dispose();
  }
}
