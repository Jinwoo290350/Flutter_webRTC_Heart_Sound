# Roadmap — Future Enhancements

ฟีเจอร์ที่ยังไม่ implement แต่อยากเพิ่มในอนาคต — เรียงตาม priority

---

## 🎯 High Priority

### 1. Download recording as WAV

ปัจจุบัน recording = WebM/Opus blob URL ใน memory. refresh page แล้วหาย

**Plan:**
- เพิ่มปุ่ม download ใน recordings list (doctor screen, bottom sheet)
- JS: convert blob → WAV format (decode webm → encode WAV header + PCM Int16)
- ใช้ `AudioContext.decodeAudioData(blobArrayBuffer)` → AudioBuffer → custom WAV encoder
- Trigger `<a download>` ใน DOM

**Files to change:**
- `web/index.html` — เพิ่ม `window.downloadRecordingAsWav(blobUrl, filename)` ที่ใช้ decodeAudioData + WAV encoder
- `lib/services/recording_service.dart` — เพิ่ม `downloadAsWav(HeartRecording)` method
- `lib/screens/doctor/doctor_call_screen.dart` — เพิ่มไอคอน ⬇️ ใน list item

**Reference WAV encoder:**
```js
function audioBufferToWav(buf) {
  var numCh = buf.numberOfChannels;
  var rate = buf.sampleRate;
  var len = buf.length * numCh * 2 + 44;
  var ab = new ArrayBuffer(len);
  var view = new DataView(ab);
  // ... RIFF header + PCM Int16 samples
}
```

---

### 2. Native iOS/Android support — heart sound

ปัจจุบัน heart sound ใช้ได้แค่ web เพราะใช้ JS interop (AudioWorklet, getUserMedia constraints, MediaRecorder)

**Plan:**
- **iOS/Android**: ใช้ `record` package (^6.2.0) + custom PCM extraction
- ขอ mic ผ่าน `permission_handler` → `Permission.microphone.request()`
- ใช้ `flutter_webrtc.MediaStream.getUserMedia(stethoscopeConstraints)` แบบ Phase 2 เดิม
- เพิ่ม `flutter_webrtc.RTCDataChannel.send(Uint8List)` ส่ง PCM ผ่าน native binding
- Bass boost: ใช้ `audio_session` + DSP filter (ใช้ Web Audio analog บน native)

**Files to change:**
- `lib/services/webrtc_service.dart` — เพิ่ม `startNativePcmCapture()` + `_pcmRecorder` (record package)
- `lib/services/native_audio_service.dart` (new) — DSP filter, PCM ring buffer, playback via `audioplayers`
- `pubspec.yaml` — re-add `record: ^6.2.0`, `audioplayers: ^6.0.0`, `permission_handler` (มีอยู่แล้ว)
- Android `AndroidManifest.xml` — `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS` permissions
- iOS `Info.plist` — `NSMicrophoneUsageDescription`

**Note:** ตามที่ค้นพบเดิม (Test01-03), Android `AudioRecord` capture **ไม่ได้** จาก WebRTC remote audio. ต้องส่ง PCM ผ่าน DC แทน. ดู `Test04` ใน history ที่ผ่าน

---

### 3. Firebase Storage upload — persist recordings

ปัจจุบัน blob in-memory — หายเมื่อ refresh

**Plan:**
- Doctor record → blob → upload to Firebase Storage path `recordings/{roomId}/{timestamp}.webm`
- Save metadata ใน Firestore `recordings/{recordingId}` (label, position, blobUrl, doctorId, patientId, createdAt)
- Doctor screen: ⬆ upload button ใน list item
- Doctor home screen: list ของ past recordings ดึงจาก Firestore

**Files to change:**
- `pubspec.yaml` — re-add `firebase_storage: ^12.0.0`
- `lib/services/recording_service.dart` — เพิ่ม `uploadToCloud(HeartRecording)` method
- `lib/services/cloud_recording_service.dart` (new) — Firestore CRUD + Storage upload
- `lib/screens/doctor/recordings_list_screen.dart` (new) — past recordings browser

**Risks:**
- Firebase Storage free tier มี 5GB quota → ระวัง
- Auth: ต้องมี Firebase Auth ก่อนถึง upload ได้

---

## ⚙️ Medium Priority

### 4. Bass boost slider (variable, not just on/off)

ปัจจุบัน Bass boost = on/off (lowshelf +6dB @ 200Hz)

**Plan:**
- Slider 0-12dB (default 6dB)
- Real-time adjust `_pcmBassFilter.gain.value`
- เก็บค่าใน localStorage (per-doctor preference)
- **สำคัญ:** Bass boost ต้อง OFF ตอน record (medical fidelity per CLAUDE.md)

**Files to change:**
- `web/index.html` — `window.setBassBoostLevel(db)` รับ 0-12
- `lib/services/_audio_js_web.dart` — เพิ่ม `setBassBoostLevel(double)` binding
- `lib/screens/doctor/doctor_call_screen.dart` — Slider widget ใน heart banner หรือ separate sheet
- Recording start → auto setBassBoostLevel(0)

---

### 5. Audio quality dashboard (real-time stats)

WebRTC มี `getStats()` ให้ดู bitrate, packet loss, jitter

**Plan:**
- Doctor screen: small overlay แสดง stats
  - Opus: bitrate (kbps), jitter (ms), packet loss (%)
  - PCM DC: sent/received bytes, current buffer size
- Update ทุก 1 วินาที จาก `pc.getStats()`
- ใช้สำหรับ debug + medical confidence (low jitter = trusted)

**Files to change:**
- `lib/services/webrtc_service.dart` — เพิ่ม `Stream<CallStats> get statsStream`
- `lib/widgets/stats_overlay.dart` (new) — StreamBuilder + Card UI

---

### 6. Bilateral mute option (configurable)

ปัจจุบัน mute = local only. บางคนอยากกดมุดเงียบทั้ง 2 ฝั่งด้วยปุ่มเดียว

**Plan:**
- Settings: "Bilateral mute" toggle (default off)
- เมื่อเปิด: กด 🔊 mute → ส่ง control DC message → peer's playback auto-mute ด้วย
- Reuse control DataChannel (มีอยู่แล้ว) ส่ง `{type: 'muteAll', muted: true}`

**Files to change:**
- `web/index.html` + `webrtc_service.dart` — handle `muteAll` control message
- `lib/screens/.../settings_dialog.dart` (new) — toggle UI

---

## 🔧 Low Priority / Nice to Have

### 7. Recording playback in-app (proper UI)

ตอนนี้ doctor list แสดง blob URL ใน dialog แบบ raw. ควรมี `<audio>` element player พร้อม seek bar + play/pause

**Plan:**
- ใช้ `audioplayers` package OR `<audio>` element ผ่าน HTML widget
- Web: ใช้ HTMLAudioElement + Streaming blob
- Native: `audioplayers` UrlSource

---

### 8. STUN/TURN configuration

ปัจจุบันใช้ Google STUN + Open Relay TURN (free, public)

**Plan:**
- Self-hosted TURN server (coturn) สำหรับ production
- Firebase Functions endpoint คืน credentials ที่ rotate

---

### 9. Multi-position recording session

ปัจจุบัน record 1 ครั้ง = 1 file. หมอต้องการฟัง 4 ตำแหน่ง (Aortic/Mitral/Pulmonary/Tricuspid) ใน session เดียว

**Plan:**
- "Multi-position session" mode: หมอกดเริ่ม → patient ฟังตำแหน่งละ 10-15 วินาที → auto-advance → จบที่ 4 ตำแหน่ง
- บันทึก 4 ไฟล์ + metadata: position
- ดูได้ใน list grouped by session

---

### 10. Heart sound analysis (post-recording)

นำ heart sound analysis Python script ที่มีอยู่ (`audio_compare.py`, `heart_sound_analysis.ipynb`) มา integrate

**Plan:**
- Backend Python service (Flask/FastAPI) รับ WAV → analyze → return PSD, S1/S2 timing, murmur detection
- Doctor screen: "วิเคราะห์เสียงนี้" button → upload to backend → show charts (waterfall, FFT)
- Reference: `Heart_sound/` folder ที่มี analysis scripts อยู่แล้ว

---

### 11. WebSocket signaling fallback

Firestore signaling มี latency 100-500ms. WebSocket จะเร็วกว่า (~10-50ms)

**Plan:**
- Self-hosted signaling server (Node.js + ws)
- Fallback: Firestore ถ้า WebSocket ไม่ available
- Reuse Firebase Auth สำหรับ WebSocket auth

---

### 12. PWA + Offline mode

Patient app เป็น PWA (installable, offline-capable)

**Plan:**
- เพิ่ม service worker (Workbox) cache assets + Flutter web shell
- Manifest update — icon, theme color, standalone display
- Cache strategy: stale-while-revalidate สำหรับ assets, network-first สำหรับ API

---

## 📊 Performance Targets

- Voice latency: < 100ms one-way
- Heart sound latency: < 300ms (acceptable for diagnostic)
- Bass loss (S1/S2 60-150Hz): < 6dB (medical fidelity threshold per CLAUDE.md)
- Voice quality: MOS ≥ 4.0 (Line/IG-grade)
- Recording file size: < 500 KB / 30 seconds

---

## ✅ Done (สำเร็จแล้ว)

- [x] Video call (PeerConnection + Firestore signaling + ICE restart)
- [x] Voice (Opus fullband + `usedtx=0` กันเสียงตัดท้าย)
- [x] Heart sound dual mode (🎵 Sample WAV / 🩺 Live mic filters OFF)
- [x] PCM DataChannel transmission (Int16 768 kbps, jitter buffer 160ms)
- [x] Recording (MediaRecorder webm/opus → blob list)
- [x] 3 separate mute (Mic / 🔊 Opus / ❤️ Heart) — local-only + cooperative `stopHeart`
- [x] Patient mute parity (5 ปุ่ม รวม 🔊 Opus mute)
- [x] Doctor heart banner + Bass boost on/off
- [x] Auto cache-bust ใน `start_test_server.sh`
- [x] Auto-unmute doctor PCM เมื่อ patient restart heart sound
