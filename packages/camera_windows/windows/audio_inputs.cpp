// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Added for lab_protocol_timer (PROFITH); see audio_inputs.h.

#include "audio_inputs.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <mutex>

#include "com_heap_ptr.h"
#include "string_utils.h"

namespace camera_windows {

using Microsoft::WRL::ComPtr;

namespace {

std::mutex preferred_mutex;
std::wstring preferred_audio_input_id;

}  // namespace

std::wstring GetDefaultAudioInputId() {
  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(hr)) {
    return L"";
  }
  ComPtr<IMMDevice> device;
  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (FAILED(hr) || !device) {
    return L"";
  }
  ComHeapPtr<wchar_t> id;
  hr = device->GetId(&id);
  if (FAILED(hr) || !id) {
    return L"";
  }
  return std::wstring(id);
}

std::vector<AudioInput> ListAudioInputs() {
  std::vector<AudioInput> inputs;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (SUCCEEDED(hr)) {
    hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                             MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID);
  }
  ComHeapPtr<IMFActivate*> devices;
  UINT32 count = 0;
  if (SUCCEEDED(hr)) {
    hr = MFEnumDeviceSources(attributes.Get(), &devices, &count);
  }
  if (FAILED(hr)) {
    return inputs;
  }

  const std::wstring default_id = GetDefaultAudioInputId();
  for (UINT32 i = 0; i < count; i++) {
    ComHeapPtr<wchar_t> id;
    UINT32 id_size = 0;
    ComHeapPtr<wchar_t> name;
    UINT32 name_size = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_ENDPOINT_ID, &id,
            &id_size))) {
      AudioInput input;
      input.id = std::wstring(id, id_size);
      if (SUCCEEDED(devices[i]->GetAllocatedString(
              MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &name_size))) {
        input.name = std::wstring(name, name_size);
      } else {
        input.name = input.id;
      }
      input.is_default = !default_id.empty() && input.id == default_id;
      inputs.push_back(input);
    }
  }
  for (UINT32 i = 0; i < count; i++) {
    devices[i]->Release();
  }
  return inputs;
}

void SetPreferredAudioInputId(const std::wstring& id) {
  std::lock_guard<std::mutex> lock(preferred_mutex);
  preferred_audio_input_id = id;
}

std::wstring GetPreferredAudioInputId() {
  std::lock_guard<std::mutex> lock(preferred_mutex);
  return preferred_audio_input_id;
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateAudioInputsChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "camera_windows/audio_inputs",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "list") {
          flutter::EncodableList list;
          for (const AudioInput& input : ListAudioInputs()) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("id"),
                 flutter::EncodableValue(Utf8FromUtf16(input.id))},
                {flutter::EncodableValue("name"),
                 flutter::EncodableValue(Utf8FromUtf16(input.name))},
                {flutter::EncodableValue("isDefault"),
                 flutter::EncodableValue(input.is_default)},
            }));
          }
          result->Success(flutter::EncodableValue(list));
        } else if (call.method_name() == "select") {
          const auto* id = std::get_if<std::string>(call.arguments());
          SetPreferredAudioInputId(id ? Utf16FromUtf8(*id) : L"");
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  return channel;
}

}  // namespace camera_windows
