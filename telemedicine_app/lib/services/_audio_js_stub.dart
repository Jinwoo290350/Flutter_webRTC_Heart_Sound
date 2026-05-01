// Stub สำหรับ platform ที่ไม่ใช่ web (Android, iOS, desktop)
Future<void> startSimAudio(String path) async {}
Future<void> stopSimAudio() async {}
void setHeartMode(bool enabled) {}
Future<void> retrySimInject() async {}
void setHeartBoost(double db) {}
void playReference(String path) {}
void stopReference() {}
void downloadRecording(String blobUrl, String filename) {}
Future<String> startJsRecording() async => '';
void stopJsRecording() {}
Future<void> startPcmCapture({String? deviceId}) async {}
Future<void> stopPcmCapture() async {}
void stopPcmPlayback() {}
void setPcmPlaybackMuted(bool muted) {}
void setRemoteAudioMuted(bool muted) {}
