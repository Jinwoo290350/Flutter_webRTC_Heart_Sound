/// ตำแหน่งฟังหัวใจมาตรฐาน 4 จุด
enum HeartPosition { aortic, mitral, pulmonary, tricuspid }

extension HeartPositionX on HeartPosition {
  String get label {
    switch (this) {
      case HeartPosition.aortic: return 'Aortic';
      case HeartPosition.mitral: return 'Mitral';
      case HeartPosition.pulmonary: return 'Pulmonary';
      case HeartPosition.tricuspid: return 'Tricuspid';
    }
  }

  String get thai {
    switch (this) {
      case HeartPosition.aortic: return 'ลิ้น Aortic';
      case HeartPosition.mitral: return 'ลิ้น Mitral';
      case HeartPosition.pulmonary: return 'ลิ้น Pulmonary';
      case HeartPosition.tricuspid: return 'ลิ้น Tricuspid';
    }
  }

  /// asset URL สำหรับ heart sound sample — Flutter web serves bundled assets ที่ /assets/<pubspec_path>
  /// pubspec ระบุ assets/heart_sounds/... → URL จะเป็น /assets/assets/heart_sounds/...
  String get assetPath {
    switch (this) {
      case HeartPosition.aortic: return 'assets/assets/heart_sounds/aortic_best.wav';
      case HeartPosition.mitral: return 'assets/assets/heart_sounds/mitral_best.wav';
      case HeartPosition.pulmonary: return 'assets/assets/heart_sounds/pulmonary_best.wav';
      case HeartPosition.tricuspid: return 'assets/assets/heart_sounds/tricuspid_best.wav';
    }
  }
}
