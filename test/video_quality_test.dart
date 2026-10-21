import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lab_protocol_timer/services/video_recording_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Video bitrate', () {
    test('follows the size the camera gives, not the preset', () {
      const hd = Size(1280, 720);
      const fullHd = Size(1920, 1080);
      expect(VideoRecordingService.bitrateFor(hd, VideoQuality.normal), 2500000);
      expect(VideoRecordingService.bitrateFor(hd, VideoQuality.high), 5000000);
      expect(VideoRecordingService.bitrateFor(hd, VideoQuality.compact), 1200000);
      expect(VideoRecordingService.bitrateFor(fullHd, VideoQuality.normal), 5600000);
      // Never below 0.5 Mbit/s, also for a small camera.
      expect(VideoRecordingService.bitrateFor(const Size(320, 240), VideoQuality.compact), 500000);
      expect(VideoRecordingService.nominalSize(ResolutionPreset.veryHigh), fullHd);
    });

    test('says the weight per hour as Windows counts it', () {
      // The 13 minutes of 720p at the old 12 Mbit/s: about 1 GB.
      final old = VideoRecordingService.gigabytesPerHour(12000000) * 13 / 60;
      expect(old, closeTo(1.15, 0.05));
      expect(VideoRecordingService.formatPerHour(2500000), '≈1,1 GB por hora');
      expect(VideoRecordingService.formatPerHour(2500000, withAudio: false), '≈1,0 GB por hora');
      expect(VideoRecordingService.formatBitrate(5600000), '5,6 Mbit/s');
      expect(VideoRecordingService.formatPerHour(35000000), '≈15 GB por hora');
    });

    test('remembers the resolution and quality on this computer', () async {
      SharedPreferences.setMockInitialValues({});
      final first = VideoRecordingService(cameraId: 'cam_room')
        ..resolutionPreset = ResolutionPreset.high
        ..quality = VideoQuality.compact;
      await first.saveSettings();

      final next = VideoRecordingService(cameraId: 'cam_room');
      expect(next.quality, VideoQuality.normal);
      await next.loadSettings();
      expect(next.resolutionPreset, ResolutionPreset.high);
      expect(next.quality, VideoQuality.compact);
      expect(next.qualityLabel, 'Ahorro de espacio');
    });
  });
}
