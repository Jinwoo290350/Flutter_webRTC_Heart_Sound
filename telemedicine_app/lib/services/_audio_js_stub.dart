// Stub สำหรับ platform ที่ไม่ใช่ web
void setOpusMuted(bool muted) {}
void setPcmMuted(bool muted) {}
Future<void> startSimAudio(String assetPath) async {}
Future<void> stopSimAudio() async {}
void setBassBoost(bool enabled) {}
Future<void> startStethMic() async {}
Future<void> stopStethMic() async {}
Future<void> startRecording() async {}
Future<String> stopRecording() async => '';
