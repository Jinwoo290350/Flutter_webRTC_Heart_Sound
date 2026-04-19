import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// PatientRecordingService — บันทึกเสียงหัวใจฝั่งคนไข้ก่อนเข้า WebRTC
///
/// Web: ใช้ browser MediaRecorder โดยตรง (ผ่าน record package)
/// Native: ใช้ record package (filter OFF)
///
/// Flow: record mic → save temp file → upload Firebase Storage → write URL to Firestore
/// Doctor ฟัง Firestore และ download URL มาเล่นได้ทันที
class PatientRecordingService extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  String? _roomId;
  String _currentPosition = 'Aortic';

  void setRoomId(String? id) => _roomId = id;

  /// เริ่มบันทึก mic ฝั่งคนไข้ (filter ปิดทั้งหมด)
  Future<void> startRecording(String position) async {
    if (_isRecording) return;
    _currentPosition = position;

    try {
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        debugPrint('[PatientRec] no mic permission');
        return;
      }

      String path;
      if (kIsWeb) {
        path = 'heart_${DateTime.now().millisecondsSinceEpoch}.webm';
      } else {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/heart_${DateTime.now().millisecondsSinceEpoch}.m4a';
      }
      await _recorder.start(
        RecordConfig(
          encoder: kIsWeb ? AudioEncoder.opus : AudioEncoder.aacLc,
          sampleRate: 48000,
          bitRate: 192000,
          numChannels: 1,
          // ปิด noise suppression และ echo cancel
          noiseSuppress: false,
          echoCancel: false,
          autoGain: false,
        ),
        path: path,
      );

      _isRecording = true;
      notifyListeners();
      debugPrint('[PatientRec] started → $path [$position]');
    } catch (e, st) {
      debugPrint('[PatientRec] start error: $e\n$st');
    }
  }

  /// หยุดบันทึกและอัพโหลด Firebase Storage
  /// Doctor จะได้รับ URL ผ่าน Firestore
  Future<String?> stopAndUpload() async {
    if (!_isRecording) return null;
    _isRecording = false;
    notifyListeners();

    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) {
        debugPrint('[PatientRec] no output path');
        return null;
      }
      debugPrint('[PatientRec] recorded → $path');

      // อัพโหลด Firebase Storage
      final ext = kIsWeb ? 'webm' : 'm4a';
      final fileName = 'heart_${_roomId ?? 'unknown'}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final ref = FirebaseStorage.instance.ref('heart_recordings/$fileName');

      String downloadUrl;
      if (kIsWeb) {
        // Web: path เป็น blob URL
        final response = await ref.putString(path, format: PutStringFormat.dataUrl).snapshotEvents.last;
        downloadUrl = await response.ref.getDownloadURL();
      } else {
        final file = File(path);
        await ref.putFile(file);
        downloadUrl = await ref.getDownloadURL();
        // ลบ temp file
        try { await file.delete(); } catch (_) {}
      }

      debugPrint('[PatientRec] uploaded → $downloadUrl');

      // เขียน URL ใน Firestore ให้ doctor รับได้
      if (_roomId != null) {
        await FirebaseFirestore.instance
            .collection('rooms')
            .doc(_roomId)
            .collection('patient_recordings')
            .add({
          'url': downloadUrl,
          'position': _currentPosition,
          'timestamp': FieldValue.serverTimestamp(),
          'ext': ext,
        });
        debugPrint('[PatientRec] Firestore written room=$_roomId');
      }

      return downloadUrl;
    } catch (e, st) {
      debugPrint('[PatientRec] stop/upload error: $e\n$st');
      _isRecording = false;
      notifyListeners();
      return null;
    }
  }

  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    await _recorder.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }
}

/// Model สำหรับ recording ที่ patient อัพโหลด
class PatientRecording {
  final String id;
  final String url;
  final String position;
  final DateTime timestamp;
  final String ext;

  const PatientRecording({
    required this.id,
    required this.url,
    required this.position,
    required this.timestamp,
    required this.ext,
  });

  factory PatientRecording.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return PatientRecording(
      id: doc.id,
      url: d['url'] as String,
      position: d['position'] as String? ?? '',
      timestamp: (d['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      ext: d['ext'] as String? ?? 'webm',
    );
  }
}
