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

    let installationSecurity = InstallationSecurityChannel()
    let installationSecurityChannel = FlutterMethodChannel(
      name: "wired_parts/installation_security",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    installationSecurityChannel.setMethodCallHandler { call, result in
      installationSecurity.handle(call, result: result)
    }

    super.awakeFromNib()
  }
}

private enum InstallationSecurityRequest {
  case read(InstallationSecurityNamespace)
  case compareAndSwap(InstallationSecurityNamespace, InstallationSecurityRevision?, ProtectedInstallationState)
  case writeRecoveryFile(String, Data)

  init(_ call: FlutterMethodCall) throws {
    if call.method == "writeRecoveryFileExclusive" {
      guard let arguments = call.arguments as? [String: Any],
        Set(arguments.keys) == ["path", "bytes"],
        let path = arguments["path"] as? String,
        let bytes = arguments["bytes"] as? FlutterStandardTypedData,
        bytes.type == .uInt8 else {
        throw StoreError.invalidArgument
      }
      self = .writeRecoveryFile(path, bytes.data)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
      let rawNamespace = arguments["namespace"] as? String else {
      throw StoreError.invalidArgument
    }
    let namespace = try InstallationSecurityNamespace(rawNamespace)
    if call.method == "readState" {
      guard Set(arguments.keys) == ["namespace"] else { throw StoreError.invalidArgument }
      self = .read(namespace)
      return
    }
    guard Set(arguments.keys).isSubset(of: ["namespace", "expectedRevision", "nextRevision", "bytes"]),
      let rawNextRevision = arguments["nextRevision"] as? String,
      let bytes = arguments["bytes"] as? FlutterStandardTypedData,
      bytes.type == .uInt8 else {
      throw StoreError.invalidArgument
    }
    let expectedRevision: InstallationSecurityRevision?
    if let value = arguments["expectedRevision"], !(value is NSNull) {
      guard let rawExpectedRevision = value as? String else { throw StoreError.invalidArgument }
      expectedRevision = try InstallationSecurityRevision(rawExpectedRevision)
    } else {
      expectedRevision = nil
    }
    let nextState = try ProtectedInstallationState(
      revision: InstallationSecurityRevision(rawNextRevision), bytes: bytes.data)
    self = .compareAndSwap(namespace, expectedRevision, nextState)
  }
}

private final class InstallationSecurityChannel {
  private let store: Result<InstallationSecurityStore, StoreError>

  init() {
    do {
      store = .success(try InstallationSecurityStore())
    } catch let error as StoreError {
      store = .failure(error)
    } catch {
      store = .failure(.unavailable)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "readState" || call.method == "compareAndSwapState" ||
      call.method == "writeRecoveryFileExclusive" else {
      result(FlutterMethodNotImplemented)
      return
    }
    do {
      let request = try InstallationSecurityRequest(call)
      let storage = try store.get()
      switch request {
      case .read(let namespace):
        storage.readState(namespace: namespace) { outcome in
          switch outcome {
          case .success(let state):
            guard let state = state else {
              result(nil)
              return
            }
            result([
              "revision": state.revision.rawValue,
              "bytes": FlutterStandardTypedData(bytes: state.bytes),
            ])
          case .failure(let error):
            result(Self.flutterError(error))
          }
        }
      case .compareAndSwap(let namespace, let expectedRevision, let nextState):
        storage.compareAndSwapState(
          namespace: namespace, expectedRevision: expectedRevision, nextState: nextState
        ) { outcome in
          switch outcome {
          case .success(let revision): result(["revision": revision.rawValue])
          case .failure(let error): result(Self.flutterError(error))
          }
        }
      case .writeRecoveryFile(let path, let bytes):
        storage.writeRecoveryFileExclusive(path: path, bytes: bytes) { outcome in
          switch outcome {
          case .success(let count): result(["written": count])
          case .failure(let error): result(Self.flutterError(error))
          }
        }
      }
    } catch let error as StoreError {
      result(Self.flutterError(error))
    } catch {
      result(Self.flutterError(.unavailable))
    }
  }

  private static func flutterError(_ error: StoreError) -> FlutterError {
    FlutterError(code: error.code, message: error.message, details: error.details)
  }
}
