import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../services/webrtc_service.dart';
import '../../services/recording_service.dart';
import '../../models/call_state.dart';

class DoctorCallScreen extends StatefulWidget {
  const DoctorCallScreen({super.key});
  @override
  State<DoctorCallScreen> createState() => _DoctorCallScreenState();
}

class _DoctorCallScreenState extends State<DoctorCallScreen> {
  final _remoteRenderer = RTCVideoRenderer();
  final _localRenderer = RTCVideoRenderer();
  final _roomCtrl = TextEditingController();
  bool _micOn = true;
  bool _opusMuted = false;
  bool _pcmMuted = false;
  bool _bassBoost = false;

  bool _prevHeartMode = false;
  bool _listenMode = false;       // true = doctor's mic auto-muted to prevent echo loop
  bool _wasMicOnBeforeListen = true; // restore mic state when leaving listen mode

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
    // patient restart heart sound (false → true): auto-unmute doctor's PCM
    if (!_prevHeartMode && webrtc.heartMode && _pcmMuted) {
      setState(() => _pcmMuted = false);
      webrtc.setPcmMuted(false);
    }
    // patient starts heart mode → suggest listen mode (auto-enter)
    if (!_prevHeartMode && webrtc.heartMode && !_listenMode) {
      _enterListenMode();
    }
    // patient stops heart mode → exit listen mode
    if (_prevHeartMode && !webrtc.heartMode && _listenMode) {
      _exitListenMode();
    }
    _prevHeartMode = webrtc.heartMode;
  }

  void _enterListenMode() {
    _wasMicOnBeforeListen = _micOn;
    setState(() {
      _listenMode = true;
      _micOn = false;
    });
    context.read<WebRTCService>().toggleMic(false);
  }

  void _exitListenMode() {
    setState(() {
      _listenMode = false;
      _micOn = _wasMicOnBeforeListen;
    });
    context.read<WebRTCService>().toggleMic(_wasMicOnBeforeListen);
  }

  void _toggleListenMode() {
    if (_listenMode) {
      _exitListenMode();
    } else {
      _enterListenMode();
    }
  }

  @override
  void dispose() {
    try { context.read<WebRTCService>().removeListener(_onWebrtcChange); } catch (_) {}
    _remoteRenderer.dispose();
    _localRenderer.dispose();
    _roomCtrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final webrtc = context.read<WebRTCService>();
    // strip spaces/dashes — user อาจกรอก "123 456" หรือ "123-456"
    final id = _roomCtrl.text.replaceAll(RegExp(r'[\s-]'), '').trim();
    if (id.isEmpty) return;
    await webrtc.joinCall(id);
  }

  void _toggleMic() {
    setState(() => _micOn = !_micOn);
    context.read<WebRTCService>().toggleMic(_micOn);
  }

  void _toggleOpus() {
    setState(() => _opusMuted = !_opusMuted);
    context.read<WebRTCService>().setOpusMuted(_opusMuted);
  }

  /// PCM mute = local PCM playback mute (always toggle)
  /// + cooperative stopHeart signal only when heart mode is active (silence sender)
  void _togglePcm() {
    final webrtc = context.read<WebRTCService>();
    final muted = !_pcmMuted;
    setState(() => _pcmMuted = muted);
    webrtc.setPcmMuted(muted);
    if (muted && webrtc.heartMode) {
      webrtc.sendStopHeart(); // tell patient to stop sending
    }
  }

  void _toggleBass() {
    setState(() => _bassBoost = !_bassBoost);
    context.read<WebRTCService>().setBassBoost(_bassBoost);
  }

  Future<void> _hangup() async {
    await context.read<WebRTCService>().hangUp();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _toggleRecord() async {
    final rec = context.read<RecordingService>();
    final webrtc = context.read<WebRTCService>();
    if (rec.isRecording) {
      await rec.stop();
    } else {
      final label = webrtc.heartPosition ?? 'Recording ${rec.recordings.length + 1}';
      try {
        await rec.start(label);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('บันทึกไม่สำเร็จ: $e'), duration: const Duration(seconds: 2)),
          );
        }
      }
    }
  }

  void _showRecordings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey.shade900,
      builder: (_) => Consumer<RecordingService>(
        builder: (_, rec, __) {
          if (rec.recordings.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('ยังไม่มีบันทึก', style: TextStyle(color: Colors.white70)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: rec.recordings.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
            itemBuilder: (_, i) {
              final r = rec.recordings[i];
              return ListTile(
                leading: const Icon(Icons.audiotrack, color: Colors.pinkAccent),
                title: Text(r.label, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  '${r.createdAt.hour.toString().padLeft(2, '0')}:'
                  '${r.createdAt.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.play_arrow, color: Colors.greenAccent),
                      onPressed: () => _playRecording(r.blobUrl),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () => rec.remove(r.id),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _playRecording(String blobUrl) {
    // Use a transient overlay <audio> in document — simplest cross-platform play
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('เล่นบันทึก'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Native HTML audio via flutter_webrtc not needed — open in new tab
              ElevatedButton.icon(
                onPressed: () {
                  // open blob URL in new tab for playback
                  // Note: blob: URLs cannot be opened directly via launchUrl
                  // simplest: use anchor click via JS
                  // For now, show URL in dialog (user can copy)
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('ปิด'),
              ),
              const SizedBox(height: 8),
              SelectableText(blobUrl, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
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

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text('แพทย์ — ${webrtc.callState.label}'),
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
          ),
          body: !inCall
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextField(
                          controller: _roomCtrl,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          maxLength: 7, // 6 digits + 1 space "XXX XXX"
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4,
                            fontFamily: 'monospace',
                          ),
                          decoration: const InputDecoration(
                            labelText: 'รหัสห้อง (6 หลัก)',
                            hintText: '123 456',
                            border: OutlineInputBorder(),
                            fillColor: Colors.white,
                            filled: true,
                            counterText: '',
                          ),
                          onSubmitted: (_) => _join(),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _join,
                          icon: const Icon(Icons.call),
                          label: const Text('เข้าร่วม'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                            textStyle: const TextStyle(fontSize: 16),
                          ),
                        ),
                        if (webrtc.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(webrtc.errorMessage!, style: const TextStyle(color: Colors.redAccent)),
                        ],
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    Positioned.fill(child: RTCVideoView(_remoteRenderer)),
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
                    // Heart mode banner — แสดงตอน patient ส่งเสียงหัวใจ
                    if (webrtc.heartMode && connected)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _HeartBanner(
                          position: webrtc.heartPosition ?? 'Heart',
                          opusMuted: _opusMuted,
                          pcmMuted: _pcmMuted,
                          bassBoost: _bassBoost,
                          onToggleBass: _toggleBass,
                        ),
                      ),
                    // Listen Mode banner — กดเพื่อ toggle mic mute (กัน echo ตอนฟังเสียงหัวใจ)
                    if (connected)
                      Positioned(
                        top: webrtc.heartMode ? 60 : 12,
                        left: 12,
                        child: _ListenModeButton(
                          active: _listenMode,
                          onTap: _toggleListenMode,
                        ),
                      ),
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
                          icon: _opusMuted ? Icons.volume_off : Icons.volume_up,
                          color: _opusMuted ? Colors.orange.shade700 : Colors.grey.shade700,
                          tooltip: 'Opus (voice)',
                          onTap: _toggleOpus,
                        ),
                        _CtrlBtn(
                          icon: _pcmMuted ? Icons.heart_broken : Icons.favorite,
                          color: _pcmMuted
                              ? Colors.red.shade700
                              : (webrtc.heartMode ? Colors.pinkAccent : Colors.grey.shade700),
                          tooltip: _pcmMuted
                              ? 'ปิดเสียงหัวใจอยู่ — กดเพื่อเปิด'
                              : (webrtc.heartMode ? 'ฟังเสียงหัวใจ — กดเพื่อปิด' : 'ยังไม่มีเสียงหัวใจ'),
                          // Always enabled in call — patient might restart heart sound + user wants toggle
                          onTap: _togglePcm,
                        ),
                        _CtrlBtn(
                          icon: context.watch<RecordingService>().isRecording
                              ? Icons.stop_circle
                              : Icons.fiber_manual_record,
                          color: context.watch<RecordingService>().isRecording
                              ? Colors.red.shade700
                              : Colors.grey.shade700,
                          tooltip: context.watch<RecordingService>().isRecording
                              ? 'หยุดบันทึก'
                              : 'บันทึกเสียงหัวใจ',
                          onTap: webrtc.heartMode ? _toggleRecord : null,
                        ),
                        _CtrlBtn(
                          icon: Icons.library_music,
                          color: Colors.deepPurple.shade400,
                          tooltip: 'ดูบันทึก (${context.watch<RecordingService>().recordings.length})',
                          onTap: _showRecordings,
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

class _HeartBanner extends StatelessWidget {
  final String position;
  final bool opusMuted;
  final bool pcmMuted;
  final bool bassBoost;
  final VoidCallback onToggleBass;
  const _HeartBanner({
    required this.position,
    required this.opusMuted,
    required this.pcmMuted,
    required this.bassBoost,
    required this.onToggleBass,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.pinkAccent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite, color: Colors.pinkAccent, size: 18),
          const SizedBox(width: 6),
          Text(
            'Heart Mode: $position',
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          _ChannelChip(label: 'Opus', active: !opusMuted),
          const SizedBox(width: 4),
          _ChannelChip(label: 'PCM', active: !pcmMuted),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onToggleBass,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: bassBoost ? Colors.deepPurple : Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.graphic_eq, color: Colors.white, size: 13),
                  const SizedBox(width: 3),
                  Text(
                    'Bass+6',
                    style: TextStyle(
                      color: bassBoost ? Colors.white : Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool active;
  const _ChannelChip({required this.label, required this.active});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: active ? Colors.green.shade600 : Colors.grey.shade800,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
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

class _ListenModeButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _ListenModeButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.deepPurple.shade700 : Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Colors.deepPurpleAccent : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.headset : Icons.headset_off,
              color: active ? Colors.white : Colors.white70,
              size: 16,
            ),
            const SizedBox(width: 6),
            Text(
              active ? 'โหมดฟัง (mic ปิด)' : 'พูดได้',
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
