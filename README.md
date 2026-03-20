# Telemedicine Heart Sound Streaming

ระบบ telemedicine สำหรับส่งเสียงหัวใจจาก digital stethoscope (Thinklabs One) ให้แพทย์ฟัง real-time ผ่าน WebRTC

## ปัญหาหลัก

WebRTC ถูกออกแบบมาเพื่อเสียงพูด (300–8,000 Hz) แต่เสียงหัวใจอยู่ที่ **20–500 Hz**
ซึ่ง WebRTC audio pipeline ตัดทิ้งโดยอัตโนมัติด้วย 4 filter:

| Filter | ผลกระทบ |
|--------|---------|
| HPF (High Pass Filter) | ตัดเสียงต่ำกว่า ~300 Hz |
| NS (Noise Suppression) | มองเสียงหัวใจเป็น noise แล้วกด |
| AEC (Echo Cancellation) | ตัดเสียงที่ไม่ใช่คนพูด |
| AGC (Auto Gain Control) | ทำให้เสียงเบาหาย |

**สัญญาณว่า filter ยังทำงาน**: เสียง stethoscope fade หายภายใน ~10 วินาที

## Solution

ใช้ **dual-channel audio**:
- Channel 1: เสียงพูด (filter เปิดปกติ)
- Channel 2: เสียงหัวใจ (ปิด filter ทั้งหมด + Opus fullband 48kHz)

## Architecture

```
[คนไข้ - Android Tablet]
  Thinklabs One → Thinklink → USB-C
       │
       ├─→ Channel 1: เสียงพูด (AEC=ON, NS=ON, AGC=ON)
       └─→ Channel 2: เสียงหัวใจ (filter ปิดทั้งหมด)
       │
       ▼
  WebRTC PeerConnection ──── Internet ────→ [หมอ]
                                             ├─ Video
                                             ├─ เสียงพูด
                                             └─ เสียงหัวใจ (raw)
```

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Framework | Flutter (Dart) |
| WebRTC | `flutter_webrtc` |
| Signaling | Firebase Firestore |
| STUN | Google STUN |
| Stethoscope | Thinklabs One |
| Codec | Opus fullband 48kHz |

## โครงสร้างโปรเจกต์

```
Flutter_webRTC_Heart/
├── telemedicine_app/          # Flutter app
│   └── lib/
│       ├── services/
│       │   ├── webrtc_service.dart     # PeerConnection + dual-channel
│       │   ├── signaling_service.dart  # Firebase signaling
│       │   ├── audio_service.dart      # audio mode management
│       │   └── recording_service.dart  # record + playback
│       └── screens/
│           ├── patient/                # คนไข้: เริ่มโทร + simulate stethoscope
│           └── doctor/                 # หมอ: รับสาย + บันทึก + เล่นซ้ำ
├── heart_sound_analysis.ipynb  # วิเคราะห์ sample เสียงหัวใจ
└── Heart_sound/               # dataset (ไม่อยู่ใน git)
    ├── Aortic_{0-5}/
    ├── Mitral_{0,2-5}/
    ├── Pulmonary_{0-5}/
    └── Tricuspid_{0,1,3-5}/
```

## Development Phases

- [x] **Phase 1**: Basic video call (WebRTC + Firestore signaling)
- [x] **Phase 2**: Dual-channel audio + stethoscope simulation
- [x] **Phase 3**: Doctor UI — toggle mode, record, playback
- [ ] **Hardware test**: ทดสอบกับ Thinklabs One จริงบน Android

## Quick Start

```bash
# 1. Firebase setup
flutterfire configure --project=flutterwebrtcmtec

# 2. Run
cd telemedicine_app
flutter pub get
flutter run -d chrome --release
```

## Hardware Setup

```
Thinklabs One → Thinklink adapter → USB-C → Android Tablet
                                               └─→ Flutter app รับเป็น external mic
```

## ทดสอบสำคัญ

เสียง stethoscope ต้อง **ไม่ fade หายภายใน 10 วินาที**
ถ้า fade = filter ยังทำงานอยู่
