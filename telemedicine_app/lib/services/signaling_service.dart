import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config/firebase_config.dart';

/// SignalingService — จัดการแลกเปลี่ยน SDP offer/answer และ ICE candidates ผ่าน Firestore
///
/// Flow:
///   Patient (caller):
///     1. createRoom() → สร้าง room ใน Firestore + อัปโหลด offer
///     2. listenForAnswer() → รอ doctor ส่ง answer กลับมา
///     3. listenForRemoteCandidates() → รับ ICE candidates จาก doctor
///
///   Doctor (callee):
///     1. joinRoom(roomId) → ดึง offer จาก Firestore
///     2. uploadAnswer(answer) → อัปโหลด answer
///     3. listenForRemoteCandidates() → รับ ICE candidates จาก patient
class SignalingService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Reference ไปยัง room document ปัจจุบัน
  DocumentReference? _roomRef;
  String? _roomId;

  String? get roomId => _roomId;

  // ==================== Patient (Caller) ====================

  /// สร้าง room ใหม่ใน Firestore และอัปโหลด offer SDP
  /// คืนค่า roomId ที่ patient จะแชร์ให้ doctor
  Future<String> createRoom(RTCSessionDescription offer) async {
    // สร้าง document ใหม่ใน collection 'rooms' (auto-ID)
    _roomRef = _firestore.collection(FirebaseConfig.roomsCollection).doc();
    _roomId = _roomRef!.id;

    await _roomRef!.set({
      FirebaseConfig.offerField: {
        'type': offer.type,
        'sdp': offer.sdp,
      },
      FirebaseConfig.statusField: FirebaseConfig.statusWaiting,
      FirebaseConfig.createdAtField: FieldValue.serverTimestamp(),
    });

    return _roomId!;
  }

  /// Patient รอฟัง answer จาก doctor
  /// เมื่อ doctor อัปโหลด answer, callback จะถูกเรียก
  void listenForAnswer(Function(RTCSessionDescription) onAnswer) {
    _roomRef!.snapshots().listen((snapshot) {
      if (!snapshot.exists) return;

      final data = snapshot.data() as Map<String, dynamic>;
      if (data.containsKey(FirebaseConfig.answerField)) {
        final answerData = data[FirebaseConfig.answerField];
        final answer = RTCSessionDescription(
          answerData['sdp'],
          answerData['type'],
        );
        onAnswer(answer);
      }
    });
  }

  // ==================== Doctor (Callee) ====================

  /// Doctor join room ด้วย roomId ที่ได้รับจาก patient
  /// คืนค่า offer SDP ของ patient
  Future<RTCSessionDescription?> joinRoom(String roomId) async {
    _roomId = roomId;
    _roomRef = _firestore
        .collection(FirebaseConfig.roomsCollection)
        .doc(roomId);

    final snapshot = await _roomRef!.get();
    if (!snapshot.exists) return null;

    final data = snapshot.data() as Map<String, dynamic>;
    if (!data.containsKey(FirebaseConfig.offerField)) return null;

    final offerData = data[FirebaseConfig.offerField];
    return RTCSessionDescription(offerData['sdp'], offerData['type']);
  }

  /// Doctor อัปโหลด answer SDP ไปยัง Firestore
  Future<void> uploadAnswer(RTCSessionDescription answer) async {
    await _roomRef!.update({
      FirebaseConfig.answerField: {
        'type': answer.type,
        'sdp': answer.sdp,
      },
      FirebaseConfig.statusField: FirebaseConfig.statusConnected,
    });
  }

  // ==================== ICE Candidates ====================

  /// อัปโหลด ICE candidate ของตัวเองไปยัง Firestore
  /// [role]: 'caller' (patient) หรือ 'callee' (doctor)
  Future<void> addIceCandidate(RTCIceCandidate candidate, String role) async {
    await _roomRef!
        .collection('${role}_${FirebaseConfig.candidatesCollection}')
        .add({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  /// รับ ICE candidates ของ peer จาก Firestore แบบ real-time
  /// [role]: role ของ peer (ถ้าเราเป็น caller ก็ฟัง callee_candidates)
  void listenForRemoteCandidates(
    String role,
    Function(RTCIceCandidate) onCandidate,
  ) {
    _roomRef!
        .collection('${role}_${FirebaseConfig.candidatesCollection}')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data()!;
          final candidate = RTCIceCandidate(
            data['candidate'],
            data['sdpMid'],
            data['sdpMLineIndex'],
          );
          onCandidate(candidate);
        }
      }
    });
  }

  // ==================== Room Management ====================

  /// อัปเดต status เป็น 'ended' และล้าง sub-collections
  Future<void> endRoom() async {
    if (_roomRef == null) return;
    await _roomRef!.update({
      FirebaseConfig.statusField: FirebaseConfig.statusEnded,
    });
  }

  /// ฟัง status ของ room (ตรวจว่าอีกฝ่ายวางสายหรือเปล่า)
  void listenForRoomStatus(Function(String) onStatusChange) {
    _roomRef?.snapshots().listen((snapshot) {
      if (!snapshot.exists) return;
      final data = snapshot.data() as Map<String, dynamic>;
      final status = data[FirebaseConfig.statusField] as String?;
      if (status != null) onStatusChange(status);
    });
  }

  void reset() {
    _roomRef = null;
    _roomId = null;
  }
}
