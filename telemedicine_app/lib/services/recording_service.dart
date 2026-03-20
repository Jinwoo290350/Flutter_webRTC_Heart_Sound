import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';

/// ข้อมูล recording ที่บันทึกไว้
class HeartRecording {
  final String id;
  final String label;       // เช่น "Recording 1"
  final String position;    // เช่น "Aortic"
  final DateTime timestamp;
  final String assetPath;   // path ของ asset (สำหรับ demo mode)

  HeartRecording({
    required this.id,
    required this.label,
    required this.position,
    required this.timestamp,
    required this.assetPath,
  });
}

/// RecordingService — จัดการ recording และ playback เสียงหัวใจ
///
/// Phase 3: หมอกดบันทึกเสียงหัวใจระหว่าง call แล้วเล่นซ้ำได้
/// Demo mode: ใช้ไฟล์ asset แทนการบันทึกจริง
class RecordingService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  // ==================== State ====================

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  String? _currentlyPlayingId;
  String? get currentlyPlayingId => _currentlyPlayingId;

  PlayerState _playerState = PlayerState.stopped;
  PlayerState get playerState => _playerState;

  Duration _position = Duration.zero;
  Duration get position => _position;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  double _volume = 1.0;
  double get volume => _volume;

  /// รายการ recordings ที่บันทึกไว้
  final List<HeartRecording> recordings = [];

  // ==================== Init ====================

  RecordingService() {
    _player.onPlayerStateChanged.listen((state) {
      _playerState = state;
      if (state == PlayerState.completed) _currentlyPlayingId = null;
      notifyListeners();
    });
    _player.onPositionChanged.listen((pos) {
      _position = pos;
      notifyListeners();
    });
    _player.onDurationChanged.listen((dur) {
      _duration = dur;
      notifyListeners();
    });
  }

  // ==================== Recording ====================

  /// เริ่มบันทึก (demo: สร้าง recording entry ไว้ก่อน)
  void startRecording(String position) {
    _isRecording = true;
    notifyListeners();
    debugPrint('RecordingService: started recording [$position]');
  }

  /// หยุดบันทึกและเพิ่มเข้า list
  /// [assetPath]: path ของ asset file ที่จะใช้เล่น (demo mode)
  void stopRecording(String position, String assetPath) {
    if (!_isRecording) return;
    _isRecording = false;

    final recording = HeartRecording(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      label: 'Recording ${recordings.length + 1}',
      position: position,
      timestamp: DateTime.now(),
      assetPath: assetPath,
    );
    recordings.insert(0, recording); // ใหม่สุดขึ้นก่อน
    notifyListeners();
    debugPrint('RecordingService: saved recording [${recording.label}]');
  }

  /// ลบ recording
  void deleteRecording(String id) {
    recordings.removeWhere((r) => r.id == id);
    if (_currentlyPlayingId == id) {
      _player.stop();
      _currentlyPlayingId = null;
    }
    notifyListeners();
  }

  // ==================== Playback ====================

  /// เล่น recording จาก asset path
  Future<void> play(HeartRecording recording) async {
    _currentlyPlayingId = recording.id;
    await _player.setVolume(_volume);
    await _player.play(
      AssetSource(recording.assetPath.replaceFirst('assets/', '')),
    );
    notifyListeners();
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.resume();
  }

  Future<void> stop() async {
    await _player.stop();
    _currentlyPlayingId = null;
    _position = Duration.zero;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> setVolume(double vol) async {
    _volume = vol.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    notifyListeners();
  }

  bool isPlaying(String id) =>
      _currentlyPlayingId == id && _playerState == PlayerState.playing;

  bool isPaused(String id) =>
      _currentlyPlayingId == id && _playerState == PlayerState.paused;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
