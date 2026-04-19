# Telemedicine Heart Sound Streaming

ระบบ telemedicine ที่ให้แพทย์และผู้ป่วย video call พร้อมส่งเสียงหัวใจจาก digital stethoscope (Thinklabs One) ผ่าน WebRTC แบบ real-time แพทย์สามารถบันทึกและเล่นซ้ำเสียงหัวใจได้

---

## ผลการทดสอบคุณภาพเสียง (Audio Quality Results)

เกณฑ์ทางการแพทย์: S1/S2 band (60–150 Hz) ต้องสูญเสียไม่เกิน **−6 dB** จากต้นฉบับ

| ชุดทดสอบ | เทคโนโลยี | PC→PC | PC→Web | PC→App |
|---------|-----------|-------|--------|--------|
| Test01 | WebRTC Opus (std) | +1.8 dB ✅ | +1.8 dB ✅ | −18.6 dB ❌ |
| Test02 | DataChannel PCM | +1.8 dB ✅ | +1.8 dB ✅ | −8.5 dB ❌ |
| Test03 | PCM + Auto-sync | +1.8 dB ✅ | +1.8 dB ✅ | −4.5 dB ✅ |
| **Test04** | **PCM + Lifecycle fix** | **+1.8 dB ✅** | **+1.8 dB ✅** | **−4.1 dB ✅** |

**ทุก path ผ่านเกณฑ์ทางการแพทย์แล้วใน Test04**

### Root Cause ของ PC→App FAIL (Test01–02)

Android `AudioRecord` ไม่สามารถ capture เสียงที่รับจาก WebRTC ได้ — มันเข้าถึงแค่ microphone input เท่านั้น
**Solution:** ส่ง PCM Float32 ผ่าน WebRTC DataChannel → สะสม samples → เขียนเป็น WAV โดยตรง

---

## ปัญหาหลัก: WebRTC ทำลายเสียงหัวใจ

WebRTC ถูกออกแบบมาเพื่อเสียงพูดมนุษย์ (300–8,000 Hz) แต่เสียงหัวใจอยู่ที่ **20–500 Hz** ซึ่ง WebRTC audio pipeline ตัดทิ้งโดยอัตโนมัติ

| Filter | ผลกระทบต่อเสียงหัวใจ |
|--------|----------------------|
| HPF (High Pass Filter) | ตัดทุกอย่างต่ำกว่า ~300 Hz ทิ้ง |
| NS (Noise Suppression) | เรียนรู้ว่าเสียงหัวใจคือ "noise" แล้วค่อยๆ กดลง |
| AEC (Echo Cancellation) | ตัดเสียงที่ไม่ใช่เสียงพูดออก |
| AGC (Auto Gain Control) | ปรับ volume อัตโนมัติจนเสียงเบาหาย |

**สัญญาณอันตราย**: ถ้าเสียง stethoscope fade หายภายใน ~10 วินาที = NS กำลังเรียนรู้แล้วกดมัน

Android มีปัญหาพิเศษ: นอกจาก WebRTC filter แล้ว ยังมี hardware AEC ในชิปที่ปิดจาก code ไม่ได้ และ communication mode ที่ OS บังคับเปิดเมื่อใช้ WebRTC

---

## Solution ที่ implement แล้ว

### 1. ปิด WebRTC Audio Filter ทุกชั้น

```dart
// Channel เสียงหัวใจ — ปิด filter ทั้งหมด
final stethConstraints = {
  'audio': {
    'echoCancellation': {'exact': false},   // 'exact' สำคัญมากบน Android Chrome 72+
    'noiseSuppression': {'exact': false},   // แค่ false อาจไม่พอ ต้องใช้ {exact: false}
    'autoGainControl': {'exact': false},
    'googHighpassFilter': false,
    'googNoiseSuppression': false,
    'googAutoGainControl': false,
    'googEchoCancellation': false,
  },
  'video': false,
};
```

### 2. Configure OS Audio Session ก่อน WebRTC

ปิด voice processing ระดับ OS ก่อนที่ WebRTC จะเริ่ม ด้วย `audio_session` package:

