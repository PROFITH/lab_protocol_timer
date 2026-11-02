// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Added for lab_protocol_timer (PROFITH): choice of the microphone that the
// camera records. Upstream camera_windows always takes the first audio
// capture device Media Foundation lists.

#ifndef PACKAGES_CAMERA_CAMERA_WINDOWS_WINDOWS_AUDIO_INPUTS_H_
#define PACKAGES_CAMERA_CAMERA_WINDOWS_WINDOWS_AUDIO_INPUTS_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>
#include <vector>

namespace camera_windows {

struct AudioInput {
  // Endpoint id (the same string as IMMDevice::GetId and
  // MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID).
  std::wstring id;
  std::wstring name;
  bool is_default = false;
};

// Audio capture devices in Media Foundation order, with the Windows default
// recording device marked.
std::vector<AudioInput> ListAudioInputs();

// Endpoint id of the Windows default recording device, empty if none.
std::wstring GetDefaultAudioInputId();

// Microphone chosen by the app; empty means the Windows default.
void SetPreferredAudioInputId(const std::wstring& id);
std::wstring GetPreferredAudioInputId();

// Channel "camera_windows/audio_inputs" with the methods "list" and
// "select" (argument: endpoint id, or null for the Windows default).
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateAudioInputsChannel(flutter::BinaryMessenger* messenger);

}  // namespace camera_windows

#endif  // PACKAGES_CAMERA_CAMERA_WINDOWS_WINDOWS_AUDIO_INPUTS_H_
