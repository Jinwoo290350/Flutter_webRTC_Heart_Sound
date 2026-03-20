/// โครงสร้าง Firestore สำหรับ signaling
///
/// Collection: rooms/{roomId}
///   ├── offer: { type: 'offer', sdp: '...' }
///   ├── answer: { type: 'answer', sdp: '...' }
///   ├── status: "waiting" | "connected" | "ended"
///   └── Sub-collection: candidates/{candidateId}
///       └── { candidate, sdpMid, sdpMLineIndex }

class FirebaseConfig {
  // ชื่อ collection หลัก
  static const String roomsCollection = 'rooms';

  // ชื่อ sub-collection สำหรับ ICE candidates
  static const String candidatesCollection = 'candidates';

  // Field names ใน room document
  static const String offerField = 'offer';
  static const String answerField = 'answer';
  static const String statusField = 'status';
  static const String createdAtField = 'createdAt';

  // ค่าของ status
  static const String statusWaiting = 'waiting';
  static const String statusConnected = 'connected';
  static const String statusEnded = 'ended';
}