- **iOS**: `AVAudioSessionMode.measurement` — ปิด AEC/NS/AGC ระดับ AVAudioSession ที่ WebKit ตั้งให้อัตโนมัติ
- **Android**: `AndroidAudioUsage.media` — หลีกเลี่ยง communication mode ที่บังคับ hardware AEC เปิด

### 3. Opus Fullband 48kHz

Opus ปกติ fallback เป็น narrowband (8kHz) เมื่อเจอ AEC เปิด ต้อง modify SDP บังคับ:

```dart
String forceOpusFullband(String sdp) {
  return sdp.replaceAllMapped(
    RegExp(r'(a=fmtp:\d+ .*)'),
    (m) => '${m[1]};maxplaybackrate=48000;sprop-maxcapturerate=48000',
  );
}
```

### 4. DataChannel PCM Recording (Doctor Side)

บน Android APK `AudioRecord` ไม่สามารถ capture WebRTC received audio ได้ จึงใช้วิธีส่ง raw PCM ผ่าน WebRTC DataChannel แทน:

```
Patient (simulation) ──Float32 chunks──▶ RTCDataChannel ──▶ Doctor accumulates ──▶ WAV file
```

- Patient ส่ง `Float32Array` ขนาด 4096 samples ต่อ chunk ผ่าน binary DataChannel
- Doctor สะสม samples ใน `List<double>` ระหว่าง recording
- เมื่อหยุด: แปลงเป็น 16-bit PCM → เขียน RIFF WAV header → บันทึกไฟล์
- มี 0.5s silence padding ชดเชย Firestore latency (~200–500ms)

### 5. Auto-sync: Patient → Doctor Recording

ผู้ป่วยกด Heart Mode → Firestore signal → หมอ auto-start recording:

```
Patient กด Heart Mode
    ├─ setHeartMode(true)   ← เขียน Firestore ก่อน (ลด latency)
    └─ toggleSimulation()   ← เปิดเสียงจริง

Doctor (listener)
    └─ listenForHeartMode() ← ใน _listenHeartMode() method (ไม่ใช่ใน build())
        ├─ check pcmChannel.state == RTCDataChannelOpen
        └─ startRecording(..., dataChannel: pcmChannel)
```

### 6. Web Audio API Injection (Web Platform)

สำหรับ simulation เสียงหัวใจบน web — inject เสียงเข้า RTCPeerConnection โดยตรง:

```
AudioContext → MediaElementSource (heart WAV) → MediaStreamDestination
    → replaceTrack() → PeerConnection → หมอได้ยินจริง
```

### 7. Bass Boost ฝั่งผู้รับ (แพทย์)

Web Audio API BiquadFilter chain บน `<video>` element ที่รับ remote stream:

```
RemoteStream → lowshelf +dB @ 500Hz → peaking @ 80Hz → peaking @ 200Hz → AudioOutput
```

ปรับ gain ได้ real-time ผ่าน slider 0–24dB ในหน้าจอแพทย์ (display aid เท่านั้น — ปิดเป็น 0dB เมื่อ record)

---

## Architecture

```
[ฝั่งคนไข้ — Android Tablet]

  Thinklabs One Stethoscope
       │ (3.5mm / USB-C via Thinklink)
       ▼
  Tablet Audio Input
       │
       ├─→ Channel 1: เสียงพูด
       │   AEC=ON, NS=ON, AGC=ON (เสียงพูดชัด)
       │
       └─→ Channel 2: เสียงหัวใจ (simulation WAV)
           AEC=OFF, NS=OFF, AGC=OFF, HPF=OFF
           Opus fullband 48kHz
           + PCM Float32 ผ่าน DataChannel
       │
       ▼
  WebRTC PeerConnection ──── Internet ────→ [ฝั่งแพทย์ — iPhone / Desktop]
  (+ Video + DataChannel)                   │
                                            ├─ Video: เห็นหน้าผู้ป่วย
                                            ├─ Audio: เสียงหัวใจ (Opus)
                                            └─ DataChannel: PCM Float32 → WAV recording
```

---

## Tech Stack

