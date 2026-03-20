/// ตั้งค่า WebRTC ส่วนกลาง
/// - STUN/TURN servers
/// - ICE configuration
/// - Audio constraints สำหรับ Phase 1 (เสียงพูดปกติ)

class WebRTCConfig {
  // ==================== ICE Servers ====================

  /// STUN server ของ Google (ฟรี, สำหรับ prototype)
  /// ใช้เพื่อ NAT traversal — หา public IP ของแต่ละ peer
  static const Map<String, dynamic> iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  // ==================== Audio Constraints ====================

  /// Phase 1: เสียงพูดทั่วไป — เปิด filter ปกติ
  /// ใช้กับทั้ง patient และ doctor สำหรับการสื่อสาร
  static const Map<String, dynamic> voiceConstraints = {
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    },
    'video': true, // ใช้ true แทนเพื่อให้ทำงานได้ทั้ง web และ mobile
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

  /// Phase 2 (เตรียมไว้): บังคับ Opus fullband 48kHz
  /// ป้องกัน Opus fall back เป็น narrowband (8kHz) เมื่อเจอ AEC/NS
  static String forceOpusFullband(String sdp) {
    return sdp.replaceAllMapped(
      RegExp(r'(a=fmtp:\d+ .*)'),
      (m) => '${m[1]};maxplaybackrate=48000;sprop-maxcapturerate=48000',
    );
  }
}
