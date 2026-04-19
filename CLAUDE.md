# CLAUDE.md — Telemedicine Heart Sound Streaming

## Project Overview

ระบบ telemedicine ที่ให้หมอกับคนไข้ video call กัน พร้อมส่งเสียงหัวใจจาก digital stethoscope (Thinklabs One) ให้หมอฟังแบบ real-time ผ่าน WebRTC หมอสามารถบันทึกและเล่นซ้ำเสียงหัวใจได้

## The Core Problem

WebRTC ถูกออกแบบมาเพื่อเสียงพูดมนุษย์ (300–8,000 Hz) แต่เสียงหัวใจอยู่ที่ 20–500 Hz ซึ่งเป็นช่วงที่ WebRTC audio processing pipeline ตัดทิ้งโดยอัตโนมัติ

WebRTC มี 4 filter ที่ทำลายเสียงหัวใจ:
- **HPF (High Pass Filter)** — ตัดเสียงต่ำกว่า ~300 Hz ออก
- **NS (Noise Suppression)** — มองว่าเสียงหัวใจเป็น noise แล้วกดลง
- **AEC (Echo Cancellation)** — ตัดเสียงที่ไม่ใช่คนพูดออก
- **AGC (Auto Gain Control)** — ปรับ volume อัตโนมัติ ทำให้เสียงเบาหาย

**สัญญาณว่า filter ยังทำงาน**: ถ้าเสียง stethoscope ค่อยๆ fade หายภายใน ~10 วินาที = NS กำลังเรียนรู้ว่าเสียงหัวใจเป็น noise แล้วกดมัน

### Android เป็นปัญหาพิเศษ

บน PC/Mac ปิด filter ด้วย getUserMedia constraints ได้ แต่ Android มี layer เพิ่ม:
1. **Hardware AEC** — ชิป audio ใน tablet มี AEC ฝังในฮาร์ดแวร์ ปิดจาก code ไม่ได้
2. **COMM mode** — Android บังคับเปิดโหมดโทรศัพท์เมื่อใช้ WebRTC
3. **WebRTC filter** — ปิดได้ด้วย code
4. **ลำโพง tablet** — ไม่มี bass ทางกายภาพ ต้องใช้หูฟัง

**Solution: ใช้ Flutter + flutter_webrtc (native WebRTC binding)** แทน browser เพื่อควบคุม audio pipeline ได้ทุกชั้น

## Architecture

```
[ฝั่งคนไข้ - Tablet Android]

  Thinklabs One Stethoscope
       │ (3.5mm / USB-C via Thinklink)
       ▼
  Tablet Audio Input
       │
       ├─→ Channel 1: เสียงพูด (mic ปกติ)
       │   └─ filter: AEC=ON, NS=ON, AGC=ON
       │
       └─→ Channel 2: เสียงหัวใจ (stethoscope)
           └─ filter: AEC=OFF, NS=OFF, AGC=OFF, HPF=OFF
           └─ Opus codec: fullband 48kHz
       │
       ▼
  WebRTC PeerConnection ──── Internet ────→ [ฝั่งหมอ]
  (+ Video track)                            │
                                             ├─ Video: เห็นหน้าคนไข้
                                             ├─ Audio 1: เสียงพูด (ชัด)
                                             ├─ Audio 2: เสียงหัวใจ (raw)
                                             │   └─ ผ่านหูฟัง bass ดี
                                             └─ Controls: สลับฟัง / บันทึก / เล่นซ้ำ
```

## Tech Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| Framework | Flutter (Dart) | cross-platform iOS + Android |
| WebRTC | `flutter_webrtc` package | open-source native WebRTC binding |
| Signaling | Firebase Firestore | real-time database สำหรับ peer connection |
| STUN | Google STUN (free) | `stun:stun.l.google.com:19302` |
| Stethoscope | Thinklabs One | analog 3.5mm output → tablet mic input |
| Audio Codec | Opus fullband 48kHz | ต้อง config ให้ไม่ตัดความถี่ต่ำ |

## Project Structure (Target)

```
telemedicine_app/
├── CLAUDE.md                    ← this file
├── pubspec.yaml
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── config/
│   │   ├── firebase_config.dart
│   │   └── webrtc_config.dart   ← Opus fullband settings, STUN/TURN
│   ├── models/
│   │   ├── call_state.dart      ← enum: idle, calling, connected, ended
│   │   └── audio_channel.dart   ← voice vs stethoscope channel model
│   ├── services/
│   │   ├── signaling_service.dart    ← Firebase Firestore signaling
│   │   ├── webrtc_service.dart       ← core WebRTC peer connection logic
│   │   ├── audio_service.dart        ← dual-channel audio management
│   │   └── recording_service.dart    ← record + playback heart sounds
│   ├── screens/
│   │   ├── home_screen.dart
│   │   ├── patient/
│   │   │   └── patient_call_screen.dart  ← camera + mic + stethoscope input
│   │   └── doctor/
│   │       └── doctor_call_screen.dart   ← video + audio controls + playback
│   └── widgets/
│       ├── video_view.dart
│       ├── audio_controls.dart       ← toggle voice/heart, volume
│       ├── stethoscope_indicator.dart ← show stethoscope connection status
│       └── recording_controls.dart   ← record, stop, play, save
├── android/
│   └── app/src/main/AndroidManifest.xml  ← permissions
├── ios/
│   └── Runner/Info.plist                 ← permissions
└── firebase/
    └── firestore.rules
```

## Critical Implementation Details

### 1. Dual-Channel Audio Setup

สร้าง 2 audio streams แยกกันด้วย `getUserMedia()` equivalent ใน flutter_webrtc:

```dart
// Channel 1: Voice — filter ON (clear speech)
final voiceConstraints = {
  'audio': {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  },
  'video': true,
};

// Channel 2: Stethoscope — ALL filters OFF (preserve low freq)
final stethConstraints = {
  'audio': {
    'deviceId': stethoscopeDeviceId,  // USB/3.5mm audio input
    'echoCancellation': {'exact': false},
    'noiseSuppression': {'exact': false},
    'autoGainControl': {'exact': false},
    'googHighpassFilter': false,
    'googNoiseSuppression': false,
    'googAutoGainControl': false,
    'googEchoCancellation': false,
  },
  'video': false,
};
```

**IMPORTANT**: ใช้ `{'exact': false}` ไม่ใช่แค่ `false` เพื่อบังคับให้ browser/native ปิดจริง

### 2. Opus Codec Configuration

ต้อง modify SDP ก่อนส่ง offer/answer เพื่อบังคับ Opus fullband:

```dart
String forceOpusFullband(String sdp) {
  return sdp.replaceAllMapped(
    RegExp(r'(a=fmtp:\d+ .*)'),
    (m) => '${m[1]};maxplaybackrate=48000;sprop-maxcapturerate=48000',
  );
}
```

ถ้าไม่ทำ Opus จะ default เป็น narrowband (8kHz) เมื่อเจอ AEC/NS = ON แล้วจะตัดเสียงต่ำกว่า 4kHz ทิ้ง

### 3. Signaling via Firebase Firestore

```
Collection: rooms/{roomId}
  ├── offer: RTCSessionDescription
  ├── answer: RTCSessionDescription
  ├── Sub-collection: candidates/{candidateId}
  │   └── candidate: RTCIceCandidate
  └── status: "waiting" | "connected" | "ended"
```

### 4. Recording & Playback (Doctor Side)

ใช้ MediaRecorder API equivalent ใน Flutter:
- บันทึกเฉพาะ stethoscope audio track (channel 2)
- เก็บเป็น file (webm/opus หรือ wav)
- หมอกดเล่นซ้ำได้ ปรับ volume ได้
- อาจเก็บใน local storage หรือ upload ไป cloud

### 5. Android Permissions

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
```

### 6. iOS Permissions

```xml
<!-- Info.plist -->
<key>NSCameraUsageDescription</key>
<string>Camera access for video call</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access for voice and stethoscope audio</string>
```

## Development Phases

### Phase 1: Basic Video Call (Week 1–4)
- [ ] Flutter project setup + dependencies
- [ ] Firebase project + Firestore signaling
- [ ] Basic 1-on-1 video call working on Android
- [ ] Test on physical Android device

### Phase 2: Dual-Channel Audio (Week 5–6)
- [ ] Detect stethoscope as USB/external audio input
- [ ] Create separate audio track with all filters disabled
- [ ] Add both tracks to PeerConnection
- [ ] Force Opus fullband via SDP modification
- [ ] Test: stethoscope sound does NOT fade after 10 seconds

### Phase 3: Doctor UI + Playback (Week 7–8)
- [ ] Doctor screen: toggle between voice and heart sound
- [ ] Record heart sound to file
- [ ] Playback with controls (play, pause, seek)
- [ ] Volume control for heart sound channel
- [ ] End-to-end test with actual clinician

## Key Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_webrtc: ^0.12.0        # WebRTC native binding
  cloud_firestore: ^5.0.0         # Firebase signaling
  firebase_core: ^3.0.0           # Firebase init
  permission_handler: ^11.0.0     # Camera/mic permissions
  path_provider: ^2.1.0           # Local file storage for recordings
  audioplayers: ^6.0.0            # Playback recorded audio
  provider: ^6.0.0                # State management
```

