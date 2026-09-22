#include <winsock2.h>
#include <ws2tcpip.h>

#include "flutter_window.h"

#include <iphlpapi.h>

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr ULONG kInitialAddressBufferSize = 15 * 1024;
constexpr ULONG kMaximumAddressBufferSize = 4 * 1024 * 1024;
constexpr int kMaximumAddressRetries = 4;

struct WifiIpv4Interface {
  std::string name;
  std::string address;
  std::uint8_t prefix_length;
  std::uint32_t index;
};

bool IsExcludedAddress(const IN_ADDR& address) {
  const ULONG host_address = ntohl(address.S_un.S_addr);
  return host_address == 0 || (host_address & 0xff000000UL) == 0x7f000000UL ||
         (host_address & 0xffff0000UL) == 0xa9fe0000UL;
}

bool IsValidUnicastAddress(const IP_ADAPTER_UNICAST_ADDRESS* unicast) {
  if (unicast == nullptr || unicast->Address.lpSockaddr == nullptr ||
      unicast->Address.lpSockaddr->sa_family != AF_INET ||
      unicast->OnLinkPrefixLength > 32) {
    return false;
  }
  const auto* address = reinterpret_cast<const sockaddr_in*>(
      unicast->Address.lpSockaddr);
  return !IsExcludedAddress(address->sin_addr);
}

ULONG EnumerateWifiInterfaces(std::vector<WifiIpv4Interface>* interfaces) {
  std::vector<unsigned char> buffer(kInitialAddressBufferSize);
  ULONG result = ERROR_BUFFER_OVERFLOW;
  IP_ADAPTER_ADDRESSES* adapters = nullptr;

  for (int attempt = 0; attempt < kMaximumAddressRetries &&
                           result == ERROR_BUFFER_OVERFLOW;
       ++attempt) {
    ULONG buffer_size = static_cast<ULONG>(buffer.size());
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    result = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, nullptr,
                                  adapters, &buffer_size);
    if (result == ERROR_BUFFER_OVERFLOW) {
      if (buffer_size == 0 || buffer_size > kMaximumAddressBufferSize) {
        break;
      }
      buffer.resize(buffer_size);
    }
  }

  if (result == ERROR_NO_DATA) {
    return ERROR_NO_DATA;
  }
  if (result != NO_ERROR) {
    return result;
  }

  for (const auto* adapter = adapters; adapter != nullptr;
       adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType != IF_TYPE_IEEE80211) {
      continue;
    }
    const std::string name = Utf8FromUtf16(adapter->FriendlyName);
    for (const auto* unicast = adapter->FirstUnicastAddress;
         unicast != nullptr; unicast = unicast->Next) {
      if (!IsValidUnicastAddress(unicast)) {
        continue;
      }
      const auto* address = reinterpret_cast<const sockaddr_in*>(
          unicast->Address.lpSockaddr);
      char address_text[INET_ADDRSTRLEN] = {};
      if (InetNtopA(AF_INET, &address->sin_addr, address_text,
                    sizeof(address_text)) == nullptr) {
        return static_cast<ULONG>(WSAGetLastError());
      }
      interfaces->push_back(
          {name, address_text, unicast->OnLinkPrefixLength,
           static_cast<std::uint32_t>(adapter->IfIndex)});
    }
  }
  return NO_ERROR;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  flutter::MethodChannel<flutter::EncodableValue> nearby_wifi_channel(
      flutter_controller_->engine()->messenger(), "wired_parts/nearby_wifi",
      &flutter::StandardMethodCodec::GetInstance());
  nearby_wifi_channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "ipv4Interfaces") {
          result->NotImplemented();
          return;
        }
        std::vector<WifiIpv4Interface> interfaces;
        const ULONG error = EnumerateWifiInterfaces(&interfaces);
        if (error == NO_ERROR || error == ERROR_NO_DATA) {
          flutter::EncodableList encoded_interfaces;
          encoded_interfaces.reserve(interfaces.size());
          for (auto& wifi_interface : interfaces) {
            flutter::EncodableMap encoded_interface;
            encoded_interface[flutter::EncodableValue("name")] =
                flutter::EncodableValue(std::move(wifi_interface.name));
            encoded_interface[flutter::EncodableValue("address")] =
                flutter::EncodableValue(std::move(wifi_interface.address));
            encoded_interface[flutter::EncodableValue("prefixLength")] =
                flutter::EncodableValue(
                    static_cast<std::int32_t>(wifi_interface.prefix_length));
            encoded_interface[flutter::EncodableValue("index")] =
                flutter::EncodableValue(
                    static_cast<std::int64_t>(wifi_interface.index));
            encoded_interfaces.emplace_back(std::move(encoded_interface));
          }
          result->Success(
              flutter::EncodableValue(std::move(encoded_interfaces)));
        } else {
          result->Error("nearby_wifi_error",
                        "Windows IPv4 enumeration failed with error " +
                            std::to_string(error));
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
