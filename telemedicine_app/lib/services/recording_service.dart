import 'package:flutter/foundation.dart';
import '_audio_js_stub.dart'
    if (dart.library.js_interop) '_audio_js_web.dart' as audio_js;

/// Heart sound recording (web only — uses MediaRecorder on remote audio track)
class HeartRecording {
  final String id;
  final String label;
  final String blobUrl;
  final DateTime createdAt;
  HeartRecording({
    required this.id,
    required this.label,
    required this.blobUrl,
    required this.createdAt,
  });
}

class RecordingService extends ChangeNotifier {
  final List<HeartRecording> _recordings = [];
  List<HeartRecording> get recordings => List.unmodifiable(_recordings);

  bool _recording = false;
  bool get isRecording => _recording;

  String? _pendingLabel;

  Future<void> start(String label) async {
    if (!kIsWeb || _recording) return;
    try {
      await audio_js.startRecording();
      _recording = true;
      _pendingLabel = label;
      notifyListeners();
    } catch (e) {
      debugPrint('[RecordingService] start error: $e');
    }
  }

  Future<void> stop() async {
    if (!kIsWeb || !_recording) return;
    try {
      final blobUrl = await audio_js.stopRecording();
      if (blobUrl.isNotEmpty) {
        _recordings.insert(0, HeartRecording(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          label: _pendingLabel ?? 'Recording ${_recordings.length + 1}',
          blobUrl: blobUrl,
          createdAt: DateTime.now(),
        ));
      }
    } catch (e) {
      debugPrint('[RecordingService] stop error: $e');
    } finally {
      _recording = false;
      _pendingLabel = null;
      notifyListeners();
    }
  }

  void remove(String id) {
    _recordings.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  void clear() {
    _recordings.clear();
    notifyListeners();
  }
}
