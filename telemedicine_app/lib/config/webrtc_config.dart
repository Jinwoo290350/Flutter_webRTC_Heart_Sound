/// ตั้งค่า WebRTC ส่วนกลาง
/// - STUN/TURN servers
/// - ICE configuration
/// - Audio constraints สำหรับ Phase 1 (เสียงพูดปกติ)

class WebRTCConfig {
  // ==================== ICE Servers ====================

  /// STUN + TURN servers
  /// ใช้ Open Relay Project (ฟรี ไม่ต้องสมัคร) สำหรับ hospital firewall traversal
  /// TURN จำเป็นเมื่อ hospital block P2P direct connection
  static const Map<String, dynamic> iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      // Open Relay Project — public TURN, no signup needed
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443',
          'turns:openrelay.metered.ca:443', // ผ่าน HTTPS firewall ได้
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
  };

  // ==================== Audio Constraints ====================

  /// Phase 1: เสียงพูดทั่วไป — เปิด filter ปกติ
  static const Map<String, dynamic> voiceConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': true,
  };

  /// Phase 2 (เตรียมไว้): เสียงหัวใจ — ปิด filter ทั้งหมด
  /// ใช้ {exact: false} บังคับปิดจริงบน Android Chrome 72+
  static Map<String, dynamic> stethoscopeConstraints(String deviceId) => {
    'audio': {
      'deviceId': {'exact': deviceId},
      'echoCancellation': {'exact': false},
      'noiseSuppression': {'exact': false},
      'autoGainControl': {'exact': false},
      // Google-specific constraints สำหรับ Android WebRTC
      'googHighpassFilter': false,
      'googNoiseSuppression': false,
      'googAutoGainControl': false,
      'googEchoCancellation': false,
    },
    'video': false,
  };

  // ==================== SDP Manipulation ====================

  /// Modify SDP:
  /// 1. บังคับ Opus fullband 48kHz — ป้องกัน fall back เป็น narrowband
  /// 2. จำกัด video bandwidth 500 kbps — ให้ audio มี priority บนเน็ตช้า
  static String modifySdp(String sdp) {
    // Opus fullband 48kHz
    String result = sdp.replaceAllMapped(
      RegExp(r'(a=fmtp:\d+ .*)'),
      (m) => '${m[1]};maxplaybackrate=48000;sprop-maxcapturerate=48000',
    );
    // จำกัด video bitrate 500 kbps (เน็ตแย่ยังดูได้ audio ไม่แย่ง bandwidth)
    result = result.replaceAllMapped(
      RegExp(r'(m=video [^\r\n]*)'),
      (m) => '${m[1]}\r\nb=AS:500',
    );
    return result;
  }

  /// ชื่อเดิม — backward compat (alias ไป modifySdp)
  static String forceOpusFullband(String sdp) => modifySdp(sdp);
}