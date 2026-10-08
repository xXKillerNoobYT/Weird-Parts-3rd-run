import Cocoa
import CoreWLAN
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let wifiChannel = FlutterMethodChannel(
      name: "wired_parts/nearby_wifi",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    wifiChannel.setMethodCallHandler { call, result in
      guard call.method == "ipv4Interfaces" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let wifiNames = Set((CWWiFiClient.shared().interfaces() ?? []).compactMap { $0.interfaceName })
      var interfaces: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&interfaces) == 0 else {
        result(FlutterError(code: "wifi_enumeration", message: "Could not read Wi-Fi interfaces", details: nil))
        return
      }
      defer { freeifaddrs(interfaces) }
      var records = [[String: Any]]()
      var cursor = interfaces
      while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        let value = entry.pointee
        let name = String(cString: value.ifa_name)
        guard wifiNames.contains(name),
          value.ifa_flags & UInt32(IFF_UP) != 0,
          value.ifa_flags & UInt32(IFF_RUNNING) != 0,
          let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
          let mask = value.ifa_netmask else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len),
          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let maskValue = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        let prefix = maskValue.nonzeroBitCount
        let expectedMask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - prefix)
        guard expectedMask == maskValue else { continue }
        records.append(["name": name, "index": Int(if_nametoindex(value.ifa_name)), "address": String(cString: host), "prefixLength": prefix])
      }
      result(records)
    }

    super.awakeFromNib()
  }
}
