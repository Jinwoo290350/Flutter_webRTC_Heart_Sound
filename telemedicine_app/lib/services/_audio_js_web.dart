// Web implementation: เรียก JS function ที่อยู่ใน index.html
import 'dart:js_interop';

@JS('setOpusMuted')
external void _jsSetOpusMuted(JSBoolean muted);

@JS('setPcmMuted')
external void _jsSetPcmMuted(JSBoolean muted);

@JS('startSimAudio')
external JSPromise _jsStartSimAudio(JSString assetPath);

@JS('stopSimAudio')
external JSPromise _jsStopSimAudio();

@JS('setBassBoost')
external void _jsSetBassBoost(JSBoolean enabled);

@JS('startStethMic')
external JSPromise _jsStartStethMic();

@JS('stopStethMic')
external JSPromise _jsStopStethMic();

@JS('startRecording')
external JSPromise _jsStartRecording();

@JS('stopRecording')
external JSPromise<JSString> _jsStopRecording();

@JS('setHalfDuplex')
external void _jsSetHalfDuplex(JSBoolean enabled);

void setOpusMuted(bool muted) {
  try { _jsSetOpusMuted(muted.toJS); } catch (_) {}
}

void setPcmMuted(bool muted) {
  try { _jsSetPcmMuted(muted.toJS); } catch (_) {}
}

Future<void> startSimAudio(String assetPath) async {
  try { await _jsStartSimAudio(assetPath.toJS).toDart; } catch (_) {}
}

Future<void> stopSimAudio() async {
  try { await _jsStopSimAudio().toDart; } catch (_) {}
}

void setBassBoost(bool enabled) {
  try { _jsSetBassBoost(enabled.toJS); } catch (_) {}
}

Future<void> startStethMic() async {
  try { await _jsStartStethMic().toDart; } catch (_) {}
}

Future<void> stopStethMic() async {
  try { await _jsStopStethMic().toDart; } catch (_) {}
}

Future<void> startRecording() async {
  try { await _jsStartRecording().toDart; } catch (_) {}
}

/// returns blob URL of recorded webm/opus
Future<String> stopRecording() async {
  try {
    final result = await _jsStopRecording().toDart;
    return result.toDart;
  } catch (_) { return ''; }
}

void setHalfDuplex(bool enabled) {
  try { _jsSetHalfDuplex(enabled.toJS); } catch (_) {}
}