| Component | Technology | หมายเหตุ |
|-----------|-----------|---------|
| Framework | Flutter (Dart) | cross-platform iOS + Android + Web |
| WebRTC | `flutter_webrtc ^0.12` | native binding — ควบคุม audio pipeline ได้ทุกชั้น |
| Signaling | Firebase Firestore | real-time database แลก offer/answer/ICE + heartMode signal |
| STUN | Google STUN | `stun:stun.l.google.com:19302` (free) |
| Codec | Opus fullband 48kHz | บังคับผ่าน SDP modification |
| Audio OS Config | `audio_session ^0.1.21` | ปิด voice processing ระดับ OS |
| State | `provider ^6.0` | ChangeNotifier pattern |
| Stethoscope | Thinklabs One | analog 3.5mm → Thinklink → USB-C tablet |

---

## โครงสร้างโปรเจกต์

```
Flutter_webRTC_Heart/
├── README.md
├── webrtc_audio_quality.ipynb      # วิเคราะห์คุณภาพเสียง Test01-Test04
├── telemedicine_app/
│   ├── pubspec.yaml
│   ├── web/
│   │   └── index.html              # JS: Web Audio injection, bass boost, iOS unlock
│   └── lib/
│       ├── config/
│       │   ├── webrtc_config.dart  # ICE servers, constraints, Opus SDP
│       │   └── firebase_config.dart
│       ├── models/
│       │   └── call_state.dart     # enum: idle/calling/waiting/connected/ended/error
│       ├── services/
│       │   ├── webrtc_service.dart      # PeerConnection + dual-channel + AudioSession
│       │   ├── signaling_service.dart   # Firebase Firestore signaling + heartMode
│       │   ├── audio_service.dart       # simulation playback + mode switching
│       │   ├── recording_service.dart   # PCM DataChannel → WAV / web blob URL
│       │   ├── _audio_js_web.dart       # dart:js_interop → JS functions ใน index.html
│       │   └── _audio_js_stub.dart      # stub สำหรับ native platform
│       └── screens/
│           ├── patient/
│           │   └── patient_call_screen.dart  # เริ่มโทร + simulate stethoscope
│           └── doctor/
│               └── doctor_call_screen.dart   # รับสาย + heart mode + auto-record + playback
└── Heart_sound/                    # dataset (ไม่อยู่ใน git — ไฟล์ใหญ่)
```

---

## Quick Start

### 1. Firebase Setup

```bash
cd telemedicine_app
flutterfire configure --project=YOUR_FIREBASE_PROJECT
```

### 2. สร้าง `.env` file

```bash
# telemedicine_app/.env
FIREBASE_API_KEY=your_key
FIREBASE_PROJECT_ID=your_project
# ดู .env.example สำหรับรายละเอียดทั้งหมด
```

### 3. Run บน Browser

```bash
cd telemedicine_app
flutter pub get
flutter run -d chrome --web-renderer html \
  --dart-define=FIREBASE_API_KEY=your_key \
  --dart-define=FIREBASE_PROJECT_ID=your_project
```

### 4. Build APK

```bash
cd telemedicine_app
flutter build apk --release \
  --dart-define=FIREBASE_API_KEY=your_key \
  --dart-define=FIREBASE_PROJECT_ID=your_project
# output: build/app/outputs/flutter-apk/app-release.apk
```

### 5. ทดสอบข้ามอุปกรณ์ด้วย cloudflared tunnel

```bash
# Terminal 1: build + serve static
cd telemedicine_app && flutter build web --release
cd build/web && python3 -m http.server 8080

# Terminal 2: expose ด้วย cloudflared
/opt/homebrew/bin/cloudflared tunnel --url http://localhost:8080
```

เปิด URL บน iPhone / Android — ไม่ต้อง install อะไรเพิ่ม

---

## หน้าจอแพทย์ (Doctor UI)

