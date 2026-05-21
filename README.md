# Telemedicine Heart Sound — WebRTC

ระบบ video call ระหว่างหมอกับคนไข้ พร้อมส่งเสียงหัวใจ (จาก stethoscope หรือ asset จำลอง) ผ่าน WebRTC แบบ real-time

> **Status:** Web build ใช้งานได้ครบทุกฟีเจอร์หลัก (video call, voice, heart sound dual-mode, recording, mute controls). Native iOS/Android ยังไม่รองรับ heart sound features (ใช้ได้แค่ video call + voice)

---

## Architecture (สรุป)

**Voice + Heart = แยก channel เด็ดขาด**

```
              Patient                                  Doctor
┌────────────────────────────────────┐    ┌────────────────────────────────┐
│ Mic ─── Opus track ───────────────────────→ <audio> sink → Speaker      │
│                                    │    │                  ↑ 🔊 Opus mute│
│ ❤️ Heart sound (2 modes):          │    │                                │
│  🎵 Sample WAV → BufferSource ─┐   │    │                                │
│  🩺 Live mic (filters OFF) ────┴───── PCM DC ──→ Worklet → BufferSource │
│                                    │    │     → masterGain → Speaker     │
│                                    │    │                ↑ ❤️ PCM mute   │
└────────────────────────────────────┘    └────────────────────────────────┘
```

### หลักการ:
- **Voice = Opus** (WebRTC audio track) → high-quality voice, AEC/NS/AGC default + `usedtx=0` กันเสียงตัดท้าย
- **Heart sound = PCM RTCDataChannel** → lossless (Int16 768 kbps), bass 20-200Hz ไม่ถูกตัด
- **2 channels พร้อมกัน** — คุยพูดคุยขณะส่งเสียงหัวใจได้
- **Mute = local-only** ไม่ใช่ bilateral — แต่ละฝั่งคุมตัวเอง + ❤️ มี cooperative `stopHeart` signal (P2P DC) ลด bandwidth
- **Cache-bust อัตโนมัติ** ใน `start_test_server.sh` กัน browser โหลด stale main.dart.js

---

## Features

### Patient screen (5 ปุ่ม)
- 🎤 **Mic** — เปิด/ปิด mic outgoing
- 📷 **Camera** — เปิด/ปิดกล้อง
- 🔊 **Voice mute** — ปิดเสียง doctor incoming
- ❤️ **Heart sound** — เปิด panel เลือก mode:
  - 🎵 **ตัวอย่าง** — เล่น WAV asset (Aortic / Mitral / Pulmonary / Tricuspid)
  - 🩺 **ฟังสด** — getUserMedia filters OFF (AEC/NS/AGC = exact:false) → mic raw → PCM DC
- 📞 **End call**

### Doctor screen (6 ปุ่ม)
- 🎤 **Mic** — เปิด/ปิด mic outgoing (สำหรับพูดกับ patient)
- 🔊 **Opus** — ปิดเสียง patient voice incoming (local mute, 3 layers: `el.muted=true` + `el.volume=0` + `masterGain.disconnect()`)
- ❤️ **Heart** — toggle mute เสียงหัวใจ + ครั้งแรกส่ง `stopHeart` ผ่าน control DC (cooperative — patient หยุดส่ง = ลด bandwidth)
- ⏺ **Record** — บันทึก audio stream → blob URL list (MediaRecorder webm/opus)
- 🎵 **List** — ดูรายการบันทึก, เล่นซ้ำ, ลบ
- 📞 **End call**

### Heart Mode Banner (doctor)
แสดงเมื่อ patient เปิดเสียงหัวใจ — บอกตำแหน่ง (Aortic / Live / etc.) + chip status Opus/PCM + ปุ่ม Bass+6dB (display aid, lowshelf 200Hz)

---

## Quickstart

### Dev server (Web)

```bash
cd telemedicine_app
./start_test_server.sh build    # build + cache-bust + restart server
./start_test_server.sh status   # check status
./start_test_server.sh stop     # stop server
```

เปิด `http://localhost:8080` ใน Incognito 2 tab → tab 1 เป็น patient (เริ่มโทร) → copy room ID → tab 2 เป็น doctor (เข้าร่วม)

### Test heart sound

1. Patient → ❤️ → เลือก **🎵 ตัวอย่าง Aortic** → Play
2. Doctor เห็น "Heart Mode: Aortic" banner + ได้ยินเสียงหัวใจผ่าน PCM
3. กด ⏺ บน doctor → บันทึก → กด ⏺ อีกครั้งหยุด → list ขึ้น

### Echo (test same-machine)

Same machine 2 tabs จะมี acoustic loop: speaker → mic → speaker. กด 🎤 ฝั่งใดฝั่งหนึ่งตัด echo

### Cross-device testing (Mac + Mobile) ผ่าน Cloudflare Tunnel

ทดสอบจริงต้องใช้ 2 device คนละ network (เช่น Mac WiFi + มือถือ 4G) — expose `localhost:8080` ผ่าน tunnel:

```bash
# Install (one-time)
brew install cloudflared

# Terminal 1: Flutter web server
cd telemedicine_app
./start_test_server.sh build

# Terminal 2: tunnel
cloudflared tunnel --url http://localhost:8080
```

ได้ output แบบ:
```
+----------------------------------------------------+
| https://random-words.trycloudflare.com             |
+----------------------------------------------------+
```

