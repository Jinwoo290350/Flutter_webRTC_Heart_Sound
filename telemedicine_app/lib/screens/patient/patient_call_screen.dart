import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../services/webrtc_service.dart';
import '../../services/audio_service.dart';
import '../../services/patient_recording_service.dart';
import '../../services/_audio_js_stub.dart'
    if (dart.library.js_interop) '../../services/_audio_js_web.dart';
import '../../models/call_state.dart';
import '../../widgets/video_view.dart';

/// หน้าของคนไข้ — เริ่มโทร + simulation stethoscope ด้วย asset files
class PatientCallScreen extends StatefulWidget {
  const PatientCallScreen({super.key});

  @override
  State<PatientCallScreen> createState() => _PatientCallScreenState();
}

class _PatientCallScreenState extends State<PatientCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final AudioService _audio = AudioService();
  final PatientRecordingService _patRec = PatientRecordingService();

  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _showSimPanel = false;
  bool _pcmCapturing = false;
  bool _opusMuted = false;
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
    _audio.dispose();
    _patRec.dispose();
    super.dispose();
  }

  Future<void> _startCall() async {
    final webrtc = context.read<WebRTCService>();
    final roomId = await webrtc.startCall();
    if (roomId != null && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RoomIdDialog(roomId: roomId),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _audio,
      child: MultiProvider(
        providers: [ChangeNotifierProvider.value(value: _patRec)],
        child: Consumer3<WebRTCService, AudioService, PatientRecordingService>(
        builder: (context, webrtc, audio, patRec, _) {
          if (webrtc.localStream != null) {
            _localRenderer.srcObject = webrtc.localStream;
          }
          if (webrtc.remoteStream != null) {
            _remoteRenderer.srcObject = webrtc.remoteStream;
          }
          // sync roomId ให้ service รู้ว่าจะเขียน Firestore room ไหน
          _patRec.setRoomId(webrtc.roomId);

          final isConnected = webrtc.callState == CallState.connected;

          // เริ่ม/หยุด PCM capture ตาม call state
          if (isConnected && !_pcmCapturing) {
            _pcmCapturing = true;
            if (kIsWeb) {
              startPcmCapture(); // Web: JS MediaRecorder
            } else {
              webrtc.startNativePcmCapture(); // Android: AudioRecord → DataChannel
            }
          } else if (!isConnected && _pcmCapturing) {
            _pcmCapturing = false;
            if (kIsWeb) {
              stopPcmCapture();
            } else {
              webrtc.stopNativePcmCapture();
            }
          }

          return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              title: webrtc.roomId != null && !isConnected
                  ? _AppBarRoomId(roomId: webrtc.roomId!)
                  : Text(_buildTitle(webrtc.callState)),
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              actions: [
                _CallStateChip(state: webrtc.callState),
                const SizedBox(width: 8),
              ],
            ),
            body: Stack(
              children: [
                // วิดีโอหมอ (เต็มจอ)
                if (isConnected)
                  VideoView(renderer: _remoteRenderer, isFullScreen: true)
                else
                  _WaitingPlaceholder(state: webrtc.callState),

                // วิดีโอตัวเอง (PiP)
                if (webrtc.localStream != null)
                  Positioned(
                    top: 16, right: 16, width: 120, height: 160,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: VideoView(renderer: _localRenderer, mirror: true),
                    ),
                  ),

                // Room ID badge
                if (webrtc.roomId != null && !isConnected)
                  Positioned(
                    top: 16, left: 16, right: 148,
                    child: _RoomIdBadge(roomId: webrtc.roomId!),
                  ),

                // Simulation panel (สไลด์ขึ้นจากล่าง)
                if (isConnected && _showSimPanel)
                  Positioned(
                    bottom: 100, left: 0, right: 0,
                    child: _SimulationPanel(audio: audio),
                  ),

                // ปุ่มควบคุม
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: _PatientControlBar(
                    callState: webrtc.callState,
                    micEnabled: _micEnabled,
                    cameraEnabled: _cameraEnabled,
                    isSimulating: audio.isSimulating,
                    isRecording: patRec.isRecording,
                    showSimPanel: _showSimPanel,
                    recPosition: _recPosition,
                    onStartCall: _startCall,
                    onToggleMic: () {
                      setState(() => _micEnabled = !_micEnabled);
                      webrtc.toggleMic(_micEnabled);
                    },
                    onToggleCamera: () {
                      setState(() => _cameraEnabled = !_cameraEnabled);
                      webrtc.toggleCamera(_cameraEnabled);
                    },
                    onToggleSteth: () async {
                      // ส่ง signal ก่อน toggle เพื่อลด Firestore delay
                      // (doctor จะได้รับ signal เร็วขึ้น ลด gap เสียงที่หาย)
                      final willEnable = !audio.isSimulating;
                      webrtc.signaling.setHeartMode(willEnable);
                      await audio.toggleSimulation();
                    },
                    onToggleSimPanel: () {
                      setState(() => _showSimPanel = !_showSimPanel);
                    },
                    opusMuted: _opusMuted,
                    onToggleOpus: () {
                      setState(() => _opusMuted = !_opusMuted);
                      webrtc.toggleStethoscope(!_opusMuted);
                    },
                    onToggleRecord: () async {
                      if (patRec.isRecording) {
                        final messenger = ScaffoldMessenger.of(context);
                        final url = await _patRec.stopAndUpload();
                        if (mounted && url != null) {
                          messenger.showSnackBar(
                            const SnackBar(content: Text('อัพโหลดเสร็จแล้ว หมอสามารถเล่นได้แล้ว')),
                          );
                        }
                      } else {
                        await _patRec.startRecording(_recPosition.label);
                      }
                    },
                    onChangePosition: (pos) => setState(() => _recPosition = pos),
                    onHangUp: () async {
                      if (patRec.isRecording) await _patRec.stopAndUpload();
                      await audio.toggleSimulation();
                      await webrtc.hangUp();
                      if (mounted) Navigator.pop(context);
                    },
                  ),
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
      ),
    );
  }

  String _buildTitle(CallState state) {
    switch (state) {
      case CallState.idle:    return 'เริ่มการโทร';
      case CallState.calling: return 'กำลังเชื่อมต่อ...';
      case CallState.connected: return 'กำลังสนทนา';
      default: return 'คนไข้';
    }
  }
}

// ==================== Simulation Panel ====================

/// Panel สำหรับเลือก + เล่นเสียงหัวใจ simulate stethoscope
class _SimulationPanel extends StatelessWidget {
  final AudioService audio;
  const _SimulationPanel({required this.audio});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
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
                const Icon(Icons.hearing, color: Colors.redAccent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'จำลองเสียง Stethoscope',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                // Status playing indicator
                if (audio.isSimulating)
                  const Row(
                    children: [
                      Icon(Icons.graphic_eq, color: Colors.redAccent, size: 16),
                      SizedBox(width: 4),
                      Text('กำลังเล่น', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ],
                  ),
              ],
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          // เลือกตำแหน่ง
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Text('ตำแหน่ง:', style: TextStyle(color: Colors.white60, fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: HeartPosition.values.map((pos) {
                        final selected = audio.simPosition == pos;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => audio.setSimPosition(pos),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: selected ? Colors.redAccent : Colors.white12,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                pos.label,
                                style: TextStyle(
                                  color: selected ? Colors.white : Colors.white60,
                                  fontSize: 13,
                                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // เลือก variant (0=ปกติ, 1-5=ผิดปกติระดับต่างๆ)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Text('ระดับ:', style: TextStyle(color: Colors.white60, fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: audio.simPosition.variants.map((v) {
                        final selected = audio.simVariant == v;
                        final label = v == 'best' ? '⭐ Best' : v == '0' ? 'ปกติ' : 'ระดับ $v';
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => audio.setSimVariant(v),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: selected
                                    ? (v == '0' ? Colors.green : Colors.orange)
                                    : Colors.white12,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: selected ? Colors.white : Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ==================== Control Bar ====================

class _PatientControlBar extends StatelessWidget {
  final CallState callState;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool isSimulating;
  final bool isRecording;
  final bool showSimPanel;
  final HeartPosition recPosition;
  final VoidCallback onStartCall;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final bool opusMuted;
  final VoidCallback onToggleOpus;
  final VoidCallback onToggleSteth;
  final VoidCallback onToggleSimPanel;
  final VoidCallback onToggleRecord;
  final ValueChanged<HeartPosition> onChangePosition;
  final VoidCallback onHangUp;

  const _PatientControlBar({
    required this.callState,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.isSimulating,
    required this.isRecording,
    required this.showSimPanel,
    required this.recPosition,
    required this.opusMuted,
    required this.onStartCall,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onToggleOpus,
    required this.onToggleSteth,
    required this.onToggleSimPanel,
    required this.onToggleRecord,
    required this.onChangePosition,
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
      child: callState == CallState.idle
          ? Center(
              child: FloatingActionButton.extended(
                onPressed: onStartCall,
                backgroundColor: Colors.green,
                icon: const Icon(Icons.videocam, color: Colors.white),
                label: const Text('เริ่มโทร', style: TextStyle(color: Colors.white)),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // ปุ่มไมค์
                _Btn(
                  icon: micEnabled ? Icons.mic : Icons.mic_off,
                  color: micEnabled ? Colors.white24 : Colors.red,
                  label: 'ไมค์',
                  onTap: onToggleMic,
                ),

                // ปุ่ม stethoscope simulate (แสดงตอน connected)
                if (callState == CallState.connected)
                  _Btn(
                    icon: Icons.hearing,
                    color: isSimulating ? Colors.redAccent : Colors.white24,
                    label: isSimulating ? 'หยุดเสียง' : 'เสียงหัวใจ',
                    onTap: onToggleSteth,
                    badge: isSimulating,
                  ),

                // ปุ่ม PCM Only (ปิด Opus stethoscope track)
                if (callState == CallState.connected)
                  _Btn(
                    icon: opusMuted ? Icons.volume_off : Icons.volume_up,
                    color: opusMuted ? Colors.orange : Colors.white24,
                    label: opusMuted ? 'PCM Only' : 'Opus+PCM',
                    onTap: onToggleOpus,
                  ),

                // ปุ่ม record (แสดงตอน connected)
                if (callState == CallState.connected)
                  _Btn(
                    icon: isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                    color: isRecording ? Colors.red : Colors.white24,
                    label: isRecording ? 'หยุด REC' : 'REC',
                    onTap: onToggleRecord,
                    badge: isRecording,
                  ),

                // ปุ่มวางสาย
                _Btn(
                  icon: Icons.call_end,
                  color: Colors.red,
                  size: 64,
                  label: 'วางสาย',
                  onTap: onHangUp,
                ),

                // ปุ่มเลือก sound (แสดงตอน connected)
                if (callState == CallState.connected)
                  _Btn(
                    icon: showSimPanel ? Icons.expand_more : Icons.tune,
                    color: showSimPanel ? Colors.white38 : Colors.white24,
                    label: 'เลือกเสียง',
                    onTap: onToggleSimPanel,
                  ),

                // ปุ่มกล้อง
                _Btn(
                  icon: cameraEnabled ? Icons.videocam : Icons.videocam_off,
                  color: cameraEnabled ? Colors.white24 : Colors.red,
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
                width: size,
                height: size,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, color: Colors.white, size: size * 0.45),
              ),
              if (badge)
                Positioned(
                  top: 2, right: 2,
                  child: Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent, shape: BoxShape.circle,
                    ),
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

// ==================== Misc widgets ====================

class _WaitingPlaceholder extends StatelessWidget {
  final CallState state;
  const _WaitingPlaceholder({required this.state});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state == CallState.calling || state == CallState.waiting)
            const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          Icon(
            state == CallState.idle ? Icons.videocam : Icons.hourglass_top,
            size: 80, color: Colors.white30,
          ),
          const SizedBox(height: 16),
          Text(state.label,
              style: const TextStyle(color: Colors.white70, fontSize: 18)),
        ],
      ),
    );
  }
}

class _RoomIdDialog extends StatelessWidget {
  final String roomId;
  const _RoomIdDialog({required this.roomId});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Room ID'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('แชร์รหัสนี้ให้แพทย์เพื่อเข้าร่วม:'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: SelectableText(
              roomId,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('คัดลอก'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: roomId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('คัดลอกแล้ว!')),
              );
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ปิด')),
      ],
    );
  }
}

class _AppBarRoomId extends StatefulWidget {
  final String roomId;
  const _AppBarRoomId({required this.roomId});

  @override
  State<_AppBarRoomId> createState() => _AppBarRoomIdState();
}

class _AppBarRoomIdState extends State<_AppBarRoomId> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.roomId));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Room: ', style: TextStyle(color: Colors.white60, fontSize: 13)),
          Text(
            widget.roomId.length > 12
                ? '${widget.roomId.substring(0, 12)}...'
                : widget.roomId,
            style: const TextStyle(
              color: Colors.white, fontSize: 13,
              fontFamily: 'monospace', fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 6),
          Icon(
            _copied ? Icons.check : Icons.copy,
            size: 16,
            color: _copied ? Colors.greenAccent : Colors.white60,
          ),
        ],
      ),
    );
  }
}

class _RoomIdBadge extends StatefulWidget {
  final String roomId;
  const _RoomIdBadge({required this.roomId});

  @override
  State<_RoomIdBadge> createState() => _RoomIdBadgeState();
}

class _RoomIdBadgeState extends State<_RoomIdBadge> {
  bool _copied = false;

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.roomId));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Room ID — แชร์ให้แพทย์',
              style: TextStyle(color: Colors.white60, fontSize: 11)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.roomId,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 13,
                    fontFamily: 'monospace', fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _copy,
                child: Icon(
                  _copied ? Icons.check : Icons.copy,
                  color: _copied ? Colors.greenAccent : Colors.white70,
                  size: 18,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CallStateChip extends StatelessWidget {
  final CallState state;
  const _CallStateChip({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state) {
      case CallState.connected: color = Colors.green; break;
      case CallState.calling:
      case CallState.waiting:   color = Colors.orange; break;
      case CallState.error:     color = Colors.red; break;
      default:                  color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(state.label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}
