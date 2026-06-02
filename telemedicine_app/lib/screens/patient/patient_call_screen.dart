import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../services/webrtc_service.dart';
import '../../models/call_state.dart';
import '../../models/heart_position.dart';

class PatientCallScreen extends StatefulWidget {
  const PatientCallScreen({super.key});
  @override
  State<PatientCallScreen> createState() => _PatientCallScreenState();
}

class _PatientCallScreenState extends State<PatientCallScreen> {
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  bool _micOn = true;
  bool _camOn = true;
  bool _opusMuted = false;
  bool _showSimPanel = false;
  bool _heartPlaying = false;
  bool _liveMode = false; // false = play sample WAV, true = live stethoscope mic
  bool _autoHdApplied = false; // auto-enable HD ครั้งเดียวตอน call connect
  HeartPosition _position = HeartPosition.aortic;

  @override
  void initState() {
    super.initState();
    _remoteRenderer.initialize();
    _localRenderer.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<WebRTCService>().addListener(_onWebrtcChange);
    });
  }

  void _onWebrtcChange() {
    if (!mounted) return;
    final webrtc = context.read<WebRTCService>();
    // Auto-enable Soft Expander ตอน connect — suppress self-echo โดยไม่ chop conversation
    if (!_autoHdApplied && webrtc.callState == CallState.connected) {
      _autoHdApplied = true;
      webrtc.enableSoftExpander();
    }
  }

  @override
  void dispose() {
    try { context.read<WebRTCService>().removeListener(_onWebrtcChange); } catch (_) {}
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final webrtc = context.read<WebRTCService>();
    await webrtc.startCall();
    if (webrtc.localStream != null) _localRenderer.srcObject = webrtc.localStream;
  }

  void _toggleMic() {
    setState(() => _micOn = !_micOn);
    context.read<WebRTCService>().toggleMic(_micOn);
  }

  void _toggleCam() {
    setState(() => _camOn = !_camOn);
    context.read<WebRTCService>().toggleCamera(_camOn);
  }

  void _toggleOpus() {
    setState(() => _opusMuted = !_opusMuted);
    context.read<WebRTCService>().setOpusMuted(_opusMuted);
  }

  Future<void> _toggleHeart() async {
    final webrtc = context.read<WebRTCService>();
    if (_heartPlaying) {
      if (_liveMode) {
        await webrtc.stopStethoscopeMic();
      } else {
        await webrtc.stopHeartSound();
      }
      setState(() => _heartPlaying = false);
    } else {
      if (_liveMode) {
        await webrtc.startStethoscopeMic();
      } else {
        await webrtc.startHeartSound(_position.assetPath, _position.label);
      }
      setState(() => _heartPlaying = true);
    }
  }

  Future<void> _changeMode(bool live) async {
    if (live == _liveMode) return;
    final webrtc = context.read<WebRTCService>();
    if (_heartPlaying) {
      // stop current mode first
      if (_liveMode) {
        await webrtc.stopStethoscopeMic();
      } else {
        await webrtc.stopHeartSound();
      }
      setState(() {
        _liveMode = live;
        _heartPlaying = false;
      });
    } else {
      setState(() => _liveMode = live);
    }
  }

  Future<void> _changePosition(HeartPosition pos) async {
    final webrtc = context.read<WebRTCService>();
    setState(() => _position = pos);
    if (_heartPlaying && !_liveMode) {
      // restart with new asset
      await webrtc.stopHeartSound();
      await webrtc.startHeartSound(pos.assetPath, pos.label);
    }
  }

  Future<void> _hangup() async {
    await context.read<WebRTCService>().hangUp();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _copyRoom(String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('คัดลอก Room ID แล้ว'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 6-digit code → "XXX XXX" (อ่านง่ายขึ้น)
  String _formatRoomCode(String id) {
    if (id.length == 6) return '${id.substring(0, 3)} ${id.substring(3)}';
    return id;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WebRTCService>(
      builder: (context, webrtc, _) {
        if (webrtc.localStream != null && _localRenderer.srcObject == null) {
          _localRenderer.srcObject = webrtc.localStream;
        }
        if (webrtc.remoteStream != null && _remoteRenderer.srcObject != webrtc.remoteStream) {
          _remoteRenderer.srcObject = webrtc.remoteStream;
        }

        final connected = webrtc.callState == CallState.connected;
        final inCall = webrtc.callState != CallState.idle && webrtc.callState != CallState.ended;
        final roomId = webrtc.roomId;

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text('คนไข้ — ${webrtc.callState.label}'),
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
          ),
          body: !inCall
              ? Center(
                  child: ElevatedButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.call),
                    label: const Text('เริ่มการโทร'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),
                )
              : Stack(
                  children: [
                    Positioned.fill(child: RTCVideoView(_remoteRenderer)),
                    // PiP local camera (top-right)
                    Positioned(
                      top: 12,
                      right: 12,
                      width: 110,
                      height: 150,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: RTCVideoView(_localRenderer, mirror: true),
                      ),
                    ),
                    // Room ID banner (ตอนยังรอ doctor)
                    if (roomId != null && !connected)
                      Positioned(
                        top: 80,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: GestureDetector(
                            onTap: () => _copyRoom(roomId),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white24, width: 1.5),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'รหัสห้อง',
                                        style: TextStyle(color: Colors.white60, fontSize: 12),
                                      ),
                                      Text(
                                        _formatRoomCode(roomId),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 3,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  const Icon(Icons.copy, color: Colors.white70, size: 20),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Sim panel (slide-up)
                    if (_showSimPanel && connected)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 100,
                        child: _SimPanel(
                          position: _position,
                          playing: _heartPlaying,
                          liveMode: _liveMode,
                          onPositionChanged: _changePosition,
                          onModeChanged: _changeMode,
                          onToggle: _toggleHeart,
                        ),
                      ),
                    // Control bar (bottom)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 24,
                      child: _ControlBar(buttons: [
                        _CtrlBtn(
                          icon: _micOn ? Icons.mic : Icons.mic_off,
                          color: _micOn ? Colors.grey.shade700 : Colors.red,
                          tooltip: 'ไมโครโฟน',
                          onTap: _toggleMic,
                        ),
                        _CtrlBtn(
                          icon: _camOn ? Icons.videocam : Icons.videocam_off,
                          color: _camOn ? Colors.grey.shade700 : Colors.red,
                          tooltip: 'กล้อง',
                          onTap: _toggleCam,
                        ),
                        _CtrlBtn(
                          icon: _opusMuted ? Icons.volume_off : Icons.volume_up,
                          color: _opusMuted ? Colors.orange.shade700 : Colors.grey.shade700,
                          tooltip: _opusMuted ? 'เปิดเสียงหมอ' : 'ปิดเสียงหมอ',
                          onTap: _toggleOpus,
                        ),
                        _CtrlBtn(
                          icon: Icons.favorite,
                          color: _heartPlaying
                              ? Colors.pinkAccent
                              : (_showSimPanel ? Colors.pink : Colors.grey.shade700),
                          tooltip: 'เสียงหัวใจ',
                          onTap: connected ? () => setState(() => _showSimPanel = !_showSimPanel) : null,
                        ),
                        _CtrlBtn(
                          icon: Icons.call_end,
                          color: Colors.red,
                          tooltip: 'วางสาย',
                          onTap: _hangup,
                        ),
                      ]),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _SimPanel extends StatelessWidget {
  final HeartPosition position;
  final bool playing;
  final bool liveMode;
  final void Function(HeartPosition) onPositionChanged;
  final void Function(bool live) onModeChanged;
  final VoidCallback onToggle;

  const _SimPanel({
    required this.position,
    required this.playing,
    required this.liveMode,
    required this.onPositionChanged,
    required this.onModeChanged,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.pinkAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'เสียงหัวใจ',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 8),
          // Mode selector: Sample WAV vs Live stethoscope mic
          Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('🎵 ตัวอย่าง', style: TextStyle(fontSize: 12)),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('🩺 ฟังสด (mic)', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  selected: {liveMode},
                  onSelectionChanged: playing ? null : (s) => onModeChanged(s.first),
                  style: ButtonStyle(
                    foregroundColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected) ? Colors.white : Colors.white70),
                    backgroundColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected) ? Colors.pinkAccent : Colors.white10),
                  ),
                ),
              ),
            ],
          ),
          if (!liveMode) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: HeartPosition.values.map((p) {
                final selected = p == position;
                return ChoiceChip(
                  label: Text(p.label),
                  selected: selected,
                  onSelected: (_) => onPositionChanged(p),
                  backgroundColor: Colors.white12,
                  selectedColor: Colors.pinkAccent,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontSize: 12,
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  liveMode
                      ? 'ถือ stethoscope ติดไมค์ — bass ผ่านได้ (filters OFF)'
                      : 'เล่นตัวอย่างเสียงหัวใจ ${position.label}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: onToggle,
                icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                label: Text(playing ? 'หยุด' : 'เล่น'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: playing ? Colors.red.shade700 : Colors.pinkAccent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;
  const _CtrlBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });
}

class _ControlBar extends StatelessWidget {
  final List<_CtrlBtn> buttons;
  const _ControlBar({required this.buttons});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: buttons.map((b) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Material(
                color: b.color,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: b.onTap,
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: Tooltip(message: b.tooltip, child: Icon(b.icon, color: Colors.white)),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
