import 'package:flutter/material.dart';
import 'patient/patient_call_screen.dart';
import 'doctor/doctor_call_screen.dart';
import 'heart_sound_sample_screen.dart';

/// หน้าหลัก — เลือกว่าเป็น "คนไข้" หรือ "หมอ"
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Telemedicine Heart'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ไอคอนหัวใจ
              const Icon(
                Icons.favorite,
                size: 80,
                color: Color(0xFFE53935),
              ),
              const SizedBox(height: 16),
              const Text(
                'ระบบฟังเสียงหัวใจทางไกล',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1565C0),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'กรุณาเลือกบทบาทของคุณ',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 48),

              // ปุ่มคนไข้
              _RoleButton(
                icon: Icons.person,
                label: 'คนไข้',
                subtitle: 'เริ่มการโทรและส่งเสียงหัวใจ',
                color: const Color(0xFF1565C0),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PatientCallScreen(),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ปุ่มหมอ
              _RoleButton(
                icon: Icons.medical_services,
                label: 'แพทย์',
                subtitle: 'รับสาย ฟัง และบันทึกเสียงหัวใจ',
                color: const Color(0xFF2E7D32),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DoctorCallScreen(),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ปุ่มตัวอย่างเสียงหัวใจ
              _RoleButton(
                icon: Icons.hearing,
                label: 'ตัวอย่างเสียงหัวใจ',
                subtitle: 'ฟังเสียงหัวใจปกติ 4 ตำแหน่ง (Aortic, Mitral, Pulmonary, Tricuspid)',
                color: const Color(0xFF6A1B9A),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const HeartSoundSampleScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _RoleButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
            child: Row(
              children: [
                Icon(icon, color: Colors.white, size: 40),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios, color: Colors.white70),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
