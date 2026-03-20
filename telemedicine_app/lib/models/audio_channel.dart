/// โมเดลแทน audio channel แต่ละช่อง
/// Phase 1: มีแค่ voice channel
/// Phase 2: เพิ่ม stethoscope channel
enum AudioChannelType {
  /// เสียงพูด — เปิด filter ปกติ (AEC, NS, AGC = ON)
  voice,

  /// เสียงหัวใจจาก stethoscope — ปิด filter ทั้งหมด
  stethoscope,
}

class AudioChannel {
  final AudioChannelType type;
  final String label;
  final bool filtersEnabled;

  /// ถ้า stethoscope เชื่อมอยู่หรือเปล่า
  bool isActive;

  AudioChannel({
    required this.type,
    required this.label,
    required this.filtersEnabled,
    this.isActive = false,
  });

  static AudioChannel voice() => AudioChannel(
        type: AudioChannelType.voice,
        label: 'เสียงพูด',
        filtersEnabled: true,
        isActive: true,
      );

  static AudioChannel stethoscope() => AudioChannel(
        type: AudioChannelType.stethoscope,
        label: 'เสียงหัวใจ',
        filtersEnabled: false,
        isActive: false,
      );
}
