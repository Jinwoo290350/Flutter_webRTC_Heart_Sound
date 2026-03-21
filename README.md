# Telemedicine Heart Sound Streaming

ระบบ telemedicine ที่ให้แพทย์และผู้ป่วย video call พร้อมส่งเสียงหัวใจจาก digital stethoscope (Thinklabs One) ผ่าน WebRTC แบบ real-time แพทย์สามารถบันทึกและเล่นซ้ำเสียงหัวใจได้

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

### 4. Web Audio API Injection (Web Platform)

สำหรับ simulation เสียงหัวใจบน web — inject เสียงเข้า RTCPeerConnection โดยตรง:

```
AudioContext → MediaElementSource (heart WAV) → MediaStreamDestination
    → replaceTrack() → PeerConnection → หมอได้ยินจริง
```

JavaScript monkey-patch `window.RTCPeerConnection` เพื่อ capture PC reference แล้ว call `replaceTrack()` เมื่อเริ่ม simulation

### 5. Bass Boost ฝั่งผู้รับ (แพทย์)

Web Audio API BiquadFilter chain บน `<video>` element ที่รับ remote stream:

```
RemoteStream → lowshelf +dB @ 500Hz → peaking @ 80Hz → peaking @ 200Hz → AudioOutput
```

ปรับ gain ได้ real-time ผ่าน slider 0–24dB ในหน้าจอแพทย์

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
       └─→ Channel 2: เสียงหัวใจ
           AEC=OFF, NS=OFF, AGC=OFF, HPF=OFF
           Opus fullband 48kHz
       │
       ▼
  WebRTC PeerConnection ──── Internet ────→ [ฝั่งแพทย์ — iPhone / Desktop]
  (+ Video track)                            │
                                             ├─ Video: เห็นหน้าผู้ป่วย
                                             ├─ Audio 1: เสียงพูด (ชัด)
                                             └─ Audio 2: เสียงหัวใจ (raw 20–500Hz)
                                                 └─ Bass Boost (Web Audio BiquadFilter)
                                                 └─ บันทึก / เล่นซ้ำ
```

**สำหรับ simulation** (ทดสอบโดยไม่มี stethoscope จริง):

```
heart_sounds/*.wav → Web Audio API → replaceTrack() → PeerConnection → หมอได้ยิน
```

---

## Tech Stack

| Component | Technology | หมายเหตุ |
|-----------|-----------|---------|
| Framework | Flutter (Dart) | cross-platform iOS + Android + Web |
| WebRTC | `flutter_webrtc ^0.12` | native binding — ควบคุม audio pipeline ได้ทุกชั้น |
| Signaling | Firebase Firestore | real-time database แลก offer/answer/ICE |
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
│       │   ├── signaling_service.dart   # Firebase Firestore signaling
│       │   ├── audio_service.dart       # simulation playback + mode switching
│       │   ├── recording_service.dart   # record/playback (web blob URL + native file)
│       │   ├── _audio_js_web.dart       # dart:js_interop → JS functions ใน index.html
│       │   └── _audio_js_stub.dart      # stub สำหรับ native platform
│       └── screens/
│           ├── patient/
│           │   └── patient_call_screen.dart  # เริ่มโทร + simulate stethoscope
│           └── doctor/
│               └── doctor_call_screen.dart   # รับสาย + heart mode + บันทึก + เล่นซ้ำ
├── heart_sound_analysis.ipynb      # วิเคราะห์ sample quality ด้วย Python
└── Heart_sound/                    # dataset (ไม่อยู่ใน git — ไฟล์ใหญ่)
    ├── Aortic_{0-5}/
    ├── Mitral_{0,2-5}/
    ├── Pulmonary_{0-5}/
    └── Tricuspid_{0,1,3-5}/
```

---

## Quick Start

### 1. Firebase Setup

```bash
# ต้องมี Firebase project ชื่อ flutterwebrtcmtec (หรือสร้างใหม่)
cd telemedicine_app
flutterfire configure --project=YOUR_FIREBASE_PROJECT
```

### 2. Run บน Browser

```bash
cd telemedicine_app
flutter pub get
flutter run -d chrome --web-renderer html
```

### 3. ทดสอบข้ามอุปกรณ์ด้วย cloudflared tunnel

```bash
# Terminal 1: build + serve static
cd telemedicine_app
flutter build web --release
cd build/web
python3 -m http.server 8080

# Terminal 2: expose ด้วย cloudflared
cloudflared tunnel --url http://localhost:8080
# จะได้ URL เช่น https://xxxx.trycloudflare.com
```

เปิด URL นั้นบน iPhone / Android — ไม่ต้อง install อะไรเพิ่ม

---

## หน้าจอแพทย์ (Doctor UI)

| Feature | รายละเอียด |
|---------|-----------|
| Heart Mode | กดเพื่อเข้า/ออกโหมดฟังเสียงหัวใจ |
| Timer | นับเวลาที่ฟังเสียงหัวใจ (MM:SS) |
| Position Selector | เลือกตำแหน่งฟัง: Aortic / Mitral / Pulmonary / Tricuspid |
| Bass Boost | Slider 0–24dB ปรับ bass ฝั่งผู้รับ real-time |
| Reference Audio | เล่นเสียงหัวใจอ้างอิง (normal) เพื่อเปรียบเทียบ |
| Record | บันทึกเสียงหัวใจระหว่าง call |
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
| Hardware Test | ทดสอบกับ Thinklabs One จริงบน Android tablet | 🔄 Pending |
| Phase Next | DataChannel raw PCM (ถ้า hardware AEC ปิดไม่ได้) | 📋 Planned |

---

## สิ่งที่ยืนยันแล้ว (Verified)

- WebRTC connection ทำงานได้ระหว่างอุปกรณ์ 2 เครื่อง
- เสียงหัวใจ (simulation WAV) ส่งผ่าน WebRTC จริง ไม่ใช่แค่ local playback
- แพทย์ฝั่ง iPhone ได้ยินเสียงหัวใจโดยไม่ต้องใส่หูฟัง
- Bass Boost ปรับ frequency response ฝั่งผู้รับได้ real-time
- iOS Safari audio unlock ทำงานได้ (ต้อง tap ก่อน)

## สิ่งที่ยังต้องทดสอบ

- **10-second fade test** — เสียง stethoscope ต้อง **ไม่ fade** หลัง 10 วินาที ถ้า fade = NS ยังทำงาน
- **Hardware AEC บน Android** — บาง tablet ปิดไม่ได้ อาจต้องใช้ DataChannel raw PCM
- **Thinklabs One จริง** — ทดสอบกับ stethoscope และ Android tablet จริง

---

## Known Issues

1. **`{exact: false}` สำคัญมาก** — บน Android Chrome 72+ ใช้แค่ `false` อาจไม่ปิด filter จริง
2. **Android emulator ไม่มี USB audio** — ต้องทดสอบบนเครื่องจริงเท่านั้น
3. **ลำโพง tablet ไม่มี bass** — หมอต้องใช้หูฟัง ไม่ใช่ลำโพงในตัว
4. **Hardware AEC** — บาง Android tablet มี AEC ในฮาร์ดแวร์ที่ปิดจาก code ไม่ได้
5. **Firestore free tier** — quota 50,000 reads/day เพียงพอสำหรับ prototype/research
