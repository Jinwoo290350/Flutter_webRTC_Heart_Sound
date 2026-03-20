import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

/// ข้อมูลของแต่ละตำแหน่งฟังเสียงหัวใจ
class _HeartPosition {
  final String name;
  final String nameTh;
  final String asset;
  final String description;
  final IconData icon;
  final Color color;

  const _HeartPosition({
    required this.name,
    required this.nameTh,
    required this.asset,
    required this.description,
    required this.icon,
    required this.color,
  });
}

/// ใช้ไฟล์ best quality จากผล heart_sound_analysis.csv
/// Aortic_4, Mitral_4, Pulmonary_2, Tricuspid_4
const _positions = [
  _HeartPosition(
    name: 'Aortic',
    nameTh: 'ลิ้นหัวใจ Aortic',
    asset: 'assets/heart_sounds/aortic_best.wav',   // Aortic_4: SNR 24.6dB
    description: 'ฟังที่ช่องซี่โครงที่ 2 ด้านขวา ติดกระดูกอก',
    icon: Icons.arrow_upward,
    color: Color(0xFFE53935),
  ),
  _HeartPosition(
    name: 'Mitral',
    nameTh: 'ลิ้นหัวใจ Mitral',
    asset: 'assets/heart_sounds/mitral_best.wav',   // Mitral_4: LowFreq 94.6%
    description: 'ฟังที่ apex หัวใจ ช่องซี่โครงที่ 5 เส้น midclavicular ซ้าย',
    icon: Icons.favorite,
    color: Color(0xFFD81B60),
  ),
  _HeartPosition(
    name: 'Pulmonary',
    nameTh: 'ลิ้นหัวใจ Pulmonary',
    asset: 'assets/heart_sounds/pulmonary_best.wav', // Pulmonary_2: score สูงสุด
    description: 'ฟังที่ช่องซี่โครงที่ 2 ด้านซ้าย ติดกระดูกอก',
    icon: Icons.air,
    color: Color(0xFF1565C0),
  ),
  _HeartPosition(
    name: 'Tricuspid',
    nameTh: 'ลิ้นหัวใจ Tricuspid',
    asset: 'assets/heart_sounds/tricuspid_best.wav', // Tricuspid_4: SNR 26.0dB สูงสุด
    description: 'ฟังที่ช่องซี่โครงที่ 4-5 ด้านซ้าย ติดกระดูกอก',
    icon: Icons.arrow_downward,
    color: Color(0xFF2E7D32),
  ),
];

/// หน้าสำหรับฟังตัวอย่างเสียงหัวใจปกติ 4 ตำแหน่ง
/// หมอใช้เพื่อเปรียบเทียบกับเสียงหัวใจจริงของคนไข้
class HeartSoundSampleScreen extends StatefulWidget {
  const HeartSoundSampleScreen({super.key});

  @override
  State<HeartSoundSampleScreen> createState() => _HeartSoundSampleScreenState();
}

class _HeartSoundSampleScreenState extends State<HeartSoundSampleScreen> {
  final AudioPlayer _player = AudioPlayer();
  String? _playingAsset;
  PlayerState _playerState = PlayerState.stopped;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingAsset = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(String asset) async {
    if (_playingAsset == asset &&
        _playerState == PlayerState.playing) {
      // กำลังเล่น → หยุด
      await _player.pause();
    } else {
      // เล่นใหม่หรือเปลี่ยนเพลง
      setState(() => _playingAsset = asset);
      await _player.play(AssetSource(asset.replaceFirst('assets/', '')));
    }
  }