**บน Mac:** เปิด `localhost:8080` (เร็วกว่า) → เลือก "แพทย์"
**บนมือถือ:** เปิด `https://random-words.trycloudflare.com` ใน Chrome/Safari → เลือก "คนไข้" → "เริ่มการโทร" → ขอ permission camera + mic → ดูรหัสห้อง 6 หลัก
**Mac กรอกรหัส 6 หลัก** → เข้าร่วม → call connects (ICE ผ่าน TURN ถ้า P2P fail)

**ข้อสำคัญ:**
- Cloudflare auto HTTPS → `getUserMedia` ทำงานบนมือถือ (HTTP จะ block)
- WebRTC P2P หลัง signaling — data ไม่ผ่าน Cloudflare (low latency)
- Tunnel URL random ทุกครั้ง — Ctrl+C ปิด URL หาย
- Firebase Firestore ทำงานทุก origin (project ไม่ใช้ Auth)

### Room code (6-digit numeric)

Patient เริ่มโทร → ระบบ generate รหัสห้อง 6 หลัก (เช่น `123 456`) ที่ doctor ใช้เข้าร่วม
- Numeric keyboard บนมือถือ
- Doctor กรอก `123456` หรือ `123 456` ก็ได้ (space ถูก strip auto)
- 1 ล้าน combinations + collision retry (5 attempts) → safe จนกว่า rooms > 10k active

---

## Project Structure

```
telemedicine_app/
├── lib/
│   ├── main.dart                     # MultiProvider (WebRTCService + RecordingService)
│   ├── config/
│   │   ├── webrtc_config.dart        # ICE servers + Opus SDP tuning (usedtx=0, fullband)
│   │   └── firebase_config.dart      # Firestore collection names
│   ├── models/
│   │   ├── call_state.dart           # enum: idle/calling/waiting/connected/ended/error
│   │   └── heart_position.dart       # enum + assetPath (assets/assets/heart_sounds/...)
│   ├── services/
│   │   ├── webrtc_service.dart       # PeerConnection + control DC + heart sound API
│   │   ├── signaling_service.dart    # Firestore room signaling + heart mode relay
│   │   ├── recording_service.dart    # MediaRecorder wrapper (web only)
│   │   ├── _audio_js_web.dart        # dart:js_interop bindings
│   │   └── _audio_js_stub.dart       # non-web stubs
│   └── screens/
│       ├── home_screen.dart          # role selector (Patient / Doctor)
│       ├── patient/patient_call_screen.dart   # 5-btn control bar + Sim panel
│       └── doctor/doctor_call_screen.dart     # 6-btn control bar + Heart banner + recordings sheet
├── web/index.html                    # JS audio pipeline (Web Audio + AudioWorklet + MediaRecorder)
├── start_test_server.sh              # build + cache-bust + run python3 http.server
└── assets/heart_sounds/*.wav         # 4-position heart sound samples (Aortic/Mitral/Pulmonary/Tricuspid)
```

---

## Audio Pipeline Details

### Patient Side

**SimAudio (🎵 Sample mode)** — single `AudioContext`:
```
fetch(WAV) → decodeAudioData (cached) → BufferSource(loop)
            → AudioWorklet 'steth-capture' (1920 samples = 40ms @ 48kHz)
            → Int16 quantize → RTCDataChannel.send (Int16 = 768 kbps)
```

**Live stethoscope (🩺 Live mode)** — separate `getUserMedia` filters OFF:
```
{ echoCancellation: {exact:false}, noiseSuppression:{exact:false},
  autoGainControl: {exact:false}, sampleRate: 48000 }
→ MediaStreamSource → AudioWorklet → Int16 → DataChannel
```

### Doctor Side

**PCM Playback** — jitter buffer 4 chunks × 40ms = 160ms:
```
DataChannel.onmessage → Int16Array → Float32Array
                      → AudioBuffer → BufferSource scheduled
                      → BiquadFilter (lowshelf 200Hz, Bass+6dB optional)
                      → masterGain (mute control)
                      → ctx.destination
```

**Opus Sink** — Web Audio capture of `<audio>` element:
```
flutter_webrtc creates <audio> in #html_webrtc_audio_manager_list
→ createMediaStreamSource(el.srcObject)
→ masterGain → ctx.destination
+ el.muted=true + el.volume=0 (defense in depth)
```

### SDP (Opus tuning)
```
a=fmtp:<pt> usedtx=0;maxplaybackrate=48000;sprop-maxcapturerate=48000;stereo=0;sprop-stereo=0
m=video ... b=AS:500   ; cap video at 500 kbps
```

---

## Roadmap

ดู [PLAN.md](PLAN.md) สำหรับ enhancement ที่ยังไม่ implement

---

## Hardware

- Stethoscope: **Thinklabs One** (analog 3.5mm → Thinklink USB-C → tablet/laptop mic)
- ตั้ง Thinklabs filter: **Low filter 30–500 Hz**
- ฟังด้วยหูฟัง over-ear / IEM ที่ frequency response ลงถึง 20 Hz

---

## Known Limitations

- **Native iOS/Android**: heart sound feature (SimAudio + Live mic + PCM playback) ไม่รองรับ — ใช้ได้แค่ video call + voice (ดู Roadmap)
- **Same-machine testing**: ต้องใช้หูฟัง หรือ mute ปุ่ม 🎤 ตัด acoustic loop
- **PCM bandwidth**: 768 kbps (Int16 × 48kHz mono) — ต้อง mobile 4G+ ขึ้นไป
- **Recording**: blob URL ใน memory เท่านั้น — refresh page หาย (ดู Roadmap → Firebase Storage)
- **Browser support**: ทดสอบบน Chrome เท่านั้น (Safari/Firefox อาจมี audio quirks)

---

## License

Internal project — TBD