| Feature | รายละเอียด |
|---------|-----------|
| Heart Mode | กดเพื่อเข้า/ออกโหมดฟังเสียงหัวใจ |
| Timer | นับเวลาที่ฟังเสียงหัวใจ (MM:SS) |
| Position Selector | เลือกตำแหน่งฟัง: Aortic / Mitral / Pulmonary / Tricuspid |
| Bass Boost | Slider 0–24dB ปรับ bass ฝั่งผู้รับ real-time (web เท่านั้น) |
| Reference Audio | เล่นเสียงหัวใจอ้างอิง (normal) เพื่อเปรียบเทียบ |
| Auto-Record | ผู้ป่วยกด Heart Mode → หมอ auto-start record ผ่าน Firestore signal |
| PCM DataChannel | indicator สีน้ำเงิน = DataChannel open พร้อมบันทึก WAV |
| Playback | เล่นซ้ำ recording พร้อม position label |

---

## Hardware Setup

```
Thinklabs One ──(3.5mm)──→ Thinklink adapter ──(USB-C)──→ Android Tablet
                                                               └─→ flutter_webrtc รับเป็น external mic input
```

Thinklabs One recommended setting: **Low Filter (30–500 Hz)** สำหรับเสียงหัวใจ

ฝั่งแพทย์ควรใช้ **headphones ที่ frequency response ลงถึง 20 Hz** (over-ear หรือ IEM) เพราะลำโพง tablet ไม่มี bass ทางกายภาพ

---

## Development Phases

| Phase | งาน | สถานะ |
|-------|-----|-------|
| Phase 1 | Basic video call (WebRTC + Firestore signaling) | ✅ Done |
| Phase 2 | ปิด filter + Opus fullband + simulation เสียงหัวใจ | ✅ Done |
| Phase 2.5 | Web Audio injection ผ่าน WebRTC, Bass Boost, AudioSession | ✅ Done |
| Phase 3 | Doctor UI: heart mode, timer, position, record, playback | ✅ Done |
| Phase 3.5 | DataChannel PCM recording — แก้ Android AudioRecord root cause | ✅ Done (Test03–04) |
| Phase 4 | ทดสอบกับ Thinklabs One จริงบน Android tablet | 🔄 Pending |

---

## สิ่งที่ยืนยันแล้ว (Verified)

- WebRTC connection ทำงานได้ระหว่างอุปกรณ์ 2 เครื่อง
- เสียงหัวใจ (simulation WAV) ส่งผ่าน WebRTC จริง ไม่ใช่แค่ local playback
- แพทย์ฝั่ง iPhone ได้ยินเสียงหัวใจโดยไม่ต้องใส่หูฟัง
- DataChannel PCM recording บน APK: S1/S2 loss = −4.1 dB ✅ (ผ่านเกณฑ์ −6 dB)
- Auto-sync: ผู้ป่วยกด → หมอ auto-record ผ่าน Firestore signal ทำงานได้
- ทุก 3 path (PC-PC, PC-Web, PC-App) ผ่านเกณฑ์ทางการแพทย์ใน Test04

## สิ่งที่ยังต้องทดสอบ

- **10-second fade test** — เสียง stethoscope จาก Thinklabs One จริงต้องไม่ fade หลัง 10 วินาที
- **Thinklabs One จริง** — ทดสอบ end-to-end กับ stethoscope และ Android tablet จริง (ไม่ใช่ simulation)
- **Hardware AEC** — ถ้า stethoscope audio ยังมีปัญหา อาจต้องส่ง PCM ผ่าน DataChannel ตั้งแต่ฝั่ง patient ด้วย

---

## Known Issues

1. **`{exact: false}` สำคัญมาก** — บน Android Chrome 72+ ใช้แค่ `false` อาจไม่ปิด filter จริง
2. **Android emulator ไม่มี USB audio** — ต้องทดสอบบนเครื่องจริงเท่านั้น
3. **ลำโพง tablet ไม่มี bass** — หมอต้องใช้หูฟัง ไม่ใช่ลำโพงในตัว
4. **Hardware AEC** — บาง Android tablet มี AEC ในฮาร์ดแวร์ที่ปิดจาก code ไม่ได้
5. **Firestore latency ~200–500ms** — ชดเชยด้วย 0.5s silence padding ใน WAV header
6. **Firestore free tier** — quota 50,000 reads/day เพียงพอสำหรับ prototype/research
