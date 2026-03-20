import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/webrtc_service.dart';
import 'services/recording_service.dart';

void main() async {
  // ต้อง ensureInitialized ก่อนใช้ async ใน main
  WidgetsFlutterBinding.ensureInitialized();

  // เริ่มต้น Firebase ด้วย options ที่ flutterfire generate ให้อัตโนมัติ
  // (ไฟล์ firebase_options.dart สร้างโดย: flutterfire configure --project=flutterwebrtcmtec)
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WebRTCService()),
        ChangeNotifierProvider(create: (_) => RecordingService()),
      ],
      child: const TelemedicineApp(),
    ),
  );
}