## Medical Audio Fidelity Requirements (CRITICAL)

ระบบนี้เป็นงานทางการแพทย์ที่ต้องการความละเอียดสูงมาก — กฎเหล่านี้ห้ามละเมิดเด็ดขาด:

### 1. ห้าม preprocess สัญญาณเสียงทุกรูปแบบ
- Input (stethoscope) และ Output (หมอ) ต้องเป็นสัญญาณเดียวกัน ไม่ผ่านการแปลงใดๆ
- **ห้ามเพิ่ม** equalization, compression, normalization, filtering ก่อนส่งข้อมูล
- Bass boost (Web Audio API) เป็น **display aid** สำหรับลำโพงที่ไม่มี bass เท่านั้น ไม่ใช่ส่วนหนึ่งของสัญญาณที่ส่ง
- Bass boost ต้อง **ปิดเป็น 0dB** เมื่อทำการ record เพื่อวิเคราะห์หรือเปรียบเทียบ

### 2. Pipeline ที่ยอมรับได้
```
Stethoscope → ADC → [WebRTC Opus 48kHz fullband] → Internet → [Opus decode] → หมอ
```
- Opus encode/decode เป็น lossy compression ที่หลีกเลี่ยงไม่ได้บน web
- ถ้า Opus quality ไม่เพียงพอ (bass loss > 6dB) → ต้องใช้ **DataChannel raw PCM** แทน

### 3. การทดสอบ audio fidelity
- เปรียบเทียบ input vs received ด้วย `audio_compare.py` โดย bass boost = 0dB
- เกณฑ์ผ่าน: bass band loss (20–200 Hz) < 6 dB
- ถ้า > 6 dB → investigate และแก้ไขก่อน deploy จริง

### 4. DataChannel PCM fallback
ถ้า WebRTC audio quality ไม่ผ่านเกณฑ์:
- ส่ง raw PCM Float32Array ผ่าน WebRTC DataChannel
- ไม่มี codec, ไม่มี filter, ไม่มี compression
- ต้อง implement jitter buffer เอง

## Testing Checklist

- [ ] Video call connects between 2 devices
- [ ] Voice audio is clear with noise reduction
- [ ] Stethoscope audio does NOT fade after 10 seconds (critical!)
- [ ] Heart sounds audible through headphones on doctor side
- [ ] Recording captures stethoscope audio only (bass boost = 0dB during capture)
- [ ] audio_compare.py: bass loss < 6dB (medical fidelity threshold)
- [ ] Playback works correctly
- [ ] Works on Android physical device (not just emulator)
- [ ] Stethoscope detected as audio input on tablet

## Hardware Setup

```
Thinklabs One → Thinklink adapter → USB-C/3.5mm → Android Tablet
                                                      │
                                                      └─→ Flutter app captures as external mic
```

Thinklabs One filter settings for heart sounds: Low filter (30–500 Hz)

## Known Issues & Gotchas

1. **Android emulator ไม่มี USB audio** — ต้องทดสอบบนเครื่องจริงเท่านั้น
2. **echoCancellation: false vs {exact: false}** — บน Android Chrome 72+ ต้องใช้ `{exact: false}` ถึงจะปิดจริง ถ้าใช้แค่ `false` อาจไม่ปิด
3. **Opus narrowband fallback** — ถ้าไม่ modify SDP, Opus จะ fall back เป็น narrowband เมื่อเจอ echo cancellation ทำให้ตัดเสียงเหนือ 8kHz
4. **Hardware AEC บน Android** — บาง tablet มี hardware AEC ที่ปิดไม่ได้ ถ้าเจอปัญหานี้ อาจต้องใช้ DataChannel ส่ง raw PCM แทน audio track
5. **ลำโพง tablet ไม่มี bass** — ฝั่งหมอต้องใช้หูฟัง over-ear หรือ IEM ที่ frequency response ลงถึง 20 Hz
6. **Firestore free tier** — มี quota 50,000 reads/day ซึ่งเพียงพอสำหรับ prototype