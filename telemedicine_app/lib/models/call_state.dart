/// สถานะของ call ณ เวลาใดเวลาหนึ่ง
enum CallState {
  /// ยังไม่มี call — หน้าหลัก
  idle,

  /// กำลังสร้าง offer / รอ peer
  calling,

  /// รอ offer จาก caller (ฝั่ง doctor join room)
  waiting,

  /// เชื่อมต่อสำเร็จ — ICE connected
  connected,

  /// call จบแล้ว
  ended,

  /// เกิด error
  error,
}

extension CallStateLabel on CallState {
  String get label {
    switch (this) {
      case CallState.idle:
        return 'ว่าง';
      case CallState.calling:
        return 'กำลังโทร...';
      case CallState.waiting:
        return 'รอการเชื่อมต่อ...';
      case CallState.connected:
        return 'เชื่อมต่อแล้ว';
      case CallState.ended:
        return 'วางสายแล้ว';
      case CallState.error:
        return 'เกิดข้อผิดพลาด';
    }
  }
}
