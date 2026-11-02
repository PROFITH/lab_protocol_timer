// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Added for lab_protocol_timer (PROFITH): choice of the microphone that the
// camera records. Upstream camera_windows always takes the first audio
// capture device.

import 'package:flutter/services.dart';

/// An audio capture device that Windows offers.
class AudioInput {
  const AudioInput({required this.id, required this.name, this.isDefault = false});

  /// Windows endpoint id; stable for a device on one computer.
  final String id;

  /// Name shown in the Windows sound settings.
  final String name;

  /// True for the Windows default recording device.
  final bool isDefault;
}

/// Lists microphones and chooses the one the next camera opened with audio
/// records. Without a choice, the Windows default recording device is used.
class CameraWindowsAudioInputs {
  static const MethodChannel _channel = MethodChannel('camera_windows/audio_inputs');

  /// Audio capture devices, in the order Media Foundation lists them.
  static Future<List<AudioInput>> list() async {
    final raw = await _channel.invokeListMethod<Object?>('list') ?? const [];
    return [
      for (final item in raw)
        if (item is Map)
          AudioInput(
            id: item['id'] as String? ?? '',
            name: item['name'] as String? ?? '',
            isDefault: item['isDefault'] as bool? ?? false,
          ),
    ];
  }

  /// Microphone for the cameras opened from now on: an [AudioInput.id], or
  /// null for the Windows default. An id that is no longer connected falls
  /// back to the default.
  static Future<void> select(String? id) => _channel.invokeMethod<void>('select', id);
}
