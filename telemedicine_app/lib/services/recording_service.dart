import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

/// ข้อมูล recording ที่บันทึกไว้
class HeartRecording {
  final String id;
  final String label;
  final String position;
  final DateTime timestamp;
  final String path;     // blob URL (web), file path (native), หรือ asset path (fallback)
  final bool isAsset;   // true = ใช้ AssetSource แทน

  const HeartRecording({
    required this.id,
    required this.label,
    required this.position,
    required this.timestamp,
    required this.path,
    this.isAsset = false,
  });
}

/// RecordingService — บันทึกเสียงหัวใจจาก WebRTC remote stream และ playback
///
/// Web: ใช้ MediaRecorder.startWeb(stream) → stop() คืน blob URL
/// Native: fallback ใช้ asset sample (Phase 2: MediaRecorder ผ่าน OUTPUT channel)
class RecordingService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  // ==================== Recording state ====================

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  MediaRecorder? _mediaRecorder;
  String? _nativePath;   // native: temp file path

  // ==================== Playback state ====================

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

  /// รายการ recordings ที่บันทึกไว้ (ใหม่สุดขึ้นก่อน)
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

  /// เริ่มบันทึกเสียงหัวใจ
  /// [position]: ชื่อตำแหน่ง เช่น "Aortic"
  /// [stream]: remote MediaStream จาก WebRTC (ถ้า null → demo mode)
  Future<void> startRecording(String position, {MediaStream? stream}) async {
    if (_isRecording) return;
    _isRecording = true;
    notifyListeners();

    if (stream == null) {
      debugPrint('RecordingService: no stream — demo mode [$position]');
      return;
    }

    try {
      _mediaRecorder = MediaRecorder();

      if (kIsWeb) {
        // Web: record จาก remote stream โดยตรง → stop() คืน blob URL
        _mediaRecorder!.startWeb(stream, mimeType: 'audio/webm');
        debugPrint('RecordingService: web recording started [$position]');
      } else {
        // Native: record จาก audio output (เสียงที่เล่นออก speaker/earphone)
        final dir = await getTemporaryDirectory();
        _nativePath = '${dir.path}/heart_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await _mediaRecorder!.start(
          _nativePath!,
          audioChannel: RecorderAudioChannel.OUTPUT,
        );
        debugPrint('RecordingService: native recording → $_nativePath');
      }
    } catch (e) {
      debugPrint('RecordingService: start error: $e — falling back to demo mode');
      _mediaRecorder = null;
      _nativePath = null;
    }
  }

  /// หยุดบันทึกและเพิ่มเข้า list
  /// [position]: ชื่อตำแหน่ง
  Future<void> stopRecording(String position) async {
    if (!_isRecording) return;
    _isRecording = false;

    String path = '';
    bool isAsset = false;

    if (_mediaRecorder != null) {
      try {
        final result = await _mediaRecorder!.stop();
        if (kIsWeb && result != null) {
          // Web: result คือ blob URL
          path = result.toString();
          debugPrint('RecordingService: web blob URL → $path');
        } else if (!kIsWeb && _nativePath != null) {
          path = _nativePath!;
          debugPrint('RecordingService: native file → $path');
        }
      } catch (e) {
        debugPrint('RecordingService: stop error: $e');
      }
      _mediaRecorder = null;
      _nativePath = null;
    }

    // Fallback: ถ้า recording ล้มเหลว → ใช้ best sample แทน
    if (path.isEmpty) {
      final assetName = position.toLowerCase();
      path = 'assets/heart_sounds/${assetName}_best.wav';
      isAsset = true;
      debugPrint('RecordingService: fallback asset → $path');
    }

    final recording = HeartRecording(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      label: 'Recording ${recordings.length + 1}',
      position: position,
      timestamp: DateTime.now(),
      path: path,
      isAsset: isAsset,
    );
    recordings.insert(0, recording);
    notifyListeners();
    debugPrint('RecordingService: saved [${recording.label}] isAsset=$isAsset');
  }

  /// ยกเลิก recording โดยไม่บันทึก
  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    try {
      await _mediaRecorder?.stop();
    } catch (_) {}
    _mediaRecorder = null;
    _nativePath = null;
    notifyListeners();
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

  Future<void> play(HeartRecording recording) async {
    _currentlyPlayingId = recording.id;
    await _player.setVolume(_volume);

    if (recording.isAsset) {
      await _player.play(AssetSource(recording.path.replaceFirst('assets/', '')));
    } else if (recording.path.startsWith('blob:') ||
        recording.path.startsWith('http://') ||
        recording.path.startsWith('https://')) {
      // Web blob URL หรือ HTTP URL
      await _player.play(UrlSource(recording.path));
    } else {
      // Native file path
      await _player.play(DeviceFileSource(recording.path));
    }
    notifyListeners();
  }

  Future<void> pause() async => _player.pause();

  Future<void> resume() async => _player.resume();

  Future<void> stop() async {
    await _player.stop();
    _currentlyPlayingId = null;
    _position = Duration.zero;
    notifyListeners();
  }

  Future<void> seek(Duration position) async => _player.seek(position);

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
    _mediaRecorder = null;
    _player.dispose();
    super.dispose();
  }
}