  bool _isPlaying(String asset) =>
      _playingAsset == asset && _playerState == PlayerState.playing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ตัวอย่างเสียงหัวใจปกติ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'เกี่ยวกับ',
            onPressed: () => _showInfo(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            color: const Color(0xFF1565C0).withOpacity(0.08),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: const Row(
              children: [
                Icon(Icons.hearing, color: Color(0xFF1565C0)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'กดปุ่มเพื่อฟังเสียงหัวใจปกติแต่ละตำแหน่ง\nแนะนำใช้หูฟังเพื่อได้ยินชัดเจนที่สุด',
                    style: TextStyle(fontSize: 13, color: Color(0xFF1565C0)),
                  ),
                ),
              ],
            ),
          ),

          // Heart diagram placeholder
          _HeartDiagram(playingAsset: _playingAsset),

          // รายการ 4 ตำแหน่ง
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _positions.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final pos = _positions[i];
                final playing = _isPlaying(pos.asset);
                return _SoundCard(
                  position: pos,
                  isPlaying: playing,
                  onTap: () => _togglePlay(pos.asset),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('เกี่ยวกับเสียงหัวใจ'),
        content: const Text(
          'เสียงหัวใจปกติมี 2 จังหวะ:\n\n'
          '• S1 "ลั่บ" — ลิ้นหัวใจ Mitral และ Tricuspid ปิด\n'
          '• S2 "ดั้บ" — ลิ้นหัวใจ Aortic และ Pulmonary ปิด\n\n'
          'ความถี่เสียงหัวใจอยู่ที่ 20–500 Hz\n'
          'ต้องใช้หูฟังที่ response ลงถึง 20 Hz',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );
  }
}

/// Diagram แสดงตำแหน่งบนหน้าอก
class _HeartDiagram extends StatelessWidget {
  final String? playingAsset;
  const _HeartDiagram({this.playingAsset});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 160,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // กระดูกอก (เส้นกลาง)
          Container(
            width: 14,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(4),
            ),
          ),

          // ซี่โครง
          for (int i = 0; i < 5; i++)
            Positioned(
              top: 20.0 + i * 22,
              child: Container(
                width: 160,
                height: 2,
                color: Colors.grey[300],
              ),
            ),

          // จุดตำแหน่งลิ้นหัวใจ
          _DotLabel(
              label: 'A', color: _positions[0].color,
              top: 28, left: 105,
              active: playingAsset == _positions[0].asset),
          _DotLabel(
              label: 'P', color: _positions[2].color,
              top: 28, right: 105,
              active: playingAsset == _positions[2].asset),
          _DotLabel(
              label: 'T', color: _positions[3].color,
              top: 70, right: 95,
              active: playingAsset == _positions[3].asset),
          _DotLabel(
              label: 'M', color: _positions[1].color,
              top: 90, right: 60,
              active: playingAsset == _positions[1].asset),

          // ป้ายกำกับ
          const Positioned(
            bottom: 8,
            child: Text(
              'A=Aortic  P=Pulmonary  T=Tricuspid  M=Mitral',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

class _DotLabel extends StatelessWidget {
  final String label;
  final Color color;
  final double top;
  final double? left;
  final double? right;
  final bool active;

  const _DotLabel({
    required this.label,
    required this.color,
    required this.top,
    this.left,
    this.right,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: active ? 32 : 24,
        height: active ? 32 : 24,
        decoration: BoxDecoration(
          color: active ? color : color.withOpacity(0.3),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
          boxShadow: active
              ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 8)]
              : [],
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : color,
              fontSize: active ? 14 : 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

/// Card แต่ละตำแหน่ง
class _SoundCard extends StatelessWidget {
  final _HeartPosition position;
  final bool isPlaying;
  final VoidCallback onTap;

  const _SoundCard({
    required this.position,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isPlaying
            ? position.color.withOpacity(0.08)
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPlaying ? position.color : Colors.grey[200]!,
          width: isPlaying ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: isPlaying ? position.color : position.color.withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPlaying ? Icons.pause : Icons.play_arrow,
            color: isPlaying ? Colors.white : position.color,
            size: 28,
          ),
        ),
        title: Text(
          position.nameTh,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isPlaying ? position.color : Colors.black87,
          ),
        ),
        subtitle: Text(
          position.description,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        trailing: isPlaying
            ? _PulseIcon(color: position.color)
            : Icon(Icons.hearing, color: Colors.grey[400]),
        onTap: onTap,
      ),
    );
  }
}

/// ไอคอน pulse แสดงเมื่อกำลังเล่น
class _PulseIcon extends StatefulWidget {
  final Color color;
  const _PulseIcon({required this.color});

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.6, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Icon(Icons.graphic_eq, color: widget.color, size: 28),
    );
  }
}
