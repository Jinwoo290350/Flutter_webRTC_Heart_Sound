import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../services/webrtc_service.dart';
import '../../services/audio_service.dart';
import '../../services/recording_service.dart';
import '../../services/_audio_js_stub.dart'
    if (dart.library.js_interop) '../../services/_audio_js_web.dart';
import '../../models/call_state.dart';
import '../../widgets/video_view.dart';

/// หน้าของหมอ — รับสาย, สลับโหมด, บันทึก + เล่นซ้ำเสียงหัวใจ
class DoctorCallScreen extends StatefulWidget {
  const DoctorCallScreen({super.key});

  @override
  State<DoctorCallScreen> createState() => _DoctorCallScreenState();
}

class _DoctorCallScreenState extends State<DoctorCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final TextEditingController _roomIdController = TextEditingController();
  final AudioService _audio = AudioService();
  final RecordingService _rec = RecordingService();

  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _showRecordings = false;

  // ตำแหน่งที่กำลัง record (ให้ user เลือก)
  HeartPosition _recPosition = HeartPosition.aortic;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _roomIdController.dispose();
    _audio.dispose();
    _rec.dispose();
    super.dispose();
  }

  void _showJoinDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('เข้าร่วมการโทร'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('กรอก Room ID ที่ได้รับจากคนไข้:'),
            const SizedBox(height: 12),
            TextField(
              controller: _roomIdController,
              decoration: const InputDecoration(
                labelText: 'Room ID',
                border: OutlineInputBorder(),
                hintText: 'วาง Room ID ที่นี่',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ยกเลิก')),
          FilledButton(
            onPressed: () async {
              final roomId = _roomIdController.text.trim();
              if (roomId.isEmpty) return;
              Navigator.pop(ctx);
              await context.read<WebRTCService>().joinCall(roomId);
            },
            child: const Text('เข้าร่วม'),
          ),
        ],
      ),
    );
  }

  void _toggleRecord() {
    if (_rec.isRecording) {
      _rec.stopRecording(_recPosition.label);
    } else {
      _showPositionPicker();
    }
  }

  void _showPositionPicker() {
    final webrtc = context.read<WebRTCService>();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('เลือกตำแหน่งที่ฟัง'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: HeartPosition.values.map((pos) {
            return ListTile(
              title: Text(pos.labelTh),
              leading: Radio<HeartPosition>(
                value: pos,
                groupValue: _recPosition,
                onChanged: (v) {
                  setState(() => _recPosition = v!);
                  Navigator.pop(context);
                  // ส่ง remote stream เพื่อบันทึกเสียงหัวใจจริงจาก WebRTC
                  _rec.startRecording(pos.label, stream: webrtc.remoteStream);
                },
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _audio),
        ChangeNotifierProvider.value(value: _rec),
      ],
      child: Consumer3<WebRTCService, AudioService, RecordingService>(
        builder: (context, webrtc, audio, rec, _) {
          if (webrtc.localStream != null) _localRenderer.srcObject = webrtc.localStream;
          if (webrtc.remoteStream != null) {
            _remoteRenderer.srcObject = webrtc.remoteStream;
            _audio.remoteStream = webrtc.remoteStream;
          }

          final isConnected = webrtc.callState == CallState.connected;
          final isHeart = audio.mode == ListeningMode.heartSound;
          // มือถือ: หน้าจอแคบ (phone/tablet in portrait)
          final isMobile = MediaQuery.of(context).size.shortestSide < 600;

          return Scaffold(
            backgroundColor: isHeart ? const Color(0xFF1A0A0A) : Colors.black,
            appBar: AppBar(
              title: const Text('แพทย์'),
              backgroundColor: isHeart ? const Color(0xFF4A0000) : Colors.black87,
              foregroundColor: Colors.white,
              actions: [
                // แสดงจำนวน recordings
                if (rec.recordings.isNotEmpty)
                  IconButton(
                    icon: Badge(
                      label: Text('${rec.recordings.length}'),
                      child: const Icon(Icons.library_music),
                    ),
                    onPressed: () => setState(() => _showRecordings = !_showRecordings),
                    tooltip: 'Recordings',
                  ),
                if (webrtc.roomId != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        'Room: ${webrtc.roomId!.substring(0, 8)}...',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
            body: Stack(
              children: [
                // วิดีโอคนไข้
                if (isConnected)
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 400),
                    opacity: isHeart ? 0.25 : 1.0,
                    child: VideoView(renderer: _remoteRenderer, isFullScreen: true),
                  )
                else
                  _DoctorWaitingView(state: webrtc.callState, onJoin: _showJoinDialog),

                // PiP ตัวเอง
                if (webrtc.localStream != null && !isHeart)
                  Positioned(
                    top: 16, right: 16, width: 120, height: 160,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: VideoView(renderer: _localRenderer, mirror: true),
                    ),
                  ),

                // Heart mode overlay
                if (isConnected && isHeart)
                  _HeartModeOverlay(
                    isRecording: rec.isRecording,
                    selectedPosition: _recPosition,
                    onPositionChanged: (pos) => setState(() => _recPosition = pos),
                  ),

                // Mode toggle
                if (isConnected)
                  Positioned(
                    top: 16, left: 16,
                    child: _ModeToggle(
                      mode: audio.mode,
                      onToggle: (m) => audio.switchMode(m),
                    ),
                  ),

                // Recording indicator
                if (rec.isRecording)
                  Positioned(
                    top: 16, right: 16,
                    child: _RecordingIndicator(position: _recPosition.label),
                  ),

                // Recordings list panel
                if (_showRecordings && rec.recordings.isNotEmpty)
                  Positioned(
                    bottom: 100, left: 0, right: 0,
                    child: _RecordingsPanel(rec: rec),
                  ),

                // ปุ่มควบคุม
                if (isConnected || webrtc.callState == CallState.waiting)
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: _DoctorControlBar(
                      micEnabled: _micEnabled,
                      cameraEnabled: _cameraEnabled,
                      isRecording: rec.isRecording,
                      isHeart: isHeart,
                      onToggleMic: () {
                        setState(() => _micEnabled = !_micEnabled);
                        webrtc.toggleMic(_micEnabled);
                      },
                      onToggleCamera: () {
                        setState(() => _cameraEnabled = !_cameraEnabled);
                        webrtc.toggleCamera(_cameraEnabled);
                      },
                      onRecord: _toggleRecord,
                      onHangUp: () async {
                        if (rec.isRecording) await rec.cancelRecording();
                        await webrtc.hangUp();
                        if (mounted) Navigator.pop(context);
                      },
                    ),
                  ),

                // มือถือ: แจ้งเตือนหูฟัง + tap to activate audio
                if (isConnected && isMobile)
                  const Positioned(
                    top: 70, left: 0, right: 0,
                    child: _MobileAudioHint(),
                  ),

                // Error
                if (webrtc.callState == CallState.error)
                  Positioned(
                    top: 0, left: 0, right: 0,
                    child: Container(
                      color: Colors.red,
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        webrtc.errorMessage ?? 'เกิดข้อผิดพลาด',
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ==================== Recordings Panel ====================

class _RecordingsPanel extends StatelessWidget {
  final RecordingService rec;
  const _RecordingsPanel({required this.rec});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.library_music, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                const Text('Recordings',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${rec.recordings.length} รายการ',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),

          // List
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rec.recordings.length,
              itemBuilder: (_, i) {
                final r = rec.recordings[i];
                final isPlaying = rec.isPlaying(r.id);
                final isPaused = rec.isPaused(r.id);
                final isCurrent = isPlaying || isPaused;

                return ListTile(
                  dense: true,
                  leading: GestureDetector(
                    onTap: () async {
                      if (isPlaying) {
                        await rec.pause();
                      } else if (isPaused) {
                        await rec.resume();
                      } else {
                        await rec.play(r);
                      }
                    },
                    child: CircleAvatar(
                      backgroundColor: isCurrent ? Colors.redAccent : Colors.white12,
                      child: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  title: Text(
                    '${r.label} — ${r.position}',
                    style: TextStyle(
                      color: isCurrent ? Colors.redAccent : Colors.white,
                      fontSize: 13,
                    ),
                  ),
                  subtitle: isCurrent
                      ? _SeekBar(rec: rec)
                      : Text(
                          _formatTime(r.timestamp),
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 18),
                    onPressed: () => rec.deleteRecording(r.id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _SeekBar extends StatelessWidget {
  final RecordingService rec;
  const _SeekBar({required this.rec});

  @override
  Widget build(BuildContext context) {
    final total = rec.duration.inMilliseconds.toDouble();
    final current = rec.position.inMilliseconds.toDouble().clamp(0.0, total > 0 ? total : 1.0);

    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: Colors.redAccent,
        inactiveTrackColor: Colors.white12,
        thumbColor: Colors.redAccent,
      ),
      child: Slider(
        value: current,
        min: 0,
        max: total > 0 ? total : 1.0,
        onChanged: (v) => rec.seek(Duration(milliseconds: v.toInt())),
      ),
    );
  }
}

// ==================== Heart Mode Overlay ====================

class _HeartModeOverlay extends StatefulWidget {
  final bool isRecording;
  final HeartPosition selectedPosition;
  final ValueChanged<HeartPosition> onPositionChanged;

  const _HeartModeOverlay({
    required this.isRecording,
    required this.selectedPosition,
    required this.onPositionChanged,
  });

  @override
  State<_HeartModeOverlay> createState() => _HeartModeOverlayState();
}

class _HeartModeOverlayState extends State<_HeartModeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _timer;
  int _seconds = 0;
  double _boostDb = 15;
  bool _isPlayingRef = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _timer?.cancel();
    stopReference();
    super.dispose();
  }

  String get _timerLabel {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _toggleReference() {
    setState(() => _isPlayingRef = !_isPlayingRef);
    if (_isPlayingRef) {
      final asset = widget.selectedPosition.assetPath('best');
      playReference(asset);
    } else {
      stopReference();
    }
  }

  // หยุด reference เมื่อเปลี่ยนตำแหน่ง
  void _changePosition(HeartPosition pos) {
    if (_isPlayingRef) {
      stopReference();
      setState(() => _isPlayingRef = false);
    }
    widget.onPositionChanged(pos);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isRecording ? Colors.redAccent : const Color(0xFFEF5350);

    return Positioned.fill(
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 110),
            child: Column(
              children: [
                // ── Heart icon + timer ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ScaleTransition(
                      scale: Tween(begin: 0.85, end: 1.0).animate(
                        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                      ),
                      child: Icon(Icons.favorite, color: color, size: 64),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.isRecording ? 'กำลังบันทึก...' : 'กำลังฟังเสียงหัวใจ',
                          style: TextStyle(
                            color: color,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            const Icon(Icons.timer_outlined, color: Colors.white54, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              _timerLabel,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 18,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 16),
                _AnimatedWaveform(isRecording: widget.isRecording),
                const SizedBox(height: 20),

                // ── Position selector ──
                _SectionLabel(label: 'ตำแหน่งฟัง'),
                const SizedBox(height: 8),
                _PositionSelector(
                  selected: widget.selectedPosition,
                  onChanged: _changePosition,
                ),

                const SizedBox(height: 20),

                // ── Bass boost slider ──
                _SectionLabel(label: 'เพิ่มความถี่ต่ำ (Bass Boost)'),
                const SizedBox(height: 6),
                _BoostSlider(
                  value: _boostDb,
                  onChanged: (v) {
                    setState(() => _boostDb = v);
                    setHeartBoost(v);
                  },
                ),

                const SizedBox(height: 20),

                // ── Reference sound ──
                _SectionLabel(label: 'เสียงอ้างอิง (เปรียบเทียบ)'),
                const SizedBox(height: 8),
                _ReferenceButton(
                  position: widget.selectedPosition,
                  isPlaying: _isPlayingRef,
                  onTap: _toggleReference,
                ),

                const SizedBox(height: 8),
                const Text(
                  '🎧 แนะนำใช้หูฟัง — เสียงหัวใจ 20–500 Hz',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Section label ──
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
            letterSpacing: 0.5,
          ),
        ),
      );
}

// ── Position selector: 4 chips A/M/P/T ──
class _PositionSelector extends StatelessWidget {
  final HeartPosition selected;
  final ValueChanged<HeartPosition> onChanged;
  const _PositionSelector({required this.selected, required this.onChanged});

  static const _labels = {
    HeartPosition.aortic:    ('A', 'Aortic'),
    HeartPosition.mitral:    ('M', 'Mitral'),
    HeartPosition.pulmonary: ('P', 'Pulmonary'),
    HeartPosition.tricuspid: ('T', 'Tricuspid'),
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: HeartPosition.values.map((pos) {
        final (short, full) = _labels[pos]!;
        final isSelected = pos == selected;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(pos),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFEF5350).withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? const Color(0xFFEF5350) : Colors.white12,
                ),
              ),
              child: Column(
                children: [
                  Text(short,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white54,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      )),
                  Text(full,
                      style: TextStyle(
                        color: isSelected ? Colors.white70 : Colors.white30,
                        fontSize: 9,
                      )),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Bass boost slider ──
class _BoostSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _BoostSlider({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            activeTrackColor: const Color(0xFFEF5350),
            inactiveTrackColor: Colors.white12,
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: value,
            min: 0,
            max: 24,
            divisions: 24,
            onChanged: onChanged,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('ปกติ', style: TextStyle(color: Colors.white38, fontSize: 10)),
            Text(
              '+${value.toStringAsFixed(0)} dB',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text('สูงสุด', style: TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ),
      ],
    );
  }
}

// ── Reference sound button ──
class _ReferenceButton extends StatelessWidget {
  final HeartPosition position;
  final bool isPlaying;
  final VoidCallback onTap;
  const _ReferenceButton({
    required this.position,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isPlaying
              ? Colors.green.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isPlaying ? Colors.greenAccent : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isPlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              color: isPlaying ? Colors.greenAccent : Colors.white54,
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              isPlaying
                  ? 'หยุดเสียงอ้างอิง'
                  : 'ฟังเสียง ${position.label} ปกติ (เปรียบเทียบ)',
              style: TextStyle(
                color: isPlaying ? Colors.greenAccent : Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedWaveform extends StatefulWidget {
  final bool isRecording;
  const _AnimatedWaveform({required this.isRecording});

  @override
  State<_AnimatedWaveform> createState() => _AnimatedWaveformState();
}

class _AnimatedWaveformState extends State<_AnimatedWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        size: const Size(280, 60),
        painter: _WaveformPainter(_ctrl.value, widget.isRecording),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double t;
  final bool isRecording;
  _WaveformPainter(this.t, this.isRecording);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isRecording ? Colors.redAccent : const Color(0xFFEF5350)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    final w = size.width;
    final h = size.height;

    // heartbeat pattern
    final beats = [0.0, 0.15, 0.22, 0.28, 0.35, 0.42, 1.0];
    final heights = [0.5, 0.5, 0.05, 0.95, 0.15, 0.5, 0.5];

    for (int i = 0; i < beats.length - 1; i++) {
      final x1 = ((beats[i] + t) % 1.0) * w;
      final x2 = ((beats[i + 1] + t) % 1.0) * w;
      final y1 = h * heights[i];
      final y2 = h * heights[i + 1];
      if (x2 > x1) {
        if (i == 0) path.moveTo(x1, y1);
        path.lineTo(x1, y1);
        path.lineTo(x2, y2);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.t != t;
}

// ==================== Recording Indicator ====================

class _RecordingIndicator extends StatefulWidget {
  final String position;
  const _RecordingIndicator({required this.position});

  @override
  State<_RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<_RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: _ctrl,
            child: const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14),
          ),
          const SizedBox(width: 6),
          Text(
            'REC ${widget.position}',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ==================== Mode Toggle ====================

class _ModeToggle extends StatelessWidget {
  final ListeningMode mode;
  final ValueChanged<ListeningMode> onToggle;
  const _ModeToggle({required this.mode, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isHeart = mode == ListeningMode.heartSound;
    return GestureDetector(
      onTap: () => onToggle(isHeart ? ListeningMode.voice : ListeningMode.heartSound),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isHeart ? const Color(0xFFB71C1C).withOpacity(0.85) : Colors.black54,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isHeart ? const Color(0xFFEF5350) : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                isHeart ? Icons.favorite : Icons.mic,
                key: ValueKey(isHeart),
                color: Colors.white, size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              isHeart ? 'โหมดฟังเสียงหัวใจ' : 'โหมดคุยปกติ',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.swap_horiz, color: Colors.white60, size: 16),
          ],
        ),
      ),
    );
  }
}

// ==================== Waiting + Control ====================

class _DoctorWaitingView extends StatelessWidget {
  final CallState state;
  final VoidCallback onJoin;
  const _DoctorWaitingView({required this.state, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    if (state == CallState.waiting) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('กำลังเชื่อมต่อกับคนไข้...',
                style: TextStyle(color: Colors.white70, fontSize: 18)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.medical_services, size: 80, color: Colors.white30),
          const SizedBox(height: 24),
          const Text('รอรับสายจากคนไข้',
              style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('กรอก Room ID ที่ได้รับจากคนไข้',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: onJoin,
            icon: const Icon(Icons.login),
            label: const Text('กรอก Room ID'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _DoctorControlBar extends StatelessWidget {
  final bool micEnabled;
  final bool cameraEnabled;
  final bool isRecording;
  final bool isHeart;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onRecord;
  final VoidCallback onHangUp;

  const _DoctorControlBar({
    required this.micEnabled,
    required this.cameraEnabled,
    required this.isRecording,
    required this.isHeart,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onRecord,
    required this.onHangUp,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Btn(
            icon: micEnabled ? Icons.mic : Icons.mic_off,
            color: micEnabled ? Colors.white24 : Colors.red,
            label: 'ไมค์',
            onTap: onToggleMic,
          ),

          // ปุ่ม Record (สำคัญใน heart mode)
          _Btn(
            icon: isRecording ? Icons.stop : Icons.fiber_manual_record,
            color: isRecording ? Colors.red : (isHeart ? Colors.redAccent.withOpacity(0.7) : Colors.white24),
            label: isRecording ? 'หยุด REC' : 'บันทึก',
            onTap: onRecord,
            size: isHeart ? 60 : 52,
            badge: isRecording,
          ),

          // วางสาย
          _Btn(
            icon: Icons.call_end,
            color: Colors.red,
            size: 64,
            label: 'วางสาย',
            onTap: onHangUp,
          ),

          _Btn(
            icon: cameraEnabled ? Icons.videocam : Icons.videocam_off,
            color: isHeart ? Colors.white12 : (cameraEnabled ? Colors.white24 : Colors.red),
            label: 'กล้อง',
            onTap: onToggleCamera,
          ),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final String label;
  final VoidCallback onTap;
  final bool badge;

  const _Btn({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    this.size = 52,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: size, height: size,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, color: Colors.white, size: size * 0.45),
              ),
              if (badge)
                Positioned(
                  top: 2, right: 2,
                  child: Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}

// ==================== Mobile Audio Hint ====================

/// แจ้งเตือนสำหรับมือถือ: iOS Safari ต้องการ gesture เพื่อเปิดเสียง
/// และต้องใช้หูฟังเพื่อได้ยินเสียงหัวใจ (ลำโพงมือถือไม่มี bass)
class _MobileAudioHint extends StatefulWidget {
  const _MobileAudioHint();

  @override
  State<_MobileAudioHint> createState() => _MobileAudioHintState();
}

class _MobileAudioHintState extends State<_MobileAudioHint> {
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    // ซ่อนอัตโนมัติหลัง 8 วินาที
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _dismissed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    return Center(
      child: GestureDetector(
        onTap: () => setState(() => _dismissed = true),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.headphones, color: Colors.amber, size: 18),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'ใช้หูฟัง + แตะหน้าจอเพื่อเปิดเสียง',
                  style: TextStyle(color: Colors.amber, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
              SizedBox(width: 8),
              Icon(Icons.close, color: Colors.white38, size: 14),
            ],
          ),
        ),
      ),
    );
  }
}
