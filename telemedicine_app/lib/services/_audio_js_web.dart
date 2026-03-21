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
