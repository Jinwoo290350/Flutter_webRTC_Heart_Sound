import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '_audio_js_stub.dart'
    if (dart.library.js_interop) '_audio_js_web.dart';

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

  AudioRecorder? _activeRecorder;  // native AudioRecord fallback
  String? _nativePath;             // native: temp file path
  Future<String>? _jsRecFuture;   // web: Promise จาก startJsRecording()

  // PCM DataChannel recording (native preferred path)
  List<double>? _pcmSamples;      // accumulated Float32 samples from DataChannel
  bool _usingPcmChannel = false;  // true = กำลัง record จาก DataChannel

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
  /// [stream]: remote MediaStream จาก WebRTC (web path)
  /// [dataChannel]: PCM DataChannel (native preferred — lossless)
  Future<void> startRecording(String position, {MediaStream? stream, RTCDataChannel? dataChannel}) async {
    if (_isRecording) return;
    _isRecording = true;
    notifyListeners();

    if (stream == null) {
      debugPrint('RecordingService: no stream — demo mode [$position]');
      return;
    }

    try {
      if (kIsWeb) {
        // Web: ใช้ JS MediaRecorder record จาก remote video element โดยตรง
        // startJsRecording() คือ Promise ที่ resolve เป็น blob URL เมื่อ stop
        _jsRecFuture = startJsRecording();
        debugPrint('RecordingService: JS recording started [$position]');
      } else {
        // Native: ถ้ามี PCM DataChannel → ใช้ path นี้ก่อน (lossless, ไม่ผ่าน Android audio stack)
        if (dataChannel != null) {
          _pcmSamples = [];
          _usingPcmChannel = true;
          dataChannel.onMessage = (msg) {
            if (_pcmSamples == null) return;
            final bytes = msg.binary;
            if (bytes.isNotEmpty) {
              final floats = bytes.buffer.asFloat32List(
                  bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
              _pcmSamples!.addAll(floats);
            }
          };
          debugPrint('RecordingService: PCM DataChannel recording started [$position]');
        } else {
          // Fallback: AudioRecord — ใช้เมื่อไม่มี DataChannel
          _usingPcmChannel = false;
          final status = await Permission.microphone.request();
          if (!status.isGranted) throw Exception('mic permission denied: $status');

          final dir = await getTemporaryDirectory();
          _nativePath = '${dir.path}/heart_${DateTime.now().millisecondsSinceEpoch}.m4a';

          final sources = [
            AndroidAudioSource.voiceCommunication,
            AndroidAudioSource.voiceDownlink,
            AndroidAudioSource.mic,
            AndroidAudioSource.defaultSource,
          ];
          bool started = false;
          for (final source in sources) {
            final recorder = AudioRecorder();
            try {
              await recorder.start(
                RecordConfig(
                  encoder: AudioEncoder.aacLc,
                  sampleRate: 48000,
                  bitRate: 192000,
                  numChannels: 1,
                  noiseSuppress: false,
                  echoCancel: false,
                  autoGain: false,
                  androidConfig: AndroidRecordConfig(audioSource: source),
                ),
                path: _nativePath!,
              );
              await _activeRecorder?.dispose();
              _activeRecorder = recorder;
              debugPrint('RecordingService: AudioRecord source=$source → $_nativePath');
              started = true;
              break;
            } catch (e) {
              debugPrint('RecordingService: source $source failed: $e — trying next');
              try { await recorder.dispose(); } catch (_) {}
            }
          }
          if (!started) throw Exception('all audio sources failed');
        }
      }
    } catch (e, st) {
      debugPrint('RecordingService: start error: $e\n$st — falling back to demo mode');
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

    if (kIsWeb && _jsRecFuture != null) {
      try {
        stopJsRecording();                   // trigger onstop → resolves Promise
        path = await _jsRecFuture!;          // รอ blob URL
        _jsRecFuture = null;
        debugPrint('RecordingService: JS blob URL → "$path" (len=${path.length})');
      } catch (e, st) {
        debugPrint('RecordingService: JS stop error: $e\n$st');
        _jsRecFuture = null;
      }
    } else if (_usingPcmChannel && _pcmSamples != null) {
      // PCM DataChannel path — เขียน raw Float32 samples เป็น WAV file
      try {
        final samples = _pcmSamples!;
        _pcmSamples = null;
        _usingPcmChannel = false;
        if (samples.isNotEmpty) {
          final dir = await getTemporaryDirectory();
          final wavPath = '${dir.path}/heart_${DateTime.now().millisecondsSinceEpoch}.wav';
          await _writeWav(wavPath, samples, sampleRate: 48000);
          final f = File(wavPath);
          if (await f.exists() && (await f.length()) > 44) {
            path = wavPath;
            debugPrint('RecordingService: PCM WAV → $path (${await f.length()} bytes, ${samples.length} samples)');
          }
        } else {
          debugPrint('RecordingService: PCM samples empty → fallback');
        }
      } catch (e, st) {
        debugPrint('RecordingService: PCM write error: $e\n$st');
        _pcmSamples = null;
        _usingPcmChannel = false;
      }
    } else if (_nativePath != null) {
      try {
        final result = await _activeRecorder?.stop();
        final candidate = result ?? _nativePath!;
        debugPrint('RecordingService: stop returned → "$candidate"');
        final f = File(candidate);
        if (await f.exists() && (await f.length()) > 0) {
          path = candidate;
          debugPrint('RecordingService: native file → $path (${await f.length()} bytes)');
        } else {
          debugPrint('RecordingService: file empty/missing → fallback');
        }
      } catch (e, st) {
        debugPrint('RecordingService: stop error: $e\n$st');
      }
      await _activeRecorder?.dispose();
      _activeRecorder = null;
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
    if (kIsWeb) {
      stopJsRecording();
      _jsRecFuture = null;
    } else {
      try { await _activeRecorder?.cancel(); } catch (_) {}
      await _activeRecorder?.dispose();
      _activeRecorder = null;
      _nativePath = null;
    }
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

  /// เขียน PCM Float32 samples เป็น WAV file (16-bit PCM, mono)
  /// เพิ่ม silence padding ต้นไฟล์ 0.5s เพื่อชดเชย Firestore latency
  Future<void> _writeWav(String path, List<double> samples, {int sampleRate = 48000}) async {
    const paddingSec = 0.5;
    final paddingSamples = (sampleRate * paddingSec).round();
    final allSamples = [...List.filled(paddingSamples, 0.0), ...samples];
    final numSamples = allSamples.length;
    final dataSize = numSamples * 2; // 16-bit = 2 bytes per sample
    final fileSize = 44 + dataSize;

    final buf = ByteData(fileSize);
    int o = 0;

    // RIFF header
    buf.setUint8(o++, 0x52); buf.setUint8(o++, 0x49); // 'R','I'
    buf.setUint8(o++, 0x46); buf.setUint8(o++, 0x46); // 'F','F'
    buf.setUint32(o, fileSize - 8, Endian.little); o += 4;
    buf.setUint8(o++, 0x57); buf.setUint8(o++, 0x41); // 'W','A'
    buf.setUint8(o++, 0x56); buf.setUint8(o++, 0x45); // 'V','E'

    // fmt chunk
    buf.setUint8(o++, 0x66); buf.setUint8(o++, 0x6D); // 'f','m'
    buf.setUint8(o++, 0x74); buf.setUint8(o++, 0x20); // 't',' '
    buf.setUint32(o, 16, Endian.little); o += 4;       // chunk size
    buf.setUint16(o, 1, Endian.little); o += 2;        // PCM
    buf.setUint16(o, 1, Endian.little); o += 2;        // mono
    buf.setUint32(o, sampleRate, Endian.little); o += 4;
    buf.setUint32(o, sampleRate * 2, Endian.little); o += 4; // byte rate
    buf.setUint16(o, 2, Endian.little); o += 2;        // block align
    buf.setUint16(o, 16, Endian.little); o += 2;       // bits per sample

    // data chunk
    buf.setUint8(o++, 0x64); buf.setUint8(o++, 0x61); // 'd','a'
    buf.setUint8(o++, 0x74); buf.setUint8(o++, 0x61); // 't','a'
    buf.setUint32(o, dataSize, Endian.little); o += 4;

    // samples: Float32 → Int16
    for (final s in allSamples) {
      final clamped = s.clamp(-1.0, 1.0);
      final i16 = (clamped * 32767).round();
      buf.setInt16(o, i16, Endian.little); o += 2;
    }

    await File(path).writeAsBytes(buf.buffer.asUint8List());
  }

  @override
  void dispose() {
    _activeRecorder?.dispose();
    _player.dispose();
    super.dispose();
  }
}
