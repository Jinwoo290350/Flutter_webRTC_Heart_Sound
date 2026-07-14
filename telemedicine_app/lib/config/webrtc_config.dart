/// ตั้งค่า WebRTC ส่วนกลาง
/// - STUN/TURN servers
/// - ICE configuration
/// - Audio constraints สำหรับ Phase 1 (เสียงพูดปกติ)

class WebRTCConfig {
  // ==================== ICE Servers ====================

  /// TURN credentials — metered.ca (ฟรี 50GB/เดือน)
  /// วิธีได้ค่า: สมัคร https://dashboard.metered.ca → TURN Server → copy
  ///   Username + Credential มาวางตรงนี้ (URL ใช้ global.relay.metered.ca ได้เลย)
  ///
  /// ถ้าเว้นว่าง (ยังไม่สมัคร) → ใช้ STUN อย่างเดียว:
  ///   - เน็ตเดียวกัน / NAT cone-type → ต่อได้ (host/srflx)
  ///   - คนละเน็ต + NAT symmetric (มือถือ/carrier) → ต่อไม่ได้ (ต้องมี TURN relay)
  static const String _turnUsername = String.fromEnvironment('TURN_USERNAME');
  static const String _turnCredential = String.fromEnvironment('TURN_CREDENTIAL');

  /// STUN + (TURN ถ้ามี credential) — assemble แบบ dynamic
  static Map<String, dynamic> get iceServers {
    final servers = <Map<String, dynamic>>[
      // STUN (ฟรี ไม่ต้องสมัคร) — ได้ srflx candidate สำหรับ NAT traversal
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ];
    // TURN relay — จำเป็นตอนคนละเน็ต + symmetric NAT (เพิ่มต่อเมื่อมี credential)
    if (_turnUsername.isNotEmpty && _turnCredential.isNotEmpty) {
      servers.add({
        'urls': [
          'turn:global.relay.metered.ca:80',
          'turn:global.relay.metered.ca:80?transport=tcp',
          'turn:global.relay.metered.ca:443',
          'turns:global.relay.metered.ca:443?transport=tcp', // ผ่าน HTTPS firewall
        ],
        'username': _turnUsername,
        'credential': _turnCredential,
      });
    }
    return {'iceServers': servers};
  }

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