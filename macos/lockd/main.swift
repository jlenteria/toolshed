//  toolshed-lockd — password gate for opening chosen apps.
//
//  Why this is a separate binary: the thing being detected is an app launch,
//  which lives in LaunchServices and NSWorkspace, and the thing being verified
//  is a passphrase, which must not be compared by two implementations. dart:io
//  can neither observe a launch nor hold a KDF, so both jobs live here.
//
//  What this does, stated plainly, because a lock that oversells itself is
//  worse than no lock:
//
//    macOS gives an ordinary app no way to refuse to launch another app. There
//    is no "ask me first" API; the only client that can veto an exec is an
//    EndpointSecurity system extension, which needs an Apple-issued entitlement
//    and will not load on a Mac that has not been approved for one.
//
//  So this observes and reacts. When an app named in the lock list comes up, the
//  agent asks it to quit — the same event ⌘Q sends, so an app with unsaved work
//  gets to show its own save dialog — then prompts for the passphrase and
//  relaunches it only if the passphrase was right. The window between the launch
//  and the quit is real and is measured in a few hundred milliseconds; the GUI
//  says so rather than claiming a wall.
//
//  After a correct passphrase the app stays open for `unlockMinutes` of
//  *inactivity*, not for that long in total: while the app is in front its
//  deadline keeps moving, so only time spent away from it counts toward locking
//  it again. A stopwatch from the passphrase would close an app that somebody
//  is still using, which is the one thing a lock must never do.
//
//  What it is for: keeping the honest user honest, and making a borrowed or
//  unattended machine ask for a passphrase before Notes, Messages or a password
//  manager comes up. What it is not for: an attacker who has your user session.
//  They can `kill` the agent, edit the config, or run the executable inside the
//  bundle directly. Anything stronger needs to be a different tool with Apple's
//  approval on it.
//
//  Roles:
//    watch     the agent loop. Launched by launchd; nothing else starts it.
//    list      installed and running apps, with their lock state. Prints JSON.
//    status    what the agent believes right now, from the shared state file.
//    setpass   read a passphrase from stdin, store its PBKDF2 hash.
//    haspass   report whether a passphrase is set, without touching the hash.
//    verify    read a passphrase from stdin, report whether it matches.
//    grant     verify a passphrase from stdin, then open one app until it has
//              been idle for the unlock window.
//    revoke    drop an app's allowance early.
//    close     ask one app to quit now, no passphrase involved.
//    prompt    show the passphrase dialog for one app (used by watch, and by
//              the console's "Test the prompt" button).
//    selfcheck  the enforcement decision table and the KDF, no UI, for CI.
//
//  Every path is under ~/Library/Application Support/toolshed and can be
//  relocated with `--store <dir>`, which is what makes these verbs testable
//  without touching a real user's lock list.
//
//  The passphrase is never an argument: argv is readable by any process on the
//  machine through `ps`. It comes in on stdin and leaves as a hash comparison.

import AppKit
import CryptoKit
import Foundation

// ---------------------------------------------------------------------- storage

struct Layout {
    var root: URL

    var config: URL { root.appendingPathComponent("app_lock.json") }
    var secret: URL { root.appendingPathComponent("app_lock_secret.json") }
    var state: URL { root.appendingPathComponent("app_lock_state.json") }
}

private func defaultStore() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return support.appendingPathComponent("toolshed", isDirectory: true)
}

// ----------------------------------------------------------------------- models

/// What the user asked for. Written by the Flutter console, read here.
struct LockConfig: Codable {
    var version: Int = 1
    var enabled: Bool = true
    /// Idle minutes, not wall-clock minutes: while the app is in front the
    /// watcher keeps moving its deadline forward.
    var unlockMinutes: Int = 5
    var forceQuit: Bool = false
    var locked: [LockedApp] = []

    struct LockedApp: Codable, Equatable {
        var bundleId: String
        var name: String
        var path: String
        var armedAt: TimeInterval
    }

    func entry(_ bundleId: String) -> LockedApp? { locked.first { $0.bundleId == bundleId } }
}

/// The passphrase, as a hash and nothing else. Never printed by any verb.
struct StoredSecret: Codable {
    var kdf: String
    var iterations: Int
    var keyLength: Int
    var saltHex: String
    var hashHex: String
    var setAt: TimeInterval
}

/// What is allowed open, and what the agent has recently done. Written by the
/// agent and by `grant`/`revoke`, read by the console.
struct AgentState: Codable {
    /// One app a passphrase has opened. `expiresAt` is a moving deadline: the
    /// watcher pushes it forward while the app is in front, so it measures how
    /// long the app has been left alone rather than how long ago the passphrase
    /// was typed.
    struct Allowance: Codable, Equatable {
        var bundleId: String
        var expiresAt: TimeInterval
        var grantedBy: String
    }

    struct Event: Codable, Equatable {
        var at: TimeInterval
        var bundleId: String
        var action: String
        var detail: String
    }

    var updatedAt: TimeInterval
    var unlocks: [Allowance] = []
    var events: [Event] = []

    /// The pid of the `watch` process that last wrote *this* store.
    ///
    /// Recorded per store because a watcher is not a machine-wide fact: a console
    /// reading a scratch store that is told "watching, pid 65606" is being told an
    /// agent which cannot see that store is enforcing it, which is the one lie a
    /// lock screen cannot be told.
    var watchPid: Int? = nil

    mutating func record(_ event: Event) {
        events.append(event)
        if events.count > 50 { events.removeFirst(events.count - 50) }
        updatedAt = event.at
    }

    /// The remaining life of an allowance, or nil when there is none. Expired
    /// entries are dropped here rather than in a sweep, so a stale file cannot
    /// keep an app open.
    mutating func allowance(for bundleId: String, now: Date) -> TimeInterval? {
        let horizon = now.timeIntervalSince1970
        unlocks = unlocks.filter { $0.expiresAt > horizon }
        return unlocks.first { $0.bundleId == bundleId }?.expiresAt
    }

    mutating func allow(_ bundleId: String, until: TimeInterval, by: String) {
        unlocks.removeAll { $0.bundleId == bundleId }
        unlocks.append(Allowance(bundleId: bundleId, expiresAt: until, grantedBy: by))
        updatedAt = Date().timeIntervalSince1970
    }

    mutating func revoke(_ bundleId: String) {
        unlocks.removeAll { $0.bundleId == bundleId }
        updatedAt = Date().timeIntervalSince1970
    }

    /// A focused app holds its own window open.
    ///
    /// While the app is frontmost the deadline is pushed to `now + minutes`.
    /// The moment it loses focus the deadline stops moving, and the time it has
    /// been away starts counting — which is what makes "open for 5 minutes"
    /// mean five idle minutes rather than five minutes of use. Returns whether
    /// the deadline moved, so the caller knows to rewrite the file.
    @discardableResult
    mutating func keepAlive(_ bundleId: String, at now: Date, minutes: Int) -> Bool {
        guard minutes > 0 else { return false }
        let deadline = now.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970
        var changed = false
        for index in unlocks.indices where unlocks[index].bundleId == bundleId {
            if unlocks[index].expiresAt < deadline {
                unlocks[index].expiresAt = deadline
                changed = true
            }
        }
        if changed { updatedAt = now.timeIntervalSince1970 }
        return changed
    }
}

/// Apps the agent will refuse to close even if a hand-edited config names them.
/// Locking these would log the user out of the session or remove the very
/// controls needed to unlock the machine, which is not a lock but an outage.
private let guardedBundleIds: [String: String] = [
    "com.apple.finder": "closing Finder takes the desktop and every window on it",
    "com.apple.dock": "closing the Dock takes the Dock and the app switcher",
    "com.apple.controlcenter": "closing Control Center takes the menu bar extras",
    "com.apple.SystemUIServer": "closing it takes the menu bar",
    "com.apple.loginwindow": "closing it ends the login session",
    "com.apple.wallpaper.agent": "closing it takes the desktop",
    "com.bling.toolshed": "toolshed hosts the lock; locking it would hide the button that unlocks the rest",
]

// ------------------------------------------------------------------------- kdf

/// PBKDF2-HMAC-SHA256 over CryptoKit, implemented here rather than pulled from
/// CommonCrypto so the single-file build needs no bridging header. The iteration
/// count travels with the hash, so raising it later does not strand an existing
/// passphrase.
func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
    let key = SymmetricKey(data: password)
    var output: [UInt8] = []
    var block: UInt32 = 1
    while output.count < keyLength {
        var counter: [UInt8] = [UInt8](repeating: 0, count: 4)
        counter[0] = UInt8((block >> 24) & 0xff)
        counter[1] = UInt8((block >> 16) & 0xff)
        counter[2] = UInt8((block >> 8) & 0xff)
        counter[3] = UInt8(block & 0xff)
        var u = Array(HMAC<SHA256>.authenticationCode(for: salt + counter, using: key))
        var accumulator = u
        for _ in 1..<max(iterations, 1) {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for index in 0..<accumulator.count { accumulator[index] ^= u[index] }
        }
        output.append(contentsOf: accumulator)
        block += 1
    }
    return Array(output[0..<keyLength])
}

/// Equal-length comparison without an early exit, so a wrong passphrase cannot be
/// found one byte at a time by timing the difference.
func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count { difference |= a[index] ^ b[index] }
    return difference == 0
}

let defaultIterations = 120_000
let derivedKeyLength = 32

/// The lengths the console mirrors in `LockAgentClient`. Eight is not a strong
/// password; it is the point where a phrase stops being a PIN someone could type
/// by accident, which is the mistake this tool is built to survive. The helper
/// checks anyway, because a passphrase set from a terminal never sees the UI.
let minPassLength = 8
let maxPassLength = 512

func hexEncode(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func hexDecode(_ text: String) -> [UInt8]? {
    var bytes: [UInt8] = []
    var nibble: UInt8?
    for character in text {
        guard let value = character.hexDigitValue else { return nil }
        if let high = nibble {
            bytes.append(high << 4 | UInt8(value))
            nibble = nil
        } else {
            nibble = UInt8(value)
        }
    }
    return nibble == nil ? bytes : nil
}

private func randomSalt(length: Int = 16) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    let result = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
    precondition(result == errSecSuccess, "no source of randomness")
    return bytes
}

// -------------------------------------------------------------------- file i/o

func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

func saveJSON(_ value: Encodable, to url: URL, fileMode: mode_t? = nil) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return "could not encode \(url.lastPathComponent)" }
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let mode = fileMode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        return nil
    } catch {
        return "could not write \(url.path): \(error.localizedDescription)"
    }
}

func readPassphraseFromStdin() -> String? {
    let handle = FileHandle.standardInput
    let data = handle.readDataToEndOfFile()
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    // A pipe always brings a newline; a passphrase that happens to end in one is
    // not a thing anyone types deliberately, so trim the single trailing break.
    if text.hasSuffix("\n") { text.removeLast() }
    if text.hasSuffix("\r") { text.removeLast() }
    return text
}

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[toolshed-lockd \(stamp)] \(message)\n".utf8))
}

// ----------------------------------------------------------------------- output

func emit(_ value: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func succeed(_ fields: [String: Any] = [:]) {
    var payload: [String: Any] = ["ok": true]
    for (key, value) in fields { payload[key] = value }
    emit(payload)
}

func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message])
    exit(1)
}

// ---------------------------------------------------------------------- reading

struct AppSnapshot {
    var bundleId: String
    var name: String
    var path: String
    var running: Bool
    var pid: Int?
    var locked: Bool
    var lockable: Bool
    var whyNotLockable: String?
    var unlockedUntil: Double?
}

/// Desktop apps, from the five places LaunchServices keeps them, plus anything
/// currently running as a desktop app that is not in those directories.
///
/// Only apps the agent would actually close. A background service is not a
/// thing a person opens, so it is not a thing this list offers to lock:
/// menu-bar extras and agents declare themselves with
/// `LSUIElement`/`LSBackgroundOnly`, and a running app that is not `.regular`
/// has no Dock tile and no window to close. The guard list — Finder, the Dock,
/// the menu bar, the session, toolshed itself — is left out for the opposite
/// reason: those entries would be checkboxes the helper refuses to honour.
/// An app that is already locked stays listed even if it falls into either
/// group, because hiding it would hide the only place its lock can be removed.
///
/// Foundation does this in one process: `Bundle(path:)` reads the Info.plist, so
/// there is no `plutil` per app and no Spotlight dependency. A machine with 300
/// bundles takes about a tenth of a second.
func installedApps(store: Layout) -> [AppSnapshot] {
    let config = loadJSON(LockConfig.self, from: store.config)
    var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    let now = Date()

    var found: [String: AppSnapshot] = [:]
    let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]
    let finder = FileManager.default

    for root in roots {
        guard let children = try? finder.contentsOfDirectory(atPath: root) else { continue }
        for child in children where child.hasSuffix(".app") {
            let path = root + "/" + child
            guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { continue }
            guard config?.entry(identifier) != nil
                || (guardedBundleIds[identifier] == nil && !isBackgroundOnly(bundle)) else { continue }
            found[identifier] = snapshot(bundleId: identifier,
                                        name: displayName(bundle, fallback: child),
                                        path: path,
                                        config: config,
                                        state: &state,
                                        now: now)
        }
    }

    for running in NSWorkspace.shared.runningApplications {
        guard let identifier = running.bundleIdentifier else { continue }
        // A locked app is always listed, even a guarded one, so the list is the
        // one place its lock can be taken off. Everything else in the guard
        // list is not an option: the agent will never close it.
        guard config?.entry(identifier) != nil || guardedBundleIds[identifier] == nil else { continue }
        let known = found[identifier] != nil || config?.entry(identifier) != nil
        // `.regular` is the Dock-and-windows policy. Accessory items, XPC
        // services and background agents are not apps a user acts on, and a
        // list of things to lock that includes them is mostly noise.
        guard known || running.activationPolicy == .regular else { continue }
        let path = running.bundleURL?.path ?? found[identifier]?.path ?? ""
        var snapshot = found[identifier] ?? snapshot(bundleId: identifier,
                                                    name: running.localizedName ?? identifier,
                                                    path: path,
                                                    config: config,
                                                    state: &state,
                                                    now: now)
        snapshot.running = true
        snapshot.pid = Int(running.processIdentifier)
        found[identifier] = snapshot
    }

    return found.values.sorted {
        let left = $0.name.lowercased(), right = $1.name.lowercased()
        return left == right ? $0.bundleId < $1.bundleId : left < right
    }
}

private func displayName(_ bundle: Bundle, fallback: String) -> String {
    let info = bundle.infoDictionary
    for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let value = info?[key] as? String, !value.isEmpty { return value }
    }
    return fallback.replacingOccurrences(of: ".app", with: "")
}

/// Whether a bundle says it has no window of its own. Info.plist booleans reach
/// Swift as `Bool`, `Int` or `String` depending on who wrote them, so all three
/// spellings of "yes" count.
private func isBackgroundOnly(_ bundle: Bundle) -> Bool {
    let info = bundle.infoDictionary
    for key in ["LSUIElement", "LSBackgroundOnly"] {
        switch info?[key] {
        case let flag as Bool: if flag { return true }
        case let flag as Int: if flag != 0 { return true }
        case let flag as String:
            if flag == "1" || flag.lowercased() == "true" { return true }
        default: break
        }
    }
    return false
}

private func snapshot(bundleId: String, name: String, path: String, config: LockConfig?,
                      state: inout AgentState, now: Date) -> AppSnapshot {
    let guardReason = guardedBundleIds[bundleId]
    return AppSnapshot(
        bundleId: bundleId,
        name: name,
        path: path,
        running: false,
        pid: nil,
        locked: config?.entry(bundleId) != nil,
        lockable: guardReason == nil,
        whyNotLockable: guardReason,
        unlockedUntil: state.allowance(for: bundleId, now: now)
    )
}

private func dictionary(_ app: AppSnapshot) -> [String: Any] {
    var value: [String: Any] = [
        "bundleId": app.bundleId,
        "name": app.name,
        "path": app.path,
        "running": app.running,
        "locked": app.locked,
        "lockable": app.lockable,
    ]
    if let pid = app.pid { value["pid"] = pid }
    if let reason = app.whyNotLockable { value["whyNotLockable"] = reason }
    if let until = app.unlockedUntil { value["unlockedUntil"] = until }
    return value
}

// ---------------------------------------------------------------- the decision

enum Verdict: Equatable {
    /// Not named in the lock list, or the lock is switched off.
    case leave
    /// Named, and holding an allowance that has not expired.
    case permitted(until: TimeInterval)
    /// Named and closed. `reason` says why, for the log and the console.
    case close(reason: String)
    /// Named but unenforceable: no passphrase set, so closing it would only be
    /// a nuisance with nothing to unlock it again.
    case misconfigured
}

/// The whole enforcement rule, as a pure function, so `selfcheck` can prove the
/// ordering without launching anything.
func decide(now: Date, config: LockConfig?, secretSet: Bool,
            bundleId: String, state: inout AgentState) -> Verdict {
    guard let config = config, config.enabled else { return .leave }
    guard config.entry(bundleId) != nil else { return .leave }
    if guardedBundleIds[bundleId] != nil {
        return .close(reason: "guarded, and closing it would take the session with it")
    }
    if !secretSet { return .misconfigured }
    if let until = state.allowance(for: bundleId, now: now) { return .permitted(until: until) }
    return .close(reason: "locked and no allowance is live")
}

// ------------------------------------------------------------------------ verbs

func storeFlag(_ arguments: [String]) -> Layout {
    if let index = arguments.firstIndex(of: "--store"), index + 1 < arguments.count {
        return Layout(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
    }
    return Layout(root: defaultStore())
}

func valueFlag(_ arguments: [String], _ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func commandList(_ arguments: [String]) {
    let store = storeFlag(arguments)
    let apps = installedApps(store: store)
    succeed(["apps": apps.map(dictionary), "store": store.root.path])
}

func commandStatus(_ arguments: [String]) {
    let store = storeFlag(arguments)
    let config = loadJSON(LockConfig.self, from: store.config)
    var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    let secret = loadJSON(StoredSecret.self, from: store.secret)
    let now = Date()
    let watchPid = watcherPid(store: store)

    let running = NSWorkspace.shared.runningApplications.compactMap { application -> [String: Any]? in
        guard let identifier = application.bundleIdentifier else { return nil }
        guard config?.entry(identifier) != nil else { return nil }
        var value: [String: Any] = [
            "bundleId": identifier,
            "name": application.localizedName ?? identifier,
            "pid": Int(application.processIdentifier),
        ]
        if let until = state.allowance(for: identifier, now: now) { value["unlockedUntil"] = until }
        return value
    }

    succeed([
        "status": [
            "uid": Int(geteuid()),
            "store": store.root.path,
            // The agent is the only thing that can close an app; a console that
            // is open without it has a list of locks that do nothing. Reported
            // with its pid because the console's own process is not the watcher,
            // and a `pid` naming the wrong process would be worse than none.
            "watching": watchPid != nil,
            "watchPid": watchPid ?? 0,
            "secret": [
                "set": secret != nil,
                "iterations": secret?.iterations ?? 0,
                "setAt": secret?.setAt ?? 0,
            ],
            "config": [
                "present": config != nil,
                "enabled": config?.enabled ?? false,
                "unlockMinutes": config?.unlockMinutes ?? 0,
                "forceQuit": config?.forceQuit ?? false,
                "lockedCount": config?.locked.count ?? 0,
            ],
            "running": running,
            "unlocks": state.unlocks.map {
                ["bundleId": $0.bundleId, "expiresAt": $0.expiresAt, "grantedBy": $0.grantedBy]
            },
            "events": Array(state.events.suffix(20)).map {
                ["at": $0.at, "bundleId": $0.bundleId, "action": $0.action, "detail": $0.detail]
            },
        ],
    ])
}

/// The pid of a `watch` running for this user, or nil. Found through `ps` rather
/// than a pid file, because a pid file is one more thing that can disagree with
/// reality.
/// The watcher for one store.
///
/// First the pid that store recorded, checked against the process table: a
/// recorded number whose process is gone, or has been handed to something else,
/// is not a watcher.
///
/// Then, for the default store only, the table itself. The distinction is the
/// plist: `launchd` starts the agent with no `--store`, so a watcher in the
/// process table can only ever be watching the default one — which makes the
/// table a witness for that store and a liar for every other, including the
/// scratch stores the tests run against.
private func watcherPid(store: Layout) -> Int? {
    let recorded = loadJSON(AgentState.self, from: store.state)?.watchPid
    if let pid = recorded, pid > 0, isWatcher(pid: pid) { return pid }
    if store.root.path == defaultStore().path {
        return scannedWatcherPid(excluding: Int(getpid()))
    }
    return nil
}

/// The pid of any `toolshed-lockd watch` running as this user *for the default
/// store*. A watcher that was handed `--store` is watching somebody else's list,
/// and naming it here would be the same mistake from the other direction.
private func scannedWatcherPid(excluding mine: Int) -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,uid=,args="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let uid = Int(geteuid())
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, let pid = Int(parts[0]), let owner = Int(parts[1]) else { continue }
        guard owner == uid, pid != mine else { continue }
        let arguments = parts.dropFirst(2).joined(separator: " ")
        if arguments.contains("toolshed-lockd") && arguments.contains("watch")
            && !arguments.contains("--store") { return pid }
    }
    return nil
}

/// One row of the process table, for a pid this store claims is its watcher.
private func isWatcher(pid: Int) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "uid=,args="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    // No line means no such process.
    guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
          let line = text.split(separator: "\n").first(where: { !$0.isEmpty }) else {
        return false
    }
    let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard parts.count >= 2, let owner = Int(parts[0]) else { return false }
    guard owner == Int(geteuid()) else { return false }
    let arguments = parts.dropFirst().joined(separator: " ")
    return arguments.contains("toolshed-lockd") && arguments.contains("watch")
}

func commandSetpass(_ arguments: [String]) {
    let store = storeFlag(arguments)
    guard let passphrase = readPassphraseFromStdin() else {
        fail("nothing was piped in. Pass the passphrase on stdin, never as an argument.")
    }
    let trimmed = passphrase.count
    guard trimmed >= minPassLength else {
        fail("a passphrase under \(minPassLength) characters is decoration, not a lock.")
    }
    guard trimmed <= maxPassLength else { fail("that passphrase is too long to be a passphrase.") }

    let salt = randomSalt()
    let derived = pbkdf2(password: [UInt8](passphrase.utf8), salt: salt,
                         iterations: defaultIterations, keyLength: derivedKeyLength)
    let secret = StoredSecret(kdf: "pbkdf2-hmac-sha256",
                              iterations: defaultIterations,
                              keyLength: derivedKeyLength,
                              saltHex: hexEncode(salt),
                              hashHex: hexEncode(derived),
                              setAt: Date().timeIntervalSince1970)
    // 0600: the hash is not the secret, but it is an offline guess waiting to
    // happen, and nothing outside this user's account has any business reading it.
    if let problem = saveJSON(secret, to: store.secret, fileMode: 0o600) { fail(problem) }
    succeed(["set": true, "iterations": defaultIterations, "algorithm": "pbkdf2-hmac-sha256"])
}

func commandHaspass(_ arguments: [String]) {
    let store = storeFlag(arguments)
    let secret = loadJSON(StoredSecret.self, from: store.secret)
    succeed(["set": secret != nil,
             "algorithm": secret?.kdf ?? "",
             "iterations": secret?.iterations ?? 0,
             "setAt": secret?.setAt ?? 0])
}

/// The comparison, in one place, used by `verify`, `grant` and the prompt.
private func matches(_ passphrase: String, _ secret: StoredSecret) -> Bool {
    guard let salt = hexDecode(secret.saltHex), let expected = hexDecode(secret.hashHex) else { return false }
    let derived = pbkdf2(password: [UInt8](passphrase.utf8), salt: salt,
                         iterations: secret.iterations, keyLength: secret.keyLength)
    return constantTimeEqual(derived, expected)
}

private func requireSecret(_ store: Layout) -> StoredSecret {
    guard let secret = loadJSON(StoredSecret.self, from: store.secret) else {
        fail("no passphrase is set, so there is nothing to check against. Set one first.")
    }
    return secret
}

func commandVerify(_ arguments: [String]) {
    let store = storeFlag(arguments)
    let secret = requireSecret(store)
    guard let passphrase = readPassphraseFromStdin() else {
        fail("the passphrase was expected on stdin.")
    }
    let ok = matches(passphrase, secret)
    if ok { succeed(["verified": true]) } else { succeed(["verified": false]) }
    exit(ok ? 0 : 2)
}

func commandGrant(_ arguments: [String]) {
    let store = storeFlag(arguments)
    guard let bundleId = valueFlag(arguments, "--bundle"), !bundleId.isEmpty else {
        fail("grant needs --bundle <id>")
    }
    let secret = requireSecret(store)
    guard let passphrase = readPassphraseFromStdin(), matches(passphrase, secret) else {
        var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
        state.record(AgentState.Event(at: Date().timeIntervalSince1970, bundleId: bundleId,
                                       action: "refused", detail: "wrong passphrase"))
        _ = saveJSON(state, to: store.state)
        succeed(["granted": false])
        exit(2)
    }
    let minutes = Int(valueFlag(arguments, "--minutes") ?? "") ?? loadJSON(LockConfig.self, from: store.config)?.unlockMinutes ?? 5
    untilUnlock(store: store, bundleId: minutes <= 0 ? nil : bundleId, minutes: max(minutes, 1), by: "console")
}

func commandRevoke(_ arguments: [String]) {
    let store = storeFlag(arguments)
    guard let bundleId = valueFlag(arguments, "--bundle"), !bundleId.isEmpty else {
        fail("revoke needs --bundle <id>")
    }
    var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    state.revoke(bundleId)
    state.record(AgentState.Event(at: Date().timeIntervalSince1970, bundleId: bundleId,
                                  action: "revoked", detail: "allowance dropped"))
    if let problem = saveJSON(state, to: store.state) { fail(problem) }
    succeed(["revoked": bundleId])
}

/// Writes (or removes) the allowance and says so in the state file, which is how
/// the console shows what is open without talking to the agent.
private func untilUnlock(store: Layout, bundleId: String?, minutes: Int, by: String) {
    var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    let now = Date()
    if let bundleId = bundleId {
        let until = now.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970
        state.allow(bundleId, until: until, by: by)
        state.record(AgentState.Event(at: now.timeIntervalSince1970, bundleId: bundleId,
                                       action: "unlocked", detail: "open until idle for \(minutes) min"))
        if let problem = saveJSON(state, to: store.state) { fail(problem) }
        succeed(["granted": true, "bundleId": bundleId, "expiresAt": until, "minutes": minutes])
    } else {
        if let problem = saveJSON(state, to: store.state) { fail(problem) }
        succeed(["granted": false, "minutes": minutes])
    }
}

func commandClose(_ arguments: [String]) {
    let store = storeFlag(arguments)
    guard let bundleId = valueFlag(arguments, "--bundle"), !bundleId.isEmpty else {
        fail("close needs --bundle <id>")
    }
    if let reason = guardedBundleIds[bundleId] { fail("will not close \(bundleId): \(reason)") }
    let force = arguments.contains("--force")
    let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleId }
    if applications.isEmpty {
        succeed(["closed": false, "reason": "not running"])
        return
    }
    for application in applications { quit(application, force: force) }
    var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    state.record(AgentState.Event(at: Date().timeIntervalSince1970, bundleId: bundleId,
                                  action: "closed", detail: force ? "forced" : "asked to quit"))
    _ = saveJSON(state, to: store.state)
    succeed(["closed": true, "pids": applications.map { Int($0.processIdentifier) }])
}

/// ⌘Q, and only ⌘Q unless the user asked for more.
///
/// A graceful terminate lets the app put up its own "save changes?" dialog, which
/// is the behaviour people expect from closing a document; `forceQuit: true` is
/// offered because an app that ignores the event would otherwise stay open with
/// its window on screen, which is not a lock at all.
/// Asks the app to quit, and escalates if it ignores the request.
///
/// The escalation is returned so the caller can cancel it: if the prompt that
/// follows a correct passphrase reopens the app, a force-quit that fires
/// afterwards would close the very window the user just unlocked.
@discardableResult
private func quit(_ application: NSRunningApplication, force: Bool) -> DispatchWorkItem? {
    if force {
        application.forceTerminate()
        return nil
    }
    application.terminate()
    let escalation = DispatchWorkItem {
        if !application.isTerminated { application.forceTerminate() }
    }
    // A plain main-queue delay does not run while the modal prompt owns the
    // run loop, which is why the block is also cancelled explicitly on success
    // rather than relying on the deadline alone.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: escalation)
    return escalation
}

// ----------------------------------------------------------------------- prompt

/// The passphrase dialog. `watch` uses it, and the console offers it as a test so
/// nobody has to wait for a lock event to find out whether the agent can show a
/// window at all.
///
/// A wrong phrase does not dismiss it: a fresh dialog opens with "that is not
/// the passphrase" so one typo does not cost a trip back through the app to the
/// unlock button. It still ends on "Leave it closed" or on the timeout, so the
/// box always offers a way out and an unattended Mac is not held behind it.
/// Each attempt is a new NSAlert because a dismissed one cannot be trusted to
/// run a second modal session, and each attempt arms a timer for the time left
/// on the deadline and invalidates it when answered, so a spent timer cannot
/// kill the next dialog early.
func promptForUnlock(bundleId: String, name: String, store: Layout, timeoutSeconds: Int?) -> Bool {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)

    // The dialog is about one app, so it wears that app's icon. A generic
    // warning glyph reads as a system alert about the Mac rather than as the
    // gate that app is standing behind.
    let appPath = loadJSON(LockConfig.self, from: store.config)?.entry(bundleId)?.path
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
    let minutes = loadJSON(LockConfig.self, from: store.config)?.unlockMinutes ?? 5
    let deadline = timeoutSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }

    var wrong = false
    while true {
        let alert = NSAlert()
        alert.messageText = "\(name) is locked"
        alert.informativeText = wrong
            ? "That is not the passphrase. Try again, or leave it closed."
            : "Enter the toolshed passphrase to open it. Nothing else about your setup changes."
        alert.alertStyle = .warning
        if let appPath = appPath, !appPath.isEmpty {
            alert.icon = NSWorkspace.shared.icon(forFile: appPath)
        }

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "passphrase"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Leave it closed")

        // The dismissal has to survive the modal run loop. `runModal()` runs in
        // `NSModalPanelRunLoopMode`, so a plain `DispatchQueue.main.asyncAfter`
        // block is not picked up until somebody clicks — which is the opposite
        // of a timeout. Registering for every mode the panel can be in is what
        // makes an unattended prompt actually expire.
        var timedOut = false
        var timer: Timer?
        if let deadline = deadline {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let armed = Timer(timeInterval: remaining, repeats: false) { _ in
                timedOut = true
                alert.window.orderOut(nil)
                NSApp.stopModal()
            }
            timer = armed
            for mode in [RunLoop.Mode.default, .modalPanel, .eventTracking, .common] {
                RunLoop.main.add(armed, forMode: mode)
            }
        }

        let response = alert.runModal()
        timer?.invalidate()

        if timedOut {
            logLine("\(bundleId): the passphrase prompt was left unanswered")
            return false
        }
        guard response == .alertFirstButtonReturn else { return false }

        let typed = field.stringValue
        if let secret = loadJSON(StoredSecret.self, from: store.secret), matches(typed, secret) {
            var state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
            let now = Date()
            state.allow(bundleId, until: now.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970, by: "prompt")
            state.record(AgentState.Event(at: now.timeIntervalSince1970, bundleId: bundleId,
                                          action: "unlocked", detail: "passphrase entered, locks after \(minutes) min unfocused"))
            _ = saveJSON(state, to: store.state)
            return true
        }
        logLine("\(bundleId): wrong passphrase entered at the prompt")
        wrong = true
    }
}

func commandPrompt(_ arguments: [String]) {
    let store = storeFlag(arguments)
    guard let bundleId = valueFlag(arguments, "--bundle"), !bundleId.isEmpty else {
        fail("prompt needs --bundle <id>")
    }
    let name = valueFlag(arguments, "--name") ?? loadJSON(LockConfig.self, from: store.config)?.entry(bundleId)?.name ?? bundleId
    let timeout = Int(valueFlag(arguments, "--timeout") ?? "")
    let opened = promptForUnlock(bundleId: bundleId, name: name, store: store, timeoutSeconds: timeout)
    if opened {
        let url = loadJSON(LockConfig.self, from: store.config)?.entry(bundleId)?.path
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path ?? ""
        if !url.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: url)) }
        succeed(["opened": true, "bundleId": bundleId])
    } else {
        succeed(["opened": false, "bundleId": bundleId])
    }
}

// -------------------------------------------------------------------- the agent

/// The watch loop. Everything it decides goes through `decide`, and everything it
/// does is one of: ask an app to quit, show a prompt, write the state file.
final class Warden {
    let store: Layout

    /// How long the passphrase dialog waits. Bounded on purpose: an agent that
    /// puts up a modal and waits forever turns an unattended Mac into a machine
    /// with a box nobody clicked on it, and the next launch would queue behind it.
    let promptTimeout: Int?
    private var config: LockConfig?
    private var state: AgentState
    private var configStamp: Date?
    private var stateStamp: Date?
    private var promptedAt: [String: Date] = [:]

    init(store: Layout, promptTimeout: Int?) {
        self.store = store
        self.promptTimeout = promptTimeout
        self.config = loadJSON(LockConfig.self, from: store.config)
        self.state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    }

    func start() {
        reloadConfig(force: true)
        nameSelf()

        // Launch notifications, not polling: the whole quality of this lock is
        // how fast a closed window appears, and a poll interval is a guarantee
        // of latency nobody needs.
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(self, selector: #selector(launched(_:)),
                                                 name: NSWorkspace.didLaunchApplicationNotification,
                                                 object: nil)
        workspace.notificationCenter.addObserver(self, selector: #selector(activated(_:)),
                                                 name: NSWorkspace.didActivateApplicationNotification,
                                                 object: nil)

        // A slow reconcile: unlocks expiring while nobody launches anything, and
        // apps that were already open when the lock was armed.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.reloadConfig(force: false)
            self.reloadState()
        }

        logLine("watching as uid \(geteuid()) pid \(getpid()); \(config?.locked.count ?? 0) app(s) named in the lock list")
        for entry in config?.locked ?? [] { logLine("  locked \(entry.bundleId) (\(entry.name))") }
        RunLoop.main.run()
    }

    @objc private func launched(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        enforce(application, becauseLaunch: true)
    }

    @objc private func activated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // An app that was already running when it was locked, or that ignored the
        // first quit request, gets asked again the moment it comes forward.
        enforce(application, becauseLaunch: false)
    }

    private func tick() {
        for application in NSWorkspace.shared.runningApplications { enforce(application, becauseLaunch: false) }
        let now = Date()
        let before = state.unlocks.count
        _ = state.allowance(for: "\u{0000}", now: now) // prunes what has expired
        if state.unlocks.count != before { writeState() }
    }

    private func reloadConfig(force: Bool) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: store.config.path))?[.modificationDate] as? Date
        if !force, stamp == configStamp { return }
        configStamp = stamp
        config = loadJSON(LockConfig.self, from: store.config)
        if !force { logLine("reloaded the lock list: \(config?.locked.count ?? 0) app(s)") }
    }

    /// The state file is shared with `grant` and `revoke`, which run as separate
    /// processes from the console. Re-reading it on change is what lets an
    /// allowance the console just wrote take effect without restarting the agent
    /// — and what stops this loop from overwriting it with a stale copy.
    private func reloadState() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: store.state.path))?[.modificationDate] as? Date
        if stamp == stateStamp { return }
        stateStamp = stamp
        state = loadJSON(AgentState.self, from: store.state) ?? AgentState(updatedAt: 0)
    }

    private func enforce(_ application: NSRunningApplication, becauseLaunch: Bool) {
        guard let identifier = application.bundleIdentifier else { return }
        reloadState()
        guard application.activationPolicy == .regular else { return }
        let now = Date()
        // An app in front is not idle: push its deadline forward before the
        // decision reads it, so a locked app can only be closed once it has
        // actually been left alone for the configured minutes.
        if application.isActive, let minutes = config?.unlockMinutes, minutes > 0,
           state.keepAlive(identifier, at: now, minutes: minutes) {
            writeState()
        }
        let secretSet = loadJSON(StoredSecret.self, from: store.secret) != nil
        var scratch = state
        switch decide(now: now, config: config, secretSet: secretSet, bundleId: identifier, state: &scratch) {
        case .leave, .permitted:
            return
        case .misconfigured:
            // Only say it once per app per minute; a locked list with no
            // passphrase is a configuration error, not an event stream.
            if let last = promptedAt[identifier], now.timeIntervalSince(last) < 60 { return }
            promptedAt[identifier] = now
            logLine("\(identifier) is locked but no passphrase is set, so nothing was closed")
            state.record(.init(at: now.timeIntervalSince1970, bundleId: identifier,
                               action: "misconfigured", detail: "locked with no passphrase set"))
            writeState()
        case let .close(reason):
            if !becauseLaunch, let last = promptedAt[identifier], now.timeIntervalSince(last) < 2 { return }
            promptedAt[identifier] = now
            let name = config?.entry(identifier)?.name ?? application.localizedName ?? identifier
            logLine("closing \(identifier): \(reason)")
            state.record(.init(at: now.timeIntervalSince1970, bundleId: identifier,
                               action: "closed", detail: reason))
            writeState()
            let escalation = quit(application, force: config?.forceQuit ?? false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.promptFor(identifier, name: name) {
                    escalation?.cancel()
                    self.relaunch(identifier, name: name)
                } else {
                    escalation?.cancel()
                    self.keepClosed(identifier)
                }
            }
        }
    }

    /// Asked to quit, then prompted. The prompt is what turns "your app closed"
    /// into a gate: a correct passphrase opens it again and buys the allowance.
    private func promptFor(_ bundleId: String, name: String) -> Bool {
        let opened = promptForUnlock(bundleId: bundleId, name: name, store: store,
                                     timeoutSeconds: promptTimeout)
        if !opened { logLine("\(bundleId) was not opened: no matching passphrase") }
        return opened
    }

    /// A refused prompt leaves nothing of the app running.
    ///
    /// The quit above is a request, and the modal is a pause in which a second
    /// launch can slip through — so an app that ignored it, or came back while
    /// the dialog was up, was still on screen with no allowance. From the user's
    /// side that reads as "the wrong passphrase opened it", which is the one
    /// thing a lock must never look like. So after a refusal the close is
    /// insisted on, whatever the *Insist* setting, because the app has already
    /// been asked once and this is the path where "no" has to mean no.
    private func keepClosed(_ bundleId: String) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleId
        }
        guard !running.isEmpty else {
            logLine("\(bundleId) stayed closed")
            return
        }
        for application in running { application.forceTerminate() }
        logLine("kept \(bundleId) closed: the prompt was refused and the app was still running")
        state.record(.init(at: Date().timeIntervalSince1970, bundleId: bundleId,
                           action: "closed", detail: "prompt refused; insisted on the close"))
        writeState()
    }

    private func relaunch(_ bundleId: String, name: String) {
        let path = config?.entry(bundleId)?.path ?? ""
        let url = path.isEmpty ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            : URL(fileURLWithPath: path)
        guard let url = url else {
            logLine("unlocked \(bundleId) but could not find it to open it")
            return
        }
        NSWorkspace.shared.open(url)
        logLine("opened \(name) (\(bundleId))")
        state.record(.init(at: Date().timeIntervalSince1970, bundleId: bundleId,
                           action: "opened", detail: "relaunched after the passphrase"))
        writeState()
    }

    /// Names this process in the store it is watching. A `status` call is a
    /// short-lived process and cannot tell, from the machine, which watcher
    /// belongs to which store; the file it is already reading can.
    ///
    /// The reload comes first on purpose. `writeState()` reloads the file before
    /// saving, so naming the process before that reload let the previous
    /// watcher's copy win on a restart — a live watcher that `status` reported
    /// as dead, and a console that offered to install an agent already running.
    private func nameSelf() {
        reloadState()
        state.watchPid = Int(getpid())
        state.updatedAt = Date().timeIntervalSince1970
        if let problem = saveJSON(state, to: store.state) { logLine(problem) }
    }

    private func writeState() {
        reloadState()
        state.updatedAt = Date().timeIntervalSince1970
        if let problem = saveJSON(state, to: store.state) { logLine(problem) }
    }
}

// -------------------------------------------------------------------- selfcheck

func selfcheck() -> Int32 {
    var failures = 0
    func check(_ label: String, _ condition: Bool) {
        if condition {
            print("ok   \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let notes = "com.apple.Notes"
    var locked = LockConfig()
    locked.locked = [LockConfig.LockedApp(bundleId: notes, name: "Notes",
                                         path: "/System/Applications/Notes.app",
                                         armedAt: base.timeIntervalSince1970)]

    var empty = AgentState(updatedAt: 0)
    check("an app nobody locked is left alone",
          decide(now: base, config: locked, secretSet: true, bundleId: "com.apple.TextEdit", state: &empty) == .leave)
    check("the lock list is not consulted when switched off",
          decide(now: base, config: locked.copyWith(enabled: false), secretSet: true, bundleId: notes, state: &empty) == .leave)
    check("a locked app with no allowance is closed",
          decide(now: base, config: locked, secretSet: true, bundleId: notes, state: &empty)
            == .close(reason: "locked and no allowance is live"))
    check("a locked app with no passphrase is called a mistake, not a hit",
          decide(now: base, config: locked, secretSet: false, bundleId: notes, state: &empty) == .misconfigured)

    var allowed = AgentState(updatedAt: 0)
    allowed.allow(notes, until: base.addingTimeInterval(300).timeIntervalSince1970, by: "prompt")
    check("an allowance holds the lock off",
          decide(now: base, config: locked, secretSet: true, bundleId: notes, state: &allowed)
            == .permitted(until: base.addingTimeInterval(300).timeIntervalSince1970))
    check("an expired allowance is dropped rather than honoured",
          decide(now: base.addingTimeInterval(301), config: locked, secretSet: true, bundleId: notes, state: &allowed)
            == .close(reason: "locked and no allowance is live"))
    check("expiry prunes the record so it cannot leak open", allowed.unlocks.isEmpty)

    // The window is an inactivity timer, not a stopwatch from the passphrase:
    // an app that keeps focus keeps pushing its deadline forward, and the
    // moment the pushes stop is the moment the countdown starts.
    var focused = AgentState(updatedAt: 0)
    focused.allow(notes, until: base.addingTimeInterval(300).timeIntervalSince1970, by: "prompt")
    check("focusing the app moves its deadline forward",
          focused.keepAlive(notes, at: base.addingTimeInterval(290), minutes: 5))
    check("a focused app stays open past the original deadline",
          decide(now: base.addingTimeInterval(400), config: locked, secretSet: true,
                 bundleId: notes, state: &focused)
            == .permitted(until: base.addingTimeInterval(590).timeIntervalSince1970))
    check("an app left alone is closed when the idle window ends",
          decide(now: base.addingTimeInterval(591), config: locked, secretSet: true,
                 bundleId: notes, state: &focused)
            == .close(reason: "locked and no allowance is live"))

    var neverFocused = AgentState(updatedAt: 0)
    neverFocused.allow(notes, until: base.addingTimeInterval(300).timeIntervalSince1970, by: "prompt")
    check("a window that is never refreshed expires on its own",
          decide(now: base.addingTimeInterval(301), config: locked, secretSet: true,
                 bundleId: notes, state: &neverFocused)
            == .close(reason: "locked and no allowance is live"))

    var longWindow = AgentState(updatedAt: 0)
    longWindow.allow(notes, until: base.addingTimeInterval(900).timeIntervalSince1970, by: "console")
    check("focus never shortens a longer window",
          !longWindow.keepAlive(notes, at: base, minutes: 5))

    check("the session itself is never a target",
          decide(now: base, config: locked.copyWith(bundleId: "com.apple.finder"), secretSet: true,
                 bundleId: "com.apple.finder", state: &empty)
            == .close(reason: "guarded, and closing it would take the session with it"))

    // The KDF: deterministic for one salt, different for another, and never
    // matching a wrong guess. The parameters travel with the hash, so a later
    // iteration count does not invalidate an existing passphrase.
    let salt = [UInt8]("0123456789abcdef".utf8)
    let right = pbkdf2(password: [UInt8]("correct horse".utf8), salt: salt, iterations: 4_096, keyLength: 32)
    let again = pbkdf2(password: [UInt8]("correct horse".utf8), salt: salt, iterations: 4_096, keyLength: 32)
    let wrong = pbkdf2(password: [UInt8]("correct horsf".utf8), salt: salt, iterations: 4_096, keyLength: 32)
    let otherSalt = pbkdf2(password: [UInt8]("correct horse".utf8), salt: [UInt8]("fedcba9876543210".utf8),
                           iterations: 4_096, keyLength: 32)
    check("the same passphrase derives the same bytes", constantTimeEqual(right, again))
    check("one character off does not match", !constantTimeEqual(right, wrong))
    check("one salt off does not match", !constantTimeEqual(right, otherSalt))
    check("the hex round trip is lossless", hexDecode(hexEncode(right)) == right)
    check("a length mismatch fails without reading past the end", !constantTimeEqual(right, Array(right.dropLast())))

    // A lock list is only as good as the file that can carry it back.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let roundTrip = try? JSONDecoder().decode(LockConfig.self, from: encoder.encode(locked))
    check("the config survives JSON", roundTrip?.locked.first?.bundleId == notes)
    let stateRoundTrip = try? JSONDecoder().decode(AgentState.self,
                                                   from: encoder.encode(allowedEvents()))
    check("the state survives JSON", stateRoundTrip?.events.first?.action == "closed")

    if failures > 0 {
        print("\(failures) check(s) failed")
        return 1
    }
    print("all checks passed")
    return 0
}

private func allowedEvents() -> AgentState {
    var value = AgentState(updatedAt: 0)
    value.record(.init(at: 1, bundleId: "com.apple.Notes", action: "closed", detail: "for the check"))
    return value
}

private extension LockConfig {
    func copyWith(enabled: Bool) -> LockConfig {
        var copy = self
        copy.enabled = enabled
        return copy
    }

    /// A list containing one arbitrary bundle id, for the decision checks.
    func copyWith(bundleId: String) -> LockConfig {
        var copy = self
        copy.locked = [LockedApp(bundleId: bundleId, name: bundleId, path: "", armedAt: 0)]
        return copy
    }
}

// -------------------------------------------------------------------------- cli

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""
let rest = Array(arguments.dropFirst(2))
let store = storeFlag(rest)

switch command {
case "watch":
    if geteuid() == 0 {
        // Root is not needed and would be worse: a watcher running as root could
        // close apps in every account on the machine, and its state file would
        // land in /var/root where the console cannot read it.
        fail("run this as the signed-in user, not root. A per-user agent needs no privilege.")
    }
    let timeout = Int(valueFlag(rest, "--prompt-timeout") ?? "") ?? 60
    Warden(store: store, promptTimeout: timeout > 0 ? timeout : nil).start()
case "list":
    commandList(rest)
case "status":
    commandStatus(rest)
case "setpass":
    commandSetpass(rest)
case "haspass":
    commandHaspass(rest)
case "verify":
    commandVerify(rest)
case "grant":
    commandGrant(rest)
case "revoke":
    commandRevoke(rest)
case "close":
    commandClose(rest)
case "prompt":
    commandPrompt(rest)
case "selfcheck":
    exit(selfcheck())
default:
    fail("""
    usage: toolshed-lockd <watch|list|status|setpass|haspass|verify|grant|revoke|close|prompt|selfcheck> \
    [--store <dir>] [--bundle <id>] [--minutes <n>] [--name <text>] [--timeout <s>] \
    [--prompt-timeout <s>] [--force]
    """)
}
