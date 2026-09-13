import AppKit
import Darwin
import IOKit.pwr_mgt

// Pure transition rule: no key contents, event taps, or authentication access.
func dismissLockOverlay(locked: Bool, lidClosed: Bool, idle: Double?, previousIdle: Double) -> Bool {
    guard locked, !lidClosed, let idle, idle.isFinite, idle >= 0 else { return true }
    return idle < 1 || idle + 0.1 < previousIdle
}

@MainActor
private final class LockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LockScreenOverlay: NSObject {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias DestroySpace = @convention(c) (Int32, UInt64) -> Void

    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let createSpace: CreateSpace
    private let setSpaceLevel: SpaceLevel
    private let showSpaces: Spaces
    private let hideSpaces: Spaces
    private let addWindows: AddWindows
    private let destroySpace: DestroySpace
    private let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    private let power = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private var space: UInt64 = 0
    private var windows: [NSPanel] = []
    private var timer: Timer?
    private var wakeAssertion: IOPMAssertionID = 0
    private var previousIdle = 0.0
    private var waitingForWake = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private var lastWake = -Double.infinity
    private var failed = false
    private var systemSleeping = false
    private let quiet: QuietDisplay
    private var nativeSaverActive = false
    private var lastMaintenance = -Double.infinity

    init(startMonitoring: Bool = true) throws {
        // ponytail: private SkyLight calls verified on macOS 26 only; revalidate on a major OS upgrade.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL)
        else { throw NSError(domain: "CodexLockOverlay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Automatic lock display is not supported on this macOS version"]) }
        func load<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw NSError(domain: "CodexLockOverlay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unavailable system function: \(name)"])
            }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            connection = try load("SLSMainConnectionID", as: Connection.self)()
            createSpace = try load("SLSSpaceCreate", as: CreateSpace.self)
            setSpaceLevel = try load("SLSSpaceSetAbsoluteLevel", as: SpaceLevel.self)
            showSpaces = try load("SLSShowSpaces", as: Spaces.self)
            hideSpaces = try load("SLSHideSpaces", as: Spaces.self)
            addWindows = try load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self)
            destroySpace = try load("SLSSpaceDestroy", as: DestroySpace.self)
            quiet = try QuietDisplay()
        } catch { dlclose(handle); throw error }
        self.handle = handle
        super.init()
        guard startMonitoring else { return }
        quiet.recover()
        if !locked { quiet.rememberBrightness() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(nativeSaverStarted),
            name: Notification.Name("com.apple.screensaver.didstart"), object: nil, suspensionBehavior: .deliverImmediately)
        for name in ["com.apple.screensaver.willstop", "com.apple.screensaver.didstop"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(nativeSaverStopped),
                name: Notification.Name(name), object: nil, suspensionBehavior: .deliverImmediately)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    isolated deinit {
        stop()
        if hid != 0 { IOObjectRelease(hid) }
        if power != 0 { IOObjectRelease(power) }
        dlclose(handle)
    }

    private var locked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
            && session?["kCGSSessionOnConsoleKey"] as? Bool == true
    }

    private var idle: Double? {
        guard hid != 0,
              let value = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    private var lidClosed: Bool {
        guard power != 0,
              let value = IORegistryEntryCreateCFProperty(power, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        else { return true } // Missing hardware state: never wake a possibly closed Mac.
        return value.boolValue
    }

    @objc private func tick() {
        guard !systemSleeping else { return }
        if nativeSaverActive {
            if let idle, !lidClosed, idle + 0.1 >= previousIdle {
                previousIdle = idle
                maintainQuietDisplay()
            } else { nativeSaverStopped() }
            return
        }
        guard !failed else { return }
        guard locked else {
            dismiss()
            waitingForWake = false
            if let idle, idle < 1 { quiet.rememberBrightness() }
            return
        }
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        if !asleep { waitingForWake = false }
        let currentIdle = idle
        if !windows.isEmpty && dismissLockOverlay(locked: true, lidClosed: lidClosed, idle: currentIdle, previousIdle: previousIdle) {
            dismiss()
        }
        previousIdle = currentIdle ?? 0
        if !windows.isEmpty { maintainQuietDisplay() }
        guard asleep, !waitingForWake, !lidClosed, let currentIdle, currentIdle >= 1 else { return }
        // A display-off edge triggers the change; locking alone never changes the wallpaper.
        do {
            if windows.isEmpty { try present() }
            guard !windows.isEmpty, locked else { dismiss(); return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastWake >= 5 else { return }
            lastWake = now
            let result = IOPMAssertionDeclareUserActivity("Codex Limit display" as CFString, kIOPMUserActiveLocal, &wakeAssertion)
            guard result == kIOReturnSuccess else { throw NSError(domain: "CodexLockOverlay", code: Int(result)) }
            IOPMAssertionSetProperty(wakeAssertion, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: 1))
        } catch {
            dismiss()
            failed = true
            NSLog("Codex Limit: automatic lock display stopped safely: %@", error.localizedDescription)
        }
    }

    private func present() throws {
        guard locked, !NSScreen.screens.isEmpty else { return }
        space = createSpace(connection, 1, nil)
        guard space != 0 else { throw NSError(domain: "CodexLockOverlay", code: 3) }
        setSpaceLevel(connection, space, 400)
        for screen in NSScreen.screens {
            let panel = LockPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .black
            guard let view = CodexSaverView(frame: NSRect(origin: .zero, size: screen.frame.size), isPreview: true) else { continue }
            panel.contentView = view
            view.startAnimation()
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        guard !windows.isEmpty else { throw NSError(domain: "CodexLockOverlay", code: 4) }
        addWindows(connection, space, windows.map { NSNumber(value: $0.windowNumber) } as CFArray, 7)
        showSpaces(connection, [NSNumber(value: space)] as CFArray)
        guard quiet.begin() else { throw NSError(domain: "CodexLockOverlay", code: 5) }
        NSLog("Codex Limit: percentage shown after display-off; session remains locked")
    }

    private func dismiss() {
        for window in windows {
            (window.contentView as? CodexSaverView)?.stopAnimation()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        if space != 0 {
            hideSpaces(connection, [NSNumber(value: space)] as CFArray)
            destroySpace(connection, space)
            space = 0
            NSLog("Codex Limit: percentage hidden; system lock screen unchanged")
        }
        if wakeAssertion != 0 { IOPMAssertionRelease(wakeAssertion); wakeAssertion = 0 }
        if !nativeSaverActive, quiet.active { quiet.restore() }
    }

    private func maintainQuietDisplay() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMaintenance >= 1 else { return }
        lastMaintenance = now
        quiet.maintain()
    }

    @objc private func screenUnlocked() {
        nativeSaverActive = false
        dismiss()
        waitingForWake = false
    }

    @objc private func nativeSaverStarted() {
        guard !systemSleeping, !lidClosed else { return }
        previousIdle = idle ?? 0
        nativeSaverActive = quiet.begin()
    }
    @objc private func nativeSaverStopped() {
        nativeSaverActive = false
        if windows.isEmpty { quiet.restore() }
    }
    @objc private func systemWillSleep() {
        systemSleeping = true; waitingForWake = true; nativeSaverActive = false; dismiss()
    }
    @objc private func systemDidWake() {
        systemSleeping = false; waitingForWake = true; quiet.recover()
    }
    @objc private func screensChanged() { dismiss(); if !quiet.active { quiet.recover() } }

    func stop() {
        nativeSaverActive = false
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        dismiss()
    }
}
