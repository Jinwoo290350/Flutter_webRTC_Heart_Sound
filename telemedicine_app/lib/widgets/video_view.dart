import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Widget สำหรับแสดงวิดีโอจาก RTCVideoRenderer
/// รองรับทั้ง full-screen และ PiP (Picture-in-Picture)
class VideoView extends StatelessWidget {
  final RTCVideoRenderer renderer;

  /// ถ้า true = เต็มจอ (BoxFit.cover)
  final bool isFullScreen;

  /// ถ้า true = กลับซ้าย-ขวา (สำหรับกล้องหน้าตัวเอง)
  final bool mirror;

  const VideoView({
    super.key,
    required this.renderer,
    this.isFullScreen = false,
    this.mirror = false,
  });

  @override
  Widget build(BuildContext context) {
    return Transform(
      // กลับภาพถ้าเป็น local camera (mirror mode)
      transform: mirror
          ? (Matrix4.identity()..scale(-1.0, 1.0, 1.0))
          : Matrix4.identity(),
      alignment: Alignment.center,
      child: RTCVideoView(
        renderer,
        objectFit: isFullScreen
            ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
            : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        mirror: false, // จัดการ mirror เองด้วย Transform ข้างบน
      ),
    );
  }
}
