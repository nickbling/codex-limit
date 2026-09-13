import AppKit
import Darwin

// Codex handles account credentials; this app only reads its usage response.
func remainingPercent(_ result: [String: Any]) -> String {
    let buckets = result["rateLimitsByLimitId"] as? [String: Any]
    let limit = (buckets?["codex"] ?? result["rateLimits"]) as? [String: Any] ?? [:]
    guard limit["limitId"] == nil || limit["limitId"] as? String == "codex" else { return "--" }
    for key in ["primary", "secondary"] {
        guard let window = limit[key] as? [String: Any],
              window["windowDurationMins"] as? Int == 10080,
              let number = window["usedPercent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
        let used = number.doubleValue
        guard used.isFinite else { continue }
        return "\(Int(max(0, min(100, 100 - used)).rounded()))%"
    }
    return "--"
}

func readUsage() -> String {
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["codex", "app-server", "--stdio"]
    // Finder and launchd do not inherit the user's shell PATH.
    if let path = Bundle.main.object(forInfoDictionaryKey: "CodexPath") as? String {
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, installed in installed }
    }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "--" }
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    do {
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex-limit-bar", "version": "2"], "capabilities": [:]
        ]])
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; return "--" }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { return "--" }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count < 1_048_576 else { return "--" }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                pending.removeSubrange(...newline)
                guard let id = message["id"] as? Int else { continue }
                guard message["error"] == nil else { return "--" }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2 {
                    return remainingPercent(message["result"] as? [String: Any] ?? [:])
                }
            }
        }
    } catch { return "--" }
    return "--"
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        if CommandLine.arguments.contains("--test") {
            func fixture(_ used: Any, key: String = "primary", duration: Int = 10080) -> [String: Any] {
                ["rateLimits": ["limitId": "codex", key: ["usedPercent": used, "windowDurationMins": duration]]]
            }
            assert(remainingPercent(fixture(34)) == "66%")
            assert(remainingPercent(fixture(100, key: "secondary")) == "0%")
            assert(remainingPercent(fixture(0)) == "100%")
            assert(remainingPercent(fixture(110)) == "0%")
            assert(remainingPercent(fixture(NSNull())) == "--")
            assert(remainingPercent(fixture(34, duration: 300)) == "--")
            assert(remainingPercent([:]) == "--")
            var multiple = fixture(99)
            multiple["rateLimitsByLimitId"] = ["codex": fixture(34)["rateLimits"]!]
            assert(remainingPercent(multiple) == "66%")
            assert(!dismissLockOverlay(locked: true, lidClosed: false, idle: 30, previousIdle: 29))
            assert(dismissLockOverlay(locked: false, lidClosed: false, idle: 30, previousIdle: 29))
            assert(dismissLockOverlay(locked: true, lidClosed: true, idle: 30, previousIdle: 29))
            assert(dismissLockOverlay(locked: true, lidClosed: false, idle: 0.2, previousIdle: 30))
            assert(dismissLockOverlay(locked: true, lidClosed: false, idle: 2, previousIdle: 30))
            assert(dismissLockOverlay(locked: true, lidClosed: false, idle: nil, previousIdle: 30))
            assert(dismissLockOverlay(locked: true, lidClosed: false, idle: .nan, previousIdle: 30))
            assert(nextMinute(after: Date(timeIntervalSince1970: 120)).timeIntervalSince1970 == 180)
            assert(nextMinute(after: Date(timeIntervalSince1970: 179.999)).timeIntervalSince1970 == 180)
            assert(nextMinute(after: Date(timeIntervalSince1970: 86399)).timeIntervalSince1970 == 86400)
            assert(QuietDisplay.State(displays: ["test": 0.5]).valid)
            assert(!QuietDisplay.State(displays: ["test": .nan]).valid)
            assert(!QuietDisplay.State(keyboards: [1: 2]).valid)
            _ = NSApplication.shared
            do { let overlay = try LockScreenOverlay(startMonitoring: false); overlay.stop() }
            catch { fatalError("Lock display system functions unavailable: \(error)") }
            print("OK: weekly remaining percentage, safe lock-display dismissal and system function availability")
            return
        }
        if CommandLine.arguments.contains("--check") { print(readUsage()); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var refreshing = false
    private var lockOverlay: LockScreenOverlay?

    func applicationWillTerminate(_ notification: Notification) { lockOverlay?.stop() }

    @objc private func startScreenSaver() {
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not start the screen saver"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item.button?.title = "--"
        item.button?.toolTip = "Weekly Codex limit remaining"
        let menu = NSMenu()
        let startItem = NSMenuItem(title: "Start screen saver", action: #selector(startScreenSaver), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Exit Codex Limit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        do { lockOverlay = try LockScreenOverlay() }
        catch { NSLog("Codex Limit: automatic lock display unavailable: %@", error.localizedDescription) }
        scheduleRefresh()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(scheduleRefresh),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleRefresh),
            name: .NSSystemClockDidChange, object: nil)
    }

    @objc private func scheduleRefresh() {
        timer?.invalidate()
        refresh()
        let timer = Timer(fireAt: nextMinute(), interval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let value = await Task.detached(priority: .utility) { readUsage() }.value
            item.button?.title = value
            do { try UsageSnapshot.write(value) }
            catch { NSLog("Codex Limit: cannot update screen saver: %@", error.localizedDescription) }
            refreshing = false
        }
    }
}
