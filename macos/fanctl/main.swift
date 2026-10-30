//  toolshed-fand — fan control for toolshed on Apple Silicon and Intel Macs.
//
//  Why this is a separate binary and not Dart code: talking to the SMC means
//  IOConnectCallStructMethod on the AppleSMC service, which dart:io cannot do.
//  Why it has two roles: measured on this machine (Mac14,7 / M2, Darwin 27)
//  with an unprivileged process, every read succeeded —
//
//      F0Ac 1193 rpm, F0Mn 1199, F0Mx 7199, F0Md 0 (automatic), 113 temperature
//      sensors
//
//  — while every fan write returned 0xe00002c1 (kIOReturnNotPrivileged), and
//  `Ftst`, the unlock key older Macs use, does not exist here (0x84). So reads
//  run as the signed-in user and need no installation at all, and only writes
//  are delegated to a root daemon. `selftest` re-measures that claim instead of
//  trusting this comment.
//
//  Roles:
//    telemetry   read sensors and fans, print JSON. Never writes, run as the user.
//    selftest    report whether this process may write fan control at all.
//    keys        enumerate SMC keys (diagnostics; used to pick sensor groups).
//    serve       the root daemon: applies a policy on a loop, answers the socket.
//    client      one request/reply round trip to the daemon, for the Flutter app.
//    selfcheck   run the policy decision table, no hardware, for CI.
//
//  The safety model, in order of precedence:
//    1. A policy can only ever ask for *more* cooling. The rpm written is
//       clamped to at least the fan's own minimum (F0Mn), so a stale or badly
//       configured policy cannot leave the machine quieter than Apple would.
//    2. Above `criticalTempC` the daemon stops writing and returns the fan to
//       automatic control, because Apple's own curve is more aggressive at that
//       point than any floor a user can configure.
//    3. `leaseSeconds` expiry, SIGTERM and a policy that is disabled each put the
//       fan back to automatic, so an orphaned daemon does not hold the fans.
//
//  The SMC wire protocol (key/value struct, selectors 5/6/8/9, kernel index 2)
//  is Apple's undocumented interface, reproduced here as described by several
//  independent userspace clients.

import Foundation
import IOKit

// --------------------------------------------------------------------- protocol

private let kernelIndex: UInt8 = 2
private let readBytes: UInt8 = 5
private let writeBytes: UInt8 = 6
private let readIndex: UInt8 = 8
private let readKeyInfo: UInt8 = 9

struct SmcKeyData {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct Info {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    var key: UInt32 = 0
    var version = Version()
    var limit = Limit()
    var info = Info()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0)
}

struct SmcValue {
    let key: String
    let type: String
    let bytes: [UInt8]

    /// Scalar reading, decoded by the key's own type. Unknown types return nil
    /// rather than a number whose scale nobody verified.
    var number: Double? {
        switch type {
        case "flt ":
            var f: Float = 0
            withUnsafeMutableBytes(of: &f) { dst in
                for i in 0..<min(4, bytes.count) { dst[i] = bytes[i] }
            }
            return Double(f)
        case "fpe2": // Intel fan values: 14-bit integer with a 2-bit fraction.
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "ui8 ":
            return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 8) | Int(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        case let t where t.hasPrefix("sp"):
            // Fixed point: "sp78" is 7 integer bits and 8 fraction bits.
            let digits = t.dropFirst(2)
            guard digits.count == 2,
                  let fracBits = Int(String(digits.dropFirst()), radix: 16),
                  bytes.count >= 2 else { return nil }
            let raw = Int16((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / Double(1 << fracBits)
        default:
            return nil
        }
    }

    var byte0: UInt8 { bytes.first ?? 0 }
}

/// Encodes a number for a write back into the representation the key itself
/// uses, which is what the firmware checks.
func encode(type: String, size: Int, into value: Double) -> [UInt8]? {
    var out = [UInt8](repeating: 0, count: size)
    switch type {
    case "flt ":
        guard size >= 4 else { return nil }
        var f = Float(value)
        withUnsafeBytes(of: &f) { src in
            for i in 0..<4 { out[i] = src[i] }
        }
    case "fpe2":
        let rpm = Int(value)
        guard rpm >= 0, rpm <= 16383 else { return nil } // would silently wrap
        out[0] = UInt8(rpm >> 6)
        out[1] = UInt8((rpm << 2) & 0xff)
    case "ui8 ":
        guard value >= 0, value <= 255 else { return nil }
        out[0] = UInt8(value)
    case "ui16":
        guard size >= 2, value >= 0, value <= 65535 else { return nil }
        out[0] = UInt8(Int(value) >> 8)
        out[1] = UInt8(Int(value) & 0xff)
    case let t where t.hasPrefix("sp"):
        let digits = t.dropFirst(2)
        guard digits.count == 2, let fracBits = Int(String(digits.dropFirst()), radix: 16) else { return nil }
        let scaled = Int16(value * Double(1 << fracBits))
        out[0] = UInt8((UInt16(bitPattern: scaled) >> 8) & 0xff)
        out[1] = UInt8(UInt16(bitPattern: scaled) & 0xff)
    default:
        return nil
    }
    return out
}

func fourcc(_ string: String) -> UInt32? {
    let utf8 = Array(string.utf8)
    guard utf8.count == 4 else { return nil }
    return UInt32(utf8[0]) << 24 | UInt32(utf8[1]) << 16 | UInt32(utf8[2]) << 8
        | UInt32(utf8[3])
}

func fromFourcc(_ value: UInt32) -> String {
    let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                 UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

// -------------------------------------------------------------------- the client

struct SmcWriteError: Error {
    let iokit: kern_return_t
    let smcResult: UInt8
    var name: String { String(cString: mach_error_string(iokit)) }
    var isPrivileged: Bool { iokit == kIOReturnSuccess && smcResult == 0 }
}

final class SmcClient {
    private var conn: io_connect_t = 0
    private var opened = false
    /// `F0Md` on the machines we have measured, `F0md` on others: probed, never
    /// assumed, because writing a key that does not exist fails quietly.
    private var modeKeySuffix = "Md"

    init?() {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return nil }
        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        opened = true
    }

    deinit {
        if opened { IOServiceClose(conn) }
    }

    private func call(_ input: inout SmcKeyData, _ output: inout SmcKeyData) -> kern_return_t {
        var outputSize = MemoryLayout<SmcKeyData>.stride
        return IOConnectCallStructMethod(
            conn, UInt32(kernelIndex), &input, MemoryLayout<SmcKeyData>.stride,
            &output, &outputSize)
    }

    /// Key metadata cannot change while the machine is up, and looking it up
    /// costs a round trip per read: one tick reads over a hundred sensors.
    private var infoCache: [UInt32: (type: String, size: Int)] = [:]

    func info(_ key: String) -> (type: String, size: Int)? {
        guard let code = fourcc(key) else { return nil }
        if let cached = infoCache[code] { return cached }
        var input = SmcKeyData(), output = SmcKeyData()
        input.key = code
        input.data8 = readKeyInfo
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0,
              output.info.dataSize > 0 else { return nil }
        let meta = (fromFourcc(output.info.dataType), Int(output.info.dataSize))
        infoCache[code] = meta
        return meta
    }

    func read(_ key: String) -> SmcValue? {
        guard let code = fourcc(key), let meta = info(key) else { return nil }
        var input = SmcKeyData(), output = SmcKeyData()
        input.key = code
        input.data8 = readBytes
        input.info.dataSize = UInt32(meta.size)
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        var bytes: [UInt8] = []
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<meta.size { bytes.append(raw[i]) }
        }
        return SmcValue(key: key, type: meta.type, bytes: bytes)
    }

    func readNumber(_ key: String) -> Double? { read(key)?.number }

    /// Writes exactly the key's own byte width: a size mismatch is rejected.
    func write(_ key: String, _ value: Double) -> Result<Void, SmcWriteError> {
        guard let meta = info(key), let code = fourcc(key) else {
            return .failure(SmcWriteError(iokit: kIOReturnBadArgument, smcResult: 0))
        }
        guard let payload = encode(type: meta.type, size: meta.size, into: value) else {
            return .failure(SmcWriteError(iokit: kIOReturnBadArgument, smcResult: 0))
        }
        var input = SmcKeyData(), output = SmcKeyData()
        input.key = code
        input.data8 = writeBytes
        input.info.dataSize = UInt32(meta.size)
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for i in 0..<min(payload.count, 32) { dst[i] = payload[i] }
        }
        let io = call(&input, &output)
        // IOKit can report success while the firmware still says no, so both
        // halves have to agree before we claim a fan changed.
        guard io == kIOReturnSuccess else {
            return .failure(SmcWriteError(iokit: io, smcResult: output.result))
        }
        guard output.result == 0 else {
            return .failure(SmcWriteError(iokit: kIOReturnSuccess, smcResult: output.result))
        }
        return .success(())
    }

    // ---------------------------------------------------------------- inventory

    var fanCount: Int { Int(readNumber("FNum") ?? 0) }

    func modeKey(_ fan: Int) -> String {
        "F\(fan)\(modeKeySuffix)"
    }

    /// Probes the mode key's spelling once per fan.
    func resolveModeKey(_ fan: Int) {
        for suffix in ["Md", "md"] where info("F\(fan)\(suffix)") != nil {
            modeKeySuffix = suffix
            return
        }
        modeKeySuffix = "Md"
    }

    func fan(_ fan: Int) -> Fan? {
        guard let actual = readNumber("F\(fan)Ac") else { return nil }
        resolveModeKey(fan)
        return Fan(
            id: fan,
            name: read("F\(fan)ID")?.number.map { "Fan \(Int($0))" } ?? "Fan \(fan)",
            actualRpm: actual,
            minRpm: readNumber("F\(fan)Mn") ?? 0,
            maxRpm: readNumber("F\(fan)Mx") ?? 0,
            targetRpm: readNumber("F\(fan)Tg"),
            mode: Int(read(modeKey(fan))?.byte0 ?? 0),
            modeKey: modeKey(fan))
    }

    /// The key at an index, for enumerating what a machine actually has.
    func keyAt(_ index: Int) -> String? {
        var input = SmcKeyData(), output = SmcKeyData()
        input.data8 = readIndex
        input.data32 = UInt32(index)
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        return fromFourcc(output.key)
    }

    /// Cached on first use: enumerating costs one call per key on the machine
    /// (1,756 on this M2), which would make every policy tick take seconds. The
    /// live reading still range-checks each sensor every time, so a key that
    /// starts reporting nonsense drops out without a re-enumeration.
    private var temperatureKeys: [String]?

    func temperatureSensors() -> [Sensor] {
        let keys = temperatureKeys ?? discoverTemperatureKeys()
        temperatureKeys = keys
        var sensors: [Sensor] = []
        for key in keys {
            guard let value = read(key), let degrees = value.number,
                  degrees > 0, degrees < 125 else { continue }
            sensors.append(Sensor(key: key, celsius: degrees.rounded(toPlaces: 1), type: value.type))
        }
        return sensors.sorted { $0.celsius > $1.celsius }
    }

    /// Every key with a plausible temperature. `#KEY` holds the count, and
    /// `readIndex` turns an index into a key.
    private func discoverTemperatureKeys() -> [String] {
        guard let countValue = read("#KEY"), let raw = countValue.number else { return [] }
        var keys: [String] = []
        var seen: Set<String> = []
        for index in 0..<Int(raw) {
            guard let key = keyAt(index), !seen.contains(key), key.hasPrefix("T") else { continue }
            seen.insert(key)
            guard let value = read(key), let degrees = value.number, degrees > 0, degrees < 125 else { continue }
            keys.append(key)
        }
        return keys
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

// ----------------------------------------------------------------------- models

struct Sensor: Codable {
    let key: String
    let celsius: Double
    let type: String

    /// The two-character family Apple's naming uses (`Tp` package, `Tg` GPU…).
    var family: String { String(key.prefix(2)) }
}

struct Fan: Codable {
    let id: Int
    let name: String
    let actualRpm: Double
    let minRpm: Double
    let maxRpm: Double
    let targetRpm: Double?

    /// 0 = Apple's automatic control, 1 = forced by us or by another tool.
    let mode: Int
    let modeKey: String

    var isForced: Bool { mode != 0 }
}

struct Telemetry: Codable {
    var at: Int = Int(Date().timeIntervalSince1970)
    var fans: [Fan]
    var sensors: [Sensor]
    var groups: [String: Double]
    var machine: String
    var pid: Int
}

/// One SMC key as read, for `keys`. The sensor groups above were chosen from
/// this output on real hardware rather than from a table of assumptions.
struct KeyRow: Codable {
    let key: String
    let type: String
    let reading: Double?
    let raw: String
}

enum SensorGroup: String, CaseIterable {
    case cpu, gpu, heatSink, all

    /// Families (the first two characters of the SMC key) that belong here.
    ///
    /// These came from `keys --prefix T` on a Mac14,7, which reports 113 usable
    /// sensors: `Tp` (27) and `TC` (3) track each other and run hottest, `TP`
    /// (11) is the same package family, `Tg`/`TM` is the GPU side, `Th`/`TH`
    /// (19) are the heat spreaders, and `Ta` (ambient) and `TB` (battery) are
    /// deliberately left out of every named group because watching the air
    /// around the laptop is not a signal about the CPU. An unknown group name
    /// falls back to `all` rather than silently watching nothing.
    var families: Set<String> {
        switch self {
        case .cpu: return ["Tp", "TC", "TP", "Td"]
        case .gpu: return ["Tg", "TG", "TM"]
        case .heatSink: return ["Th", "TH"]
        case .all: return []
        }
    }
}

func groupMaximums(_ sensors: [Sensor]) -> [String: Double] {
    var out: [String: Double] = [:]
    for group in SensorGroup.allCases {
        let matching = group == .all ? sensors : sensors.filter { group.families.contains($0.family) }
        out[group.rawValue] = matching.map(\.celsius).max()
    }
    return out
}

func selectedTemperature(_ sensors: [Sensor], group: String) -> Double? {
    let maximums = groupMaximums(sensors)
    if let named = maximums[group] { return named }
    return maximums["all"]
}

// ------------------------------------------------------------------ the policy

struct Policy: Codable {
    var enabled: Bool = true
    var fan: Int = 0
    var group: String = SensorGroup.cpu.rawValue

    /// At or above this the daemon takes over from Apple's curve.
    var targetTempC: Double = 70
    var holdRpm: Double = 2_400

    /// Extra rpm per degree above the target, so the fan answers the load
    /// instead of sitting at one number.
    var rampPerDegree: Double = 250

    /// Disengage only this far below the target, otherwise a temperature sitting
    /// on the threshold flips the fan between two states every tick.
    var hysteresisC: Double = 3
    var intervalSeconds: Int = 3

    /// Hand the fans back to Apple: its own curve is steeper than any floor a
    /// user can configure, so at this point automatic control is the safer bet.
    var criticalTempC: Double = 95

    /// Give up control if the app stops renewing. 0 holds until told otherwise.
    /// The default is a lease rather than forever: a hand-written request that
    /// forgets this field must not leave a fan forced after the client is gone.
    /// `FanPolicy.defaults` in Dart is the same number, and `fan_protocol_test`
    /// pins the two together.
    var leaseSeconds: Int = 30

    static let nearCriticalMarginC = 5.0
    static let rpmWriteTolerance = 25.0
}

enum ControlState: Equatable {
    case automatic
    case holding(rpm: Double)

    var isHolding: Bool { if case .holding = self { return true }; return false }
    var rpm: Double? { if case .holding(let rpm) = self { return rpm }; return nil }
}

struct Decision {
    let state: ControlState
    let reason: String
}

/// The whole control law, with no I/O, so `selfcheck` can exercise it on a
/// machine with no fan and CI can run it without hardware.
func decide(policy: Policy, celsius: Double?, fan: Fan, previous: ControlState) -> Decision {
    guard policy.enabled else {
        return Decision(state: .automatic, reason: "policy is disabled")
    }
    guard let celsius else {
        // An empty group means the configuration names sensors this Mac does not
        // have. Doing nothing visible is the only safe reading of that.
        return Decision(state: .automatic, reason: "no sensor in group \"\(policy.group)\"")
    }
    guard celsius < policy.criticalTempC else {
        return Decision(
            state: .automatic,
            reason: String(format: "thermal guard: %.1f C >= %.0f C, Apple control is safer",
                           celsius, policy.criticalTempC))
    }

    let disengageAt = policy.targetTempC - policy.hysteresisC
    switch previous {
    case .automatic where celsius < policy.targetTempC:
        return Decision(
            state: .automatic,
            reason: String(format: "%.1f C below target %.0f C", celsius, policy.targetTempC))
    case .automatic:
        return Decision(state: .holding(rpm: rpm(for: celsius, policy: policy, fan: fan)),
                        reason: String(format: "%.1f C reached target %.0f C", celsius, policy.targetTempC))
    case .holding where celsius <= disengageAt:
        return Decision(
            state: .automatic,
            reason: String(format: "%.1f C fell %.0f degrees below target", celsius, policy.hysteresisC))
    case .holding:
        return Decision(state: .holding(rpm: rpm(for: celsius, policy: policy, fan: fan)),
                        reason: String(format: "holding, %.1f C", celsius))
    }
}

/// Ramps with load, then clamps into what the fan can physically do. The lower
/// bound is the fan's own minimum, which is what makes a stale policy harmless:
/// it cannot ask for less cooling than Apple's idle.
func rpm(for celsius: Double, policy: Policy, fan: Fan) -> Double {
    if celsius >= policy.criticalTempC - Policy.nearCriticalMarginC {
        return fan.maxRpm > 0 ? fan.maxRpm : policy.holdRpm
    }
    let over = max(0, celsius - policy.targetTempC)
    let wanted = policy.holdRpm + policy.rampPerDegree * over
    let lower = max(fan.minRpm, 0)
    let upper = fan.maxRpm > fan.minRpm ? fan.maxRpm : max(wanted, lower)
    return min(max(wanted, lower), upper).rounded()
}

// --------------------------------------------------------------------- actuator

/// A refused SMC write, carrying the key and both error halves so the app can
/// show the machine's actual answer instead of "it failed".
struct FanWriteFailure: Error, CustomStringConvertible {
    let key: String
    let iokit: kern_return_t
    let smcResult: UInt8

    var description: String {
        "\(key): 0x\(String(format: "%08x", UInt32(bitPattern: iokit))) "
        + "(\(String(cString: mach_error_string(iokit)))) smc=\(smcResult)"
    }

    var isPrivilegeViolation: Bool { iokit == kIOReturnNotPrivileged }
}

/// Fan writes with the retry that thermalmonitord makes necessary: it owns the
/// fans, and the SMC can answer busy while it is deciding.
struct Actuator {
    let smc: SmcClient
    var attempts = 4
    var betweenAttempts: UInt32 = 120_000

    /// Target first, then the mode: the target is ignored while mode is 0, so
    /// writing it before forcing means the fan jumps straight to the right speed
    /// instead of holding whatever Apple last asked for.
    func engage(fan: Int, rpm: Double) -> Result<Void, FanWriteFailure> {
        smc.resolveModeKey(fan)
        return writeAll([("F\(fan)Tg", rpm), (smc.modeKey(fan), 1)])
    }

    func release(fan: Int) -> Result<Void, FanWriteFailure> {
        smc.resolveModeKey(fan)
        return writeAll([("F\(fan)Tg", 0), (smc.modeKey(fan), 0)])
    }

    /// Retries the whole pair as one unit: half a write landing would leave the
    /// fan forced at a stale target, which is worse than a clean failure.
    private func writeAll(_ writes: [(key: String, value: Double)]) -> Result<Void, FanWriteFailure> {
        var last: FanWriteFailure?
        for attempt in 1...attempts {
            var failure: FanWriteFailure?
            for (key, value) in writes {
                guard case .failure(let error) = smc.write(key, value) else { continue }
                failure = FanWriteFailure(key: key, iokit: error.iokit, smcResult: error.smcResult)
                break
            }
            guard let failure else { return .success(()) }
            last = failure
            // No number of retries makes an unprivileged uid privileged, and
            // hammering the SMC after a refusal only delays the answer.
            if failure.isPrivilegeViolation { return .failure(failure) }
            if attempt < attempts { usleep(betweenAttempts) }
        }
        return .failure(last ?? FanWriteFailure(key: "-", iokit: kIOReturnError, smcResult: 0))
    }
}

// -------------------------------------------------------------------- commands

/// What `selftest` measured, so the app can say "control works here" or "it does
/// not" from this machine's answer rather than from a forum post.
struct SelfTestReport: Codable {
    var uid: Int
    var isRoot: Bool
    var canOpenSmc: Bool
    var fanCount: Int
    var fans: [Fan]
    var sensorCount: Int
    var hottest: Sensor?
    var modeKey: String
    var writeAccepted: Bool?
    var writeDetail: String?
    var verdict: String
}

/// Measures whether this process may write fan control, instead of asserting it.
///
/// Touches the mode key only — 1, then straight back to 0 — and never a target,
/// so the fan keeps doing whatever Apple asked of it. This measures permission;
/// it does not exercise it.
func measurePrivileges(_ smc: SmcClient) -> SelfTestReport {
    var report = SelfTestReport(
        uid: Int(getuid()), isRoot: geteuid() == 0, canOpenSmc: true, fanCount: smc.fanCount,
        fans: [], sensorCount: 0, hottest: nil, modeKey: "F0Md",
        writeAccepted: nil, writeDetail: nil, verdict: "")
    if report.fanCount > 0 {
        smc.resolveModeKey(0)
        report.modeKey = smc.modeKey(0)
        report.fans = (0..<report.fanCount).compactMap(smc.fan)
    }
    let sensors = smc.temperatureSensors()
    report.sensorCount = sensors.count
    report.hottest = sensors.first

    if report.fanCount == 0 {
        report.verdict = "reads work, but this Mac reports no fans"
    } else {
        switch smc.write(report.modeKey, 1) {
        case .success:
            report.writeAccepted = true
            _ = smc.write(report.modeKey, 0)
            report.verdict = "fan control writes are accepted as uid \(report.uid)"
        case .failure(let error):
            report.writeAccepted = false
            report.writeDetail = "0x\(String(format: "%08x", UInt32(bitPattern: error.iokit))) (\(error.name)) smc=\(error.smcResult)"
            report.verdict = error.iokit == kIOReturnNotPrivileged
                ? "fan writes refused: uid \(report.uid) is not privileged, so control needs the root daemon"
                : "fan writes refused: \(error.name)"
        }
    }
    return report
}

func runSelfTest(json: Bool) -> Int32 {
    let report: SelfTestReport
    guard let smc = SmcClient() else {
        report = SelfTestReport(
            uid: Int(getuid()), isRoot: geteuid() == 0, canOpenSmc: false, fanCount: 0,
            fans: [], sensorCount: 0, hottest: nil, modeKey: "F0Md", writeAccepted: nil,
            writeDetail: nil, verdict: "cannot open the AppleSMC service")
        if json { emitJSON(report) } else { print(report.verdict) }
        return 1
    }
    report = measurePrivileges(smc)
    if json {
        emitJSON(report)
    } else {
        print("\(report.writeAccepted == true ? "WRITES ACCEPTED" : "WRITES REFUSED") as uid=\(report.uid)")
        print(report.verdict)
        if let detail = report.writeDetail { print("  \(detail)") }
        for fan in report.fans {
            print(String(format: "  fan %d: %.0f rpm, floor %.0f, ceiling %.0f, mode %d",
                         fan.id, fan.actualRpm, fan.minRpm, fan.maxRpm, fan.mode))
        }
        if let hottest = report.hottest {
            print(String(format: "  %d readable temperature sensors, hottest %@ at %.1f C",
                         report.sensorCount, hottest.key, hottest.celsius))
        }
    }
    return report.writeAccepted == true ? 0 : 1
}

func runTelemetry(every seconds: Int, json: Bool) -> Int32 {
    guard let smc = SmcClient() else {
        FileHandle.standardError.write("cannot open the AppleSMC service\n".data(using: .utf8)!)
        return 1
    }
    var iterations = seconds <= 0 ? 1 : seconds
    repeat {
        let sensors = smc.temperatureSensors()
        let count = smc.fanCount
        let fans = count > 0 ? (0..<count).compactMap(smc.fan) : []
        let telemetry = Telemetry(
            fans: fans, sensors: sensors, groups: groupMaximums(sensors),
            machine: machineModel(), pid: Int(getpid()))
        if json {
            emitJSON(telemetry)
        } else {
            for fan in fans {
                print(String(format: "fan %d: %.0f rpm (floor %.0f, ceiling %.0f, mode %d)",
                             fan.id, fan.actualRpm, fan.minRpm, fan.maxRpm, fan.mode))
            }
            if let top = sensors.first {
                print(String(format: "hottest %@: %.1f C across %d readable sensors",
                             top.key, top.celsius, sensors.count))
            }
        }
        iterations -= 1
        if iterations > 0 { sleep(1) }
    } while iterations > 0
    return 0
}

func runKeys(prefix: String, json: Bool) -> Int32 {
    guard let smc = SmcClient(), let countValue = smc.read("#KEY"), let raw = countValue.number else {
        return 1
    }
    var rows: [KeyRow] = []
    for index in 0..<Int(raw) {
        guard let key = smc.keyAt(index), key.hasPrefix(prefix) else { continue }
        let value = smc.read(key)
        rows.append(KeyRow(
            key: key, type: value?.type ?? "-", reading: value?.number,
            raw: (value?.bytes ?? []).prefix(4).map { String(format: "%02x", $0) }.joined()))
    }
    if json {
        emitJSON(rows)
    } else {
        for row in rows { print("\(row.key)  \(row.type)  \(row.reading.map { String(format: "%.2f", $0) } ?? "-")") }
    }
    return 0
}

/// The decision table. `flutter test` runs this, so the control law is covered
/// without a machine that has a fan.
func runSelfCheck(json: Bool) -> Int32 {
    var failures: [String] = []
    var checks = 0
    let fan = Fan(id: 0, name: "Fan 0", actualRpm: 1_200, minRpm: 1_199, maxRpm: 7_199,
                  targetRpm: 1_200, mode: 0, modeKey: "F0Md")
    let policy = Policy()

    func check(_ label: String, _ got: Decision, _ want: ControlState) {
        checks += 1
        if got.state != want {
            failures.append("\(label): got \(got.state) (\(got.reason)), want \(want)")
        }
    }

    check("disabled", decide(policy: Policy(enabled: false), celsius: 99, fan: fan, previous: .automatic), .automatic)
    check("no sensor", decide(policy: policy, celsius: nil, fan: fan, previous: .automatic), .automatic)
    check("below target, idle", decide(policy: policy, celsius: 60, fan: fan, previous: .automatic), .automatic)
    check("at target, engage", decide(policy: policy, celsius: 70, fan: fan, previous: .automatic),
          .holding(rpm: policy.holdRpm))
    check("above target, ramp", decide(policy: policy, celsius: 74, fan: fan, previous: .automatic),
          .holding(rpm: policy.holdRpm + policy.rampPerDegree * 4))
    check("hysteresis band, still holding", decide(policy: policy, celsius: 68.5, fan: fan,
          previous: .holding(rpm: 3_000)), .holding(rpm: policy.holdRpm))
    check("past hysteresis, release", decide(policy: policy, celsius: 66.9, fan: fan,
          previous: .holding(rpm: 3_000)), .automatic)
    check("thermal guard", decide(policy: policy, celsius: 95, fan: fan,
          previous: .holding(rpm: 3_000)), .automatic)
    check("near critical, full tilt", decide(policy: policy, celsius: 90.5, fan: fan,
          previous: .holding(rpm: 3_000)), .holding(rpm: fan.maxRpm))
    check("clamped to fan maximum", decide(policy: Policy(targetTempC: 30, holdRpm: 90_000),
          celsius: 60, fan: fan, previous: .automatic), .holding(rpm: fan.maxRpm))
    check("never below the idle floor", decide(policy: Policy(targetTempC: 30, holdRpm: 200, rampPerDegree: 0),
          celsius: 60, fan: fan, previous: .automatic), .holding(rpm: fan.minRpm))
    check("overshoot cannot go backwards", decide(policy: policy, celsius: 85, fan: fan,
          previous: .holding(rpm: rpm(for: 85, policy: policy, fan: fan))),
          .holding(rpm: policy.holdRpm + policy.rampPerDegree * 15))
    // The exact boundary: releasing at `target - hysteresis` and not a tenth
    // before it is what the two branches above are about.
    check("hysteresis boundary, release", decide(policy: policy, celsius: 67, fan: fan,
          previous: .holding(rpm: 2_400)), .automatic)

    if json {
        emitJSON(SelfCheckResult(checks: checks, failures: failures))
    } else if failures.isEmpty {
        print("selfcheck: \(checks) policy cases passed")
    } else {
        for failure in failures { print("FAIL \(failure)") }
    }
    return failures.isEmpty ? 0 : 1
}

struct SelfCheckResult: Codable {
    let checks: Int
    let failures: [String]
    var verdict: String { failures.isEmpty ? "ok" : "\(failures.count) failed" }
}

// ------------------------------------------------------------------ the daemon

let defaultSocketPath = "/var/run/toolshed-fand.sock"
let defaultLogPath = "/Library/Logs/toolshed-fand.log"

/// Either end can override these through the environment or the command line,
/// which is how the tests and a developer instance reach a daemon without root
/// or /var/run. The LaunchDaemon sets them in its plist.
var socketPath = ProcessInfo.processInfo.environment["TOOLSHED_FAND_SOCKET"] ?? defaultSocketPath
var daemonLogPath = ProcessInfo.processInfo.environment["TOOLSHED_FAND_LOG"] ?? defaultLogPath

/// Applied before any command runs, so `client` talks to the daemon the operator
/// named rather than the one the environment happens to say.
func applyPathOverrides(_ arguments: [String]) {
    if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
        socketPath = arguments[index + 1]
    }
    if let index = arguments.firstIndex(of: "--log"), index + 1 < arguments.count {
        daemonLogPath = arguments[index + 1]
    }
}

struct Request: Codable {
    var cmd: String
    var policy: Policy?
}

struct Reply: Codable {
    var ok: Bool
    var error: String?
    var status: Status?
    var selftest: SelfTestReport?

    struct Status: Codable {
        var pid: Int
        var uid: Int
        var isRoot: Bool
        var fans: [Fan]
        var applied: String
        var appliedRpm: Double?
        var reason: String
        var lastError: String?
        var policy: Policy?
        var leaseExpiresAt: Int?
        var startedAt: Int
        var ticks: Int
        var celsius: Double?
    }
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: daemonLogPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: daemonLogPath, contents: line.data(using: .utf8)!)
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// Owns the SMC connection and the fan state. Everything that touches either
/// goes through its lock: the tick loop and the socket handler are separate
/// threads and two of them writing fan registers at once is exactly the
/// oscillation the hysteresis exists to prevent.
final class Controller {
    private let lock = NSLock()
    let smc: SmcClient
    private var policy: Policy?
    private var state: ControlState = .automatic

    /// Which fan we last wrote to. Without this, a policy that has just been
    /// cleared would leave the fan forced, because there would be no way to know
    /// which fan to hand back.
    private var heldFan: Int?
    private var lastError: String?
    private var lastReason = "no policy has been sent"
    private var lastRenew = Date()
    private let startedAt = Date()
    private var ticks = 0
    private var lastCelsius: Double?

    /// Set by the signal handler so a second signal cannot re-enter the release.
    var shuttingDown = false

    init(smc: SmcClient) { self.smc = smc }

    var intervalSeconds: Int { max(1, policy?.intervalSeconds ?? 3) }

    func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard let policy else {
            if let fanId = heldFan { release(fanId: fanId, reason: lastReason) }
            return
        }
        ticks += 1

        if policy.leaseSeconds > 0, Date().timeIntervalSince(lastRenew) > Double(policy.leaseSeconds) {
            self.policy = nil
            release(fanId: policy.fan, reason: String(format: "lease of %ds expired without a renewal from the app", policy.leaseSeconds))
            return
        }

        let sensors = smc.temperatureSensors()
        let celsius = selectedTemperature(sensors, group: policy.group)
        lastCelsius = celsius
        guard let fan = smc.fan(policy.fan) else {
            reportFailure("fan \(policy.fan) is not readable")
            return
        }

        let decision = decide(policy: policy, celsius: celsius, fan: fan, previous: state)
        lastReason = decision.reason
        switch decision.state {
        case .automatic:
            if let fanId = heldFan { release(fanId: fanId, reason: decision.reason) }
        case .holding(let wanted):
            // Only rewrite the registers when the number actually moved, or when
            // something else has taken the fan out of our hands.
            let drifted = fan.mode == 0
            let changed = state.rpm.map { abs($0 - wanted) >= Policy.rpmWriteTolerance } ?? true
            if changed || drifted {
                switch Actuator(smc: smc).engage(fan: policy.fan, rpm: wanted) {
                case .success:
                    state = .holding(rpm: wanted)
                    heldFan = policy.fan
                    lastError = nil
                    log(String(format: "engaged fan %d at %.0f rpm — %@ (was %.0f, mode %d)",
                               policy.fan, wanted, decision.reason, fan.actualRpm, fan.mode))
                case .failure(let error):
                    // A refused write must not leave us claiming we are holding.
                    state = .automatic
                    reportFailure("write failed: \(error)")
                }
            }
        }
    }

    /// Only the first release failure is logged, then only when it changes: a
    /// daemon that cannot hand the fan back ticks every few seconds, and a log
    /// that repeats one line forever is a log nobody can read.
    private func reportFailure(_ message: String) {
        if lastError != message { log(message) }
        lastError = message
    }

    private func release(fanId: Int, reason: String) {
        switch Actuator(smc: smc).release(fan: fanId) {
        case .success:
            state = .automatic
            heldFan = nil
            lastError = nil
            log("fan \(fanId) returned to automatic control — \(reason)")
        case .failure(let error):
            // heldFan stays set, so the next tick tries again: a fan left forced
            // by a release that failed once is the outcome that must not persist.
            reportFailure("could not return fan \(fanId) to automatic: \(error)")
        }
    }

    /// Before a fresh daemon serves, every fan it finds forced goes back to
    /// Apple. A process that has just started holds no policy, so a forced fan is
    /// either this daemon's own crash residue at a stale target or another tool's
    /// hold — and in neither case is anyone maintaining that number, while Apple's
    /// curve at least still reacts to heat. The log says so out loud, because it
    /// also means starting this tool releases a fan that smcFanControl was holding.
    func releaseAllFans() {
        for fanId in 0..<smc.fanCount {
            lock.lock()
            guard let fan = smc.fan(fanId), fan.mode != 0 else {
                lock.unlock()
                continue
            }
            lock.unlock()
            release(fanId: fanId, reason: """
                daemon started with no policy; fan \(fanId) was forced at \
                \(String(format: "%.0f", fan.targetRpm ?? fan.actualRpm)) rpm \
                (mode \(fan.mode))
                """)
        }
    }

    func apply(_ incoming: Policy) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard incoming.fan < smc.fanCount else {
            return "this Mac reports \(smc.fanCount) fan(s), so fan \(incoming.fan) does not exist"
        }
        policy = incoming
        lastRenew = Date()
        return nil
    }

    /// Releases the fan immediately rather than on the next tick: a pressed
    /// button should not wait for the interval to elapse before the fan is free.
    func clear() {
        lock.lock()
        let fanId = heldFan
        policy = nil
        lastReason = "control was released"
        lock.unlock()
        if let fanId { release(fanId: fanId, reason: "control was released") }
    }

    func status() -> Reply.Status {
        lock.lock()
        defer { lock.unlock() }
        let count = smc.fanCount
        let fans = count > 0 ? (0..<count).compactMap(smc.fan) : []
        let expires: Int?
        if let policy, policy.leaseSeconds > 0 {
            expires = Int(lastRenew.addingTimeInterval(Double(policy.leaseSeconds)).timeIntervalSince1970)
        } else {
            expires = nil
        }
        let applied: String
        switch state {
        case .automatic: applied = policy == nil ? "not configured" : "automatic"
        case .holding: applied = "holding"
        }
        return Reply.Status(
            pid: Int(getpid()), uid: Int(getuid()), isRoot: geteuid() == 0, fans: fans,
            applied: applied, appliedRpm: state.rpm, reason: lastReason,
            lastError: lastError, policy: policy, leaseExpiresAt: expires,
            startedAt: Int(startedAt.timeIntervalSince1970), ticks: ticks, celsius: lastCelsius)
    }

    /// From the signal handler: put the hardware back before the process dies.
    ///
    /// Only a fan this daemon actually forced is touched. Writing fan 0's mode
    /// key on every exit — the obvious defensive reading of "whatever we believe
    /// its state is" — would hand a fan back to Apple out from under
    /// smcFanControl or Macs Fan Control, which may be holding it legitimately
    /// with this daemon never having written anything. Crash residue is the other
    /// half of that story and `releaseAllFans()` handles it at startup, where a
    /// forced fan genuinely has nobody maintaining it.
    func shutdownNow() {
        lock.lock()
        let fanId = heldFan
        lock.unlock()
        guard let fanId else { return }
        switch Actuator(smc: smc).release(fan: fanId) {
        case .success: log("fan \(fanId) returned to automatic control before exit")
        case .failure(let error): log("exited without releasing fan \(fanId): \(error)")
        }
    }
}

// ------------------------------------------------------------------ the socket

/// GCD releases a dispatch source when its last reference goes, and a released
/// source never fires. Without these the daemon binds the socket, logs that it is
/// serving, and then accepts nothing for ever — and ignores SIGTERM, which is how
/// launchd tells it to give the fans back.
private var retainedAcceptSource: DispatchSourceRead?
private var retainedSignalSources: [DispatchSourceSignal] = []

/// Root-owned Unix socket, one newline-delimited JSON request per connection.
///
/// The app cannot reach the SMC's write path itself, so this is the only way in.
/// Because the socket is world-reachable by design (the GUI user must be able to
/// talk to a root process), the peer's uid is checked instead: root and the
/// user who owns the console only. Otherwise any local account, or any process
/// running as one, could pin the fans.
func serve(_ controller: Controller) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fatalError("socket: \(String(cString: strerror(errno)))") }
    unlink(socketPath)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let utf8 = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for i in 0..<min(utf8.count, buffer.count) { buffer[i] = utf8[i] }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)
    guard bind(fd, withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self) }
    }, length) == 0 else {
        fatalError("bind \(socketPath): \(String(cString: strerror(errno)))")
    }
    // The daemon created it as root; anyone else's umask must not decide who can
    // connect, and the uid check above is what actually protects it.
    _ = chmod(socketPath, 0o666)
    guard listen(fd, 8) == 0 else { fatalError("listen: \(String(cString: strerror(errno)))") }
    log("serving \(socketPath) as uid=\(geteuid()), pid=\(getpid())")

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global())
    source.setEventHandler {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        handle(client, controller)
    }
    source.setCancelHandler { close(fd); unlink(socketPath) }
    retainedAcceptSource = source
    source.resume()
}

private func handle(_ client: Int32, _ controller: Controller) {
    defer { close(client) }
    var peerUid: uid_t = 0
    var peerGid: gid_t = 0
    guard getpeereid(client, &peerUid, &peerGid) == 0 else { return }
    guard peerUid == 0 || peerUid == consoleUid() else {
        reply(client, Reply(ok: false, error: "uid \(peerUid) is not the console user"))
        log("rejected a request from uid \(peerUid)")
        return
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        let read = recv(client, &buffer, buffer.count, 0)
        if read <= 0 { break }
        data.append(contentsOf: buffer[0..<read])
        if data.contains(0x0a) || data.count >= 65_536 { break }
    }
    guard let newline = data.firstIndex(of: 0x0a) else {
        reply(client, Reply(ok: false, error: "expected one newline-delimited JSON request")); return
    }
    guard let request = try? JSONDecoder().decode(Request.self, from: data[data.startIndex..<newline]) else {
        reply(client, Reply(ok: false, error: "that is not a toolshed-fand request")); return
    }

    switch request.cmd {
    case "ping":
        reply(client, Reply(ok: true, status: controller.status()))
    case "status":
        reply(client, Reply(ok: true, status: controller.status()))
    case "apply":
        guard let policy = request.policy else {
            reply(client, Reply(ok: false, error: "apply needs a policy")); return
        }
        if let problem = controller.apply(policy) {
            reply(client, Reply(ok: false, error: problem))
        } else {
            controller.tick()
            reply(client, Reply(ok: true, status: controller.status()))
        }
    case "clear":
        // clear() hands the fan back itself, synchronously: a pressed button
        // should not wait for the next tick to take effect.
        controller.clear()
        reply(client, Reply(ok: true, status: controller.status()))
    case "selftest":
        // Answers the question from the side that can actually write: the app
        // asks its own unprivileged question, and this is the daemon's.
        reply(client, Reply(ok: true, selftest: measurePrivileges(controller.smc)))
    default:
        reply(client, Reply(ok: false, error: "unknown command \"\(request.cmd)\""))
    }
}

private func reply(_ client: Int32, _ value: Reply) {
    let encoder = JSONEncoder()
    guard let payload = try? encoder.encode(value) else { return }
    var line = payload
    line.append(0x0a)
    line.withUnsafeBytes { _ = send(client, $0.baseAddress, $0.count, 0) }
}

private func consoleUid() -> uid_t {
    var statBuffer = stat()
    guard stat("/dev/console", &statBuffer) == 0 else { return 0 }
    return statBuffer.st_uid
}

/// One request, one reply, one short-lived process.
///
/// dart:io has no Unix-domain client, so the Flutter app shells out to this
/// instead of holding a socket open — the same way it already shells out to
/// launchctl and plutil. Requests are a handful per minute, so the process cost
/// is not worth a second protocol over a pipe.
func runClient(_ request: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { print("socket: \(String(cString: strerror(errno)))"); return 1 }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let utf8 = Array(socketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for i in 0..<min(utf8.count, buffer.count) { buffer[i] = utf8[i] }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + utf8.count + 1)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
    }
    guard connected == 0 else {
        print("{\"ok\":false,\"error\":\"cannot reach \(socketPath): \(String(cString: strerror(errno)))\"}")
        return 1
    }
    var line = Data(request.utf8)
    line.append(0x0a)
    line.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, 0) }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let received = recv(fd, &buffer, buffer.count, 0)
        if received <= 0 { break }
        response.append(contentsOf: buffer[0..<received])
        if response.contains(0x0a) { break }
    }
    guard !response.isEmpty else {
        print("{\"ok\":false,\"error\":\"the daemon returned nothing\"}")
        return 1
    }
    FileHandle.standardOutput.write(response)
    return 0
}

// ------------------------------------------------------------------------ main

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value) {
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}

func argumentValue(_ flags: [String], name: String, fallback: String) -> String {
    guard let index = flags.firstIndex(of: name), index + 1 < flags.count else { return fallback }
    return flags[index + 1]
}

func machineModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func usage() -> String {
    """
    toolshed-fand — fan control helper for toolshed

      telemetry [--json] [--every N]     read temperatures and fans as the user
      selftest  [--json]                 report whether this process may write
      keys [--prefix T] [--json]         enumerate SMC keys
      selfcheck [--json]                 run the policy decision table
      serve                              run the root daemon (LaunchDaemon)
      client  <request-json>             one round trip to the daemon's socket

      --socket PATH   override the daemon socket (also $TOOLSHED_FAND_SOCKET)
      --log PATH      override the daemon log  (also $TOOLSHED_FAND_LOG)
    """
}

let flags = CommandLine.arguments
applyPathOverrides(flags)
let command = flags.dropFirst().first ?? "help"
let wantsJSON = flags.contains("--json")

switch command {
case "telemetry":
    let every = Int(argumentValue(flags, name: "--every", fallback: "0")) ?? 0
    exit(runTelemetry(every: every, json: wantsJSON))
case "selftest":
    exit(runSelfTest(json: wantsJSON))
case "keys":
    exit(runKeys(prefix: argumentValue(flags, name: "--prefix", fallback: "T"), json: wantsJSON))
case "selfcheck":
    exit(runSelfCheck(json: wantsJSON))
case "client":
    let request = argumentValue(flags, name: "--request", fallback: "{\"cmd\":\"ping\"}")
    exit(runClient(request))
case "serve":
    // Refuses to come up as a daemon that can do nothing: a root daemon whose
    // writes are refused is a bug, and failing at start is louder than a status
    // line nobody reads. The override is for protocol testing without root, where
    // the refusals are the expected answer and belong in the log.
    let unprivileged = ProcessInfo.processInfo.environment["TOOLSHED_FAND_ALLOW_UNPRIVILEGED"] != nil
    guard geteuid() == 0 || unprivileged else {
        FileHandle.standardError.write(
            "serve must run as root: fan control writes return \(String(format: "0x%08x", UInt32(bitPattern: kIOReturnNotPrivileged))) (kIOReturnNotPrivileged) for anyone else.\n"
                .data(using: .utf8)!)
        exit(1)
    }
    guard let smc = SmcClient() else {
        FileHandle.standardError.write("cannot open the AppleSMC service\n".data(using: .utf8)!)
        exit(1)
    }
    let controller = Controller(smc: smc)
    controller.releaseAllFans()
    serve(controller)
    let loop = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    // The interval is the policy's, so the source re-arms itself after every
    // tick rather than keeping a stale one from before the app connected.
    loop.setEventHandler {
        controller.tick()
        loop.schedule(deadline: .now() + .seconds(controller.intervalSeconds))
    }
    loop.schedule(deadline: .now() + .seconds(controller.intervalSeconds))
    loop.resume()

    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.main)
        signal(signalNumber, SIG_IGN)
        source.setEventHandler {
            guard !controller.shuttingDown else { return }
            controller.shuttingDown = true
            log("signal \(signalNumber): returning the fans to automatic control")
            controller.shutdownNow()
            unlink(socketPath)
            exit(0)
        }
        // Same trap as the accept source: a signal source that nothing retains
        // is released the moment this loop moves on, and the daemon then ignores
        // SIGTERM — which launchd sends when the tool is booted out, so the fan
        // would stay forced after the daemon was gone.
        retainedSignalSources.append(source)
        source.resume()
    }
    dispatchMain()
default:
    print(usage())
    exit(command == "help" ? 0 : 2)
}
