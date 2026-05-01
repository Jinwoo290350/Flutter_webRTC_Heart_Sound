// Web implementation: เรียก JS functions ที่ defined ใน index.html
import 'dart:js_interop';

@JS('startSimAudio')
external JSPromise _jsStartSim(JSString path);

@JS('stopSimAudio')
external JSPromise _jsStopSim();

@JS('setHeartMode')
external void _jsSetHeartMode(JSBoolean enabled);

@JS('_retrySimInject')
external JSPromise _jsRetryInject();

@JS('setHeartBoost')
external void _jsSetHeartBoost(JSNumber db);

@JS('playReference')
external void _jsPlayReference(JSString path);

@JS('stopReference')
external void _jsStopReference();

@JS('downloadRecording')
external void _jsDownloadRecording(JSString blobUrl, JSString filename);

@JS('startJsRecording')
external JSPromise<JSString> _jsStartJsRecording();

@JS('stopJsRecording')
external void _jsStopJsRecording();

@JS('startPcmCapture')
external JSPromise _jsStartPcmCapture(JSString? deviceId);

@JS('stopPcmCapture')
external JSPromise _jsStopPcmCapture();

@JS('stopPcmPlayback')
external void _jsStopPcmPlayback();

@JS('setPcmPlaybackMuted')
external void _jsSetPcmPlaybackMuted(JSBoolean muted);

@JS('setRemoteAudioMuted')
external void _jsSetRemoteAudioMuted(JSBoolean muted);

Future<void> startSimAudio(String path) async {
  try { await _jsStartSim(path.toJS).toDart; } catch (_) {}
}

Future<void> stopSimAudio() async {
  try { await _jsStopSim().toDart; } catch (_) {}
}

void setHeartMode(bool enabled) {
  try { _jsSetHeartMode(enabled.toJS); } catch (_) {}
}

Future<void> retrySimInject() async {
  try { await _jsRetryInject().toDart; } catch (_) {}
}

void setHeartBoost(double db) {
  try { _jsSetHeartBoost(db.toJS); } catch (_) {}
}

void playReference(String path) {
  try { _jsPlayReference(path.toJS); } catch (_) {}
}

void stopReference() {
  try { _jsStopReference(); } catch (_) {}
}

void downloadRecording(String blobUrl, String filename) {
  try { _jsDownloadRecording(blobUrl.toJS, filename.toJS); } catch (_) {}
}

Future<String> startJsRecording() async {
  try {
    final result = await _jsStartJsRecording().toDart;
    return result.toDart;  // JSString → Dart String (blob URL)
  } catch (e) { return ''; }
}

void stopJsRecording() {
  try { _jsStopJsRecording(); } catch (_) {}
}

Future<void> startPcmCapture({String? deviceId}) async {
  try { await _jsStartPcmCapture(deviceId?.toJS).toDart; } catch (_) {}
}

Future<void> stopPcmCapture() async {
  try { await _jsStopPcmCapture().toDart; } catch (_) {}
}

void stopPcmPlayback() {
  try { _jsStopPcmPlayback(); } catch (_) {}
}

void setPcmPlaybackMuted(bool muted) {
  try { _jsSetPcmPlaybackMuted(muted.toJS); } catch (_) {}
}

void setRemoteAudioMuted(bool muted) {
  try { _jsSetRemoteAudioMuted(muted.toJS); } catch (_) {}
}
