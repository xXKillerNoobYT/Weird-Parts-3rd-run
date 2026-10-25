import Foundation
import CoreFoundation
#if !NATIVE_NETWORK_DIAGNOSTIC_GUARDS
import Cocoa
import CoreWLAN
import Darwin
import FlutterMacOS
import Network

class MainFlutterWindow: NSWindow {
  private let networkDiagnostic = NearbyNetworkDiagnosticChannel()

  override func close() {
    networkDiagnostic.cancel()
    super.close()
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let wifiChannel = FlutterMethodChannel(
      name: "wired_parts/nearby_wifi",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let networkDiagnostic = self.networkDiagnostic
    wifiChannel.setMethodCallHandler { call, result in
      if call.method == "diagnoseLocalTcp" || call.method == "cancelLocalTcpDiagnostic" {
        networkDiagnostic.handle(call, result: result)
        return
      }
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
#endif

struct NearbyDiagnosticTarget {
  let attempt: String
  let controller: Int
  let generation: Int
  let request: Int
  let address: String
  let port: UInt16
  let sourceAddress: String
  let source: UInt32
  let interfaceIndex: UInt32
  let prefix: Int

  static func integer(_ value: Any?, maximum: Int = Int(Int32.max)) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: number.objCType)),
      number.int64Value >= 1, number.int64Value <= Int64(maximum) else { return nil }
    return number.intValue
  }

  static func ipv4(_ text: String) -> UInt32? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard text.utf8.count <= 15, parts.count == 4 else { return nil }
    var result: UInt32 = 0
    for part in parts {
      guard !part.isEmpty, part == "0" || part.first != "0",
        part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let byte = UInt8(part) else { return nil }
      result = (result << 8) | UInt32(byte)
    }
    return result
  }

  static func isPrivate(_ address: UInt32) -> Bool {
    address & 0xff000000 == 0x0a000000 || address & 0xfff00000 == 0xac100000
      || address & 0xffff0000 == 0xc0a80000
  }

  static func prefixLength(_ mask: UInt32) -> Int? {
    let prefix = mask.nonzeroBitCount
    guard (1...30).contains(prefix), mask == UInt32.max << (32 - prefix) else { return nil }
    return prefix
  }

  static func parse(_ arguments: Any?) -> NearbyDiagnosticTarget? {
    guard let args = arguments as? [String: Any],
      Set(args.keys) == ["attempt", "run", "controller", "generation", "request", "address",
        "port", "sourceAddress", "interfaceIndex", "prefixLength"],
      let attempt = args["attempt"] as? String,
      UUID(uuidString: attempt)?.uuidString.lowercased() == attempt,
      let run = args["run"] as? String,
      run.range(of: "^g2-users-[0-9]{8}-[a-z0-9][a-z0-9-]{0,29}$", options: .regularExpression) == (run.startIndex..<run.endIndex),
      let controller = integer(args["controller"]), let generation = integer(args["generation"]),
      let request = integer(args["request"]), let port = integer(args["port"], maximum: 65535),
      let index = integer(args["interfaceIndex"]), let prefix = integer(args["prefixLength"], maximum: 30),
      let address = args["address"] as? String, let peer = ipv4(address), isPrivate(peer),
      let sourceAddress = args["sourceAddress"] as? String, let source = ipv4(sourceAddress), isPrivate(source)
    else { return nil }
    let mask = UInt32.max << (32 - prefix)
    let network = source & mask
    let broadcast = network | ~mask
    guard peer & mask == network, peer != source, peer != network, peer != broadcast,
      source != network, source != broadcast else { return nil }
    return NearbyDiagnosticTarget(attempt: attempt, controller: controller, generation: generation,
      request: request, address: address, port: UInt16(port), sourceAddress: sourceAddress,
      source: source, interfaceIndex: UInt32(index), prefix: prefix)
  }

  #if !NATIVE_NETWORK_DIAGNOSTIC_GUARDS
  func matchesActiveWifi() -> Bool {
    let names = Set((CWWiFiClient.shared().interfaces() ?? []).compactMap { $0.interfaceName })
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return false }
    defer { freeifaddrs(head) }
    var cursor = head
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let value = entry.pointee
      guard names.contains(String(cString: value.ifa_name)),
        if_nametoindex(value.ifa_name) == interfaceIndex,
        value.ifa_flags & UInt32(IFF_UP) != 0, value.ifa_flags & UInt32(IFF_RUNNING) != 0,
        let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
        let mask = value.ifa_netmask, mask.pointee.sa_family == UInt8(AF_INET) else { continue }
      let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
      }
      if local == source && Self.prefixLength(netmask) == prefix { return true }
    }
    return false
  }
  #endif
}

#if !NATIVE_NETWORK_DIAGNOSTIC_GUARDS
private final class NearbyNetworkDiagnosticChannel {
  private var active: NearbyLocalTcpDiagnostic?
  private static var spent = false

  deinit { active?.finish("cancelled", deliver: false) }

  func cancel() { active?.finish("cancelled") }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "cancelLocalTcpDiagnostic" {
      guard let args = call.arguments as? [String: Any], Set(args.keys) == ["attempt"],
        let attempt = args["attempt"] as? String,
        UUID(uuidString: attempt)?.uuidString.lowercased() == attempt else {
        result(FlutterError(code: "diagnostic_arguments", message: nil, details: nil))
        return
      }
      if active?.target.attempt == attempt { cancel() }
      result(nil)
      return
    }
    guard !Self.spent, active == nil, let target = NearbyDiagnosticTarget.parse(call.arguments),
      target.matchesActiveWifi() else {
      result(FlutterError(code: "diagnostic_refused", message: nil, details: nil))
      return
    }
    Self.spent = true
    let probe = NearbyLocalTcpDiagnostic(target: target) { [weak self] response in
      self?.active = nil
      result(response)
    }
    active = probe
    probe.start()
  }
}

private final class NearbyLocalTcpDiagnostic {
  let target: NearbyDiagnosticTarget
  private let connection: NWConnection
  private let started = DispatchTime.now().uptimeNanoseconds
  private var completion: (([String: Any]) -> Void)?
  private var deadline: DispatchWorkItem?
  private var events = [[String: Any]]()
  private var state = "setup"
  private var error: NWError?
  private var previous = ""
  private static let utc: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  init(target: NearbyDiagnosticTarget, completion: @escaping ([String: Any]) -> Void) {
    self.target = target
    self.completion = completion
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .wifi
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(target.sourceAddress), port: .any)
    parameters.includePeerToPeer = false
    connection = NWConnection(host: NWEndpoint.Host(target.address), port: NWEndpoint.Port(rawValue: target.port)!, parameters: parameters)
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] value in
      guard let self = self, self.completion != nil else { return }
      self.error = nil
      switch value {
      case .setup: self.state = "setup"
      case .preparing: self.state = "preparing"
      case .waiting(let error): self.state = "waiting"; self.error = error
      case .ready: self.state = "ready"
      case .failed(let error): self.state = "failed"; self.error = error
      case .cancelled: self.state = "cancelled"
      @unknown default: self.state = "unknown"
      }
      self.capture(self.connection.currentPath)
      if ["ready", "failed", "cancelled"].contains(self.state) { self.finish(self.state) }
    }
    connection.pathUpdateHandler = { [weak self] path in self?.capture(path) }
    let deadline = DispatchWorkItem { [weak self] in self?.finish("timedOut") }
    self.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
    connection.start(queue: .main)
  }

  private func capture(_ path: NWPath?, force: Bool = false) {
    guard completion != nil else { return }
    var status = "unavailable"
    var reason = "unavailable"
    if let path = path {
      switch path.status {
      case .satisfied: status = "satisfied"
      case .unsatisfied: status = "unsatisfied"
      case .requiresConnection: status = "requiresConnection"
      @unknown default: status = "other"
      }
      if path.status == .satisfied { reason = "none" } else {
        switch path.unsatisfiedReason {
        case .notAvailable: reason = "notAvailable"
        case .cellularDenied: reason = "cellularDenied"
        case .wifiDenied: reason = "wifiDenied"
        case .localNetworkDenied: reason = "localNetworkDenied"
        default: reason = "other"
        }
      }
    }
    var domain = "none"
    var code: Any = NSNull()
    if let error = error {
      switch error {
      case .posix(let value): domain = "posix"; code = Int(value.rawValue)
      case .dns(let value): domain = "dns"; code = Int(value)
      case .tls(let value): domain = "tls"; code = Int(value)
      @unknown default: domain = "other"
      }
    }
    let signature = "\(state):\(status):\(reason):\(domain):\(code)"
    if !force && signature == previous { return }
    previous = signature
    let record: [String: Any] = ["state": state, "path": status, "reason": reason,
      "domain": domain, "code": code,
      "elapsedMs": min(10000, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)),
      "observedUtc": Self.utc.string(from: Date())]
    if events.count < 8 { events.append(record) } else { events[7] = record }
  }

  func finish(_ outcome: String, deliver: Bool = true) {
    guard let completion = completion else { return }
    capture(connection.currentPath, force: true)
    self.completion = nil
    deadline?.cancel()
    deadline = nil
    connection.stateUpdateHandler = nil
    connection.pathUpdateHandler = nil
    connection.cancel()
    if deliver {
      completion(["attempt": target.attempt, "controller": target.controller,
        "generation": target.generation, "request": target.request, "outcome": outcome, "events": events])
    }
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
#endif
