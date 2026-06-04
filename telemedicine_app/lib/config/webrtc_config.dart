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

  /// Voice constraints — บังคับ AEC + NS + AGC ด้วย {exact: true}
  /// + legacy Chrome goog* constraints สำหรับ AEC3 (echo cancellation v3)
  /// เป้าหมาย: ลด echo บน cross-device test เมื่อ Mac + มือถือ อยู่ห้องเดียวกัน
  static const Map<String, dynamic> voiceConstraints = {
    'audio': {
      'echoCancellation': {'exact': true},
      'noiseSuppression': {'exact': true},
      'autoGainControl': {'exact': true},
      // Legacy Chrome constraints — บังคับ AEC3 explicitly
      'googEchoCancellation': true,
      'googEchoCancellation2': true,    // AEC3 modern algorithm
      'googNoiseSuppression': true,
      'googHighpassFilter': true,
      'googAutoGainControl': true,
      'googTypingNoiseDetection': true,
    },
    // Explicit constraints — Android Chrome tablet ขอ default 1280x720@30 อาจกระชาก
    // budget b=AS:500 ที่ SDP cap ไว้ → frame drop. ใช้ ideal (ไม่ใช่ exact) → graceful
    // fallback ถ้า hardware ไม่ตรง
    'video': {
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      'frameRate': {'ideal': 24, 'max': 30},
      'facingMode': 'user',
    },
  };

  // ==================== SDP Manipulation ====================

  /// Modify SDP — voice-optimized (Line/IG-grade) + cap video bandwidth
  ///
  /// Opus = voice เท่านั้น (heart sound แยกไป PCM DataChannel)
  ///   maxplaybackrate=48000  → fullband 48kHz (ไม่ fall back narrowband)
  ///   sprop-maxcapturerate=48000 → encoder ใช้ 48kHz
  ///   stereo=0; sprop-stereo=0 → mono ประหยัด bandwidth
  ///   usedtx=0  → DTX OFF — กันเสียงตัดท้ายประโยค (continuous transmission)
  ///              VBR + FEC ยังเปิด default
  static String modifySdp(String sdp) {
    const opusParams = 'usedtx=0;maxplaybackrate=48000;sprop-maxcapturerate=48000;'
        'stereo=0;sprop-stereo=0';
    String result = sdp.replaceAllMapped(
      RegExp(r'(a=fmtp:\d+ .*)'),
      (m) => '${m[1]};$opusParams',
    );
    // จำกัด video bitrate 800 kbps — Android tablet hardware encoder อาจ burst เกิน 500
    // ที่ 640x480@24 → frame drop. 800 ให้ headroom + ยัง audio priority บนเน็ตช้า
    result = result.replaceAllMapped(
      RegExp(r'(m=video [^\r\n]*)'),
      (m) => '${m[1]}\r\nb=AS:800',
    );
    return result;
  }

  /// Backward compat alias
  static String forceOpusFullband(String sdp) => modifySdp(sdp);
}