import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
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

  /// เก็บ Firestore stream subscriptions ทั้งหมดเพื่อ cancel ใน reset()
  /// A5: Map keyed by listener name — ป้องกัน duplicate subscriptions
  final Map<String, StreamSubscription> _subs = {};

  void _addSub(String key, StreamSubscription sub) {
    // cancel ของเก่าก่อน เพื่อกัน duplicate callback
    _subs.remove(key)?.cancel();
    _subs[key] = sub;
  }

  String? get roomId => _roomId;

  // ==================== Patient (Caller) ====================

  /// สร้าง room ใหม่ใน Firestore — ใช้ 6-digit numeric code (อ่านง่าย พิมพ์ง่ายบนมือถือ)
  /// คืนค่า roomId (6 หลัก) ที่ patient จะแชร์ให้ doctor
  Future<String> createRoom(RTCSessionDescription offer) async {
    final rng = Random.secure();
    Exception? lastError;
    for (int attempt = 0; attempt < 5; attempt++) {
      final code = (100000 + rng.nextInt(900000)).toString(); // 100000-999999
      final docRef = _firestore.collection(FirebaseConfig.roomsCollection).doc(code);
      try {
        final snap = await docRef.get();
        if (snap.exists) continue; // collision — try another code
        _roomRef = docRef;
        _roomId = code;
        await _roomRef!.set({
          FirebaseConfig.offerField: {
            'type': offer.type,
            'sdp': offer.sdp,
          },
          FirebaseConfig.statusField: FirebaseConfig.statusWaiting,
          FirebaseConfig.createdAtField: FieldValue.serverTimestamp(),
        });
        return code;
      } catch (e) {
        lastError = Exception('createRoom error: $e');
      }
    }
    throw lastError ?? Exception('ไม่สามารถสร้าง room code ได้ — ลองอีกครั้ง');
  }

  /// Patient รอฟัง answer จาก doctor
  /// เมื่อ doctor อัปโหลด answer, callback จะถูกเรียก
  void listenForAnswer(Function(RTCSessionDescription) onAnswer) {
    _addSub('answer', _roomRef!.snapshots().listen(
      (snapshot) {
        if (!snapshot.exists) return;

        final data = snapshot.data() as Map<String, dynamic>;
        if (data.containsKey(FirebaseConfig.answerField)) {
          final answerData = data[FirebaseConfig.answerField];
          // N4: validate fields
          if (answerData is! Map || answerData['sdp'] == null || answerData['type'] == null) {
            debugPrint('[Signaling] invalid answer data: $answerData');
            return;
          }
          final answer = RTCSessionDescription(
            answerData['sdp'] as String,
            answerData['type'] as String,
          );
          onAnswer(answer);
        }
      },
      onError: (e) => debugPrint('[Signaling] listenForAnswer error: $e'),
    ));
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
    // ICE candidates อาจ gather เสร็จก่อน createRoom/joinRoom — ละเว้น (peer จะ generate ใหม่หลังจาก setRemoteDescription)
    if (_roomRef == null) return;
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
    _addSub('candidates_$role', _roomRef!
        .collection('${role}_${FirebaseConfig.candidatesCollection}')
        .snapshots()
        .listen(
      (snapshot) {
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
      },
      onError: (e) => debugPrint('[Signaling] listenForRemoteCandidates error: $e'),
    ));
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
    _addSub('roomStatus', _roomRef!.snapshots().listen(
      (snapshot) {
        if (!snapshot.exists) return;
        final data = snapshot.data() as Map<String, dynamic>;
        final status = data[FirebaseConfig.statusField] as String?;
        if (status != null) onStatusChange(status);
      },
      onError: (e) => debugPrint('[Signaling] listenForRoomStatus error: $e'),
    ));
  }

  /// Patient → Doctor: ประกาศว่ากำลังส่งเสียงหัวใจ + ระบุตำแหน่ง
  /// Doctor ใช้แสดง banner "Heart Mode: Aortic"
  Future<void> setHeartMode(bool enabled, [String? position]) async {
    if (_roomRef == null) return;
    try {
      await _roomRef!.update({
        'heartMode': enabled,
        'heartPosition': enabled ? position : null,
      });
    } catch (e) {
      debugPrint('[Signaling] setHeartMode error: $e');
    }
  }

  void listenForHeartMode(void Function(bool enabled, String? position) onChanged) {
    _addSub('heartMode', _roomRef!.snapshots().listen(
      (snapshot) {
        if (!snapshot.exists) return;
        final data = snapshot.data() as Map<String, dynamic>;
        final enabled = data['heartMode'] == true;
        final position = data['heartPosition'] as String?;
        onChanged(enabled, position);
      },
      onError: (e) => debugPrint('[Signaling] listenForHeartMode error: $e'),
    ));
  }

  void reset() {
    for (final s in _subs.values) { s.cancel(); }
    _subs.clear();
    _roomRef = null;
    _roomId = null;
  }
}
