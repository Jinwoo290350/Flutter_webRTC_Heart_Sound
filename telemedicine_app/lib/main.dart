import 'package:flutter/foundation.dart' show kIsWeb;
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

  // เริ่มต้น Firebase:
  //   Web  → explicit options จาก --dart-define (web ไม่มี native config file)
  //   Mobile (Android/iOS) → auto-init จาก google-services.json / GoogleService-Info.plist
  //          → รัน `flutter run` เปล่าได้ ไม่ต้องจำ --dart-define-from-file=.env
  //   ครอบ try/catch: ถ้า init fail → แสดง error screen (ไม่ค้าง splash เงียบ ๆ)
  try {
    await Firebase.initializeApp(
      options: kIsWeb ? DefaultFirebaseOptions.currentPlatform : null,
    );
  } catch (e, st) {
    debugPrint('[Firebase] init failed: $e\n$st');
    runApp(_InitErrorApp(message: '$e'));
    return;
  }

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

/// แสดงเมื่อ Firebase.initializeApp ล้มเหลว — กัน splash ค้างเงียบ ๆ
/// (เช่น web ลืม --dart-define-from-file=.env, หรือ mobile ไม่มี google-services.json)
class _InitErrorApp extends StatelessWidget {
  final String message;
  const _InitErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1A1A1A),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'เริ่มต้น Firebase ไม่สำเร็จ',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Android/iOS: ตรวจว่ามี google-services.json / GoogleService-Info.plist\n'
                  'Web: build ด้วย --dart-define-from-file=.env',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
