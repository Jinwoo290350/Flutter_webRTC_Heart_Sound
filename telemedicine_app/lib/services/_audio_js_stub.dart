// Stub สำหรับ platform ที่ไม่ใช่ web (Android, iOS, desktop)
Future<void> startSimAudio(String path) async {}
Future<void> stopSimAudio() async {}
void setHeartMode(bool enabled) {}
Future<void> retrySimInject() async {}
void setHeartBoost(double db) {}
void playReference(String path) {}
void stopReference() {}
