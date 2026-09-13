import AppKit
import Darwin
import IOKit.pwr_mgt

@MainActor @objc private protocol KeyboardControl {
    func copyKeyboardBacklightIDs() -> [NSNumber]
    func brightnessForKeyboard(_ id: UInt64) -> Float
    func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool, forKeyboard id: UInt64) -> Bool
}

@MainActor
final class QuietDisplay {
    struct State: Codable {
        var displays: [String: Float] = [:]
        var keyboards: [UInt64: Float] = [:]
        var empty: Bool { displays.isEmpty && keyboards.isEmpty }
        var valid: Bool { (Array(displays.values) + Array(keyboards.values)).allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }

    private let getBrightness: @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private let setBrightness: @convention(c) (UInt32, Float) -> Int32
    private let cursorVisible: @convention(c) () -> Bool
    private let connection: Int32
    private let setProperty: @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private let keyboard: any KeyboardControl
    private let handles: [UnsafeMutableRawPointer]
    private let journal: URL
    private var saved = State()
    private var awake = State()
    private var cursorDisplay: UInt32?
    private var displayAssertion: IOPMAssertionID = 0
    private(set) var active = false

    static let brightness: Float = 0.001

    init(journal: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Codex Limit/quiet-display.json")) throws {
        self.journal = journal
        var opened: [UnsafeMutableRawPointer] = []
        func load<T>(_ framework: String, _ symbol: String, as: T.Type) throws -> T {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/\(framework).framework/\(framework)", RTLD_NOW | RTLD_LOCAL) else { throw CocoaError(.featureUnsupported) }
            opened.append(handle)
            guard let pointer = dlsym(handle, symbol) else { throw CocoaError(.featureUnsupported) }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else { throw CocoaError(.featureUnsupported) }
            getBrightness = try load("DisplayServices", "DisplayServicesGetBrightness", as: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
            setBrightness = try load("DisplayServices", "DisplayServicesSetBrightness", as: (@convention(c) (UInt32, Float) -> Int32).self)
            cursorVisible = try load("SkyLight", "CGCursorIsVisible", as: (@convention(c) () -> Bool).self)
            connection = try load("SkyLight", "SLSMainConnectionID", as: (@convention(c) () -> Int32).self)()
            setProperty = try load("SkyLight", "SLSSetConnectionProperty", as: (@convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32).self)
            _ = try load("CoreBrightness", "OBJC_CLASS_$_KeyboardBrightnessClient", as: UnsafeRawPointer.self)
            guard let client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init(),
                  ["copyKeyboardBacklightIDs", "brightnessForKeyboard:", "setBrightness:fadeSpeed:commit:forKeyboard:"].allSatisfy({ client.responds(to: NSSelectorFromString($0)) })
            else { throw CocoaError(.featureUnsupported) }
            keyboard = unsafeBitCast(client, to: (any KeyboardControl).self)
        } catch { opened.forEach { dlclose($0) }; throw error }
        handles = opened
    }

    isolated deinit { restore(); handles.forEach { dlclose($0) } }

    private var displays: [String: UInt32] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, uuid) as String, id)
        })
    }

    private func readBrightness(_ id: UInt32) -> Float? {
        var value: Float = -1
        guard getBrightness(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    // Capture before lock/idle dimming, not the already-dark state at screensaver entry.
    func rememberBrightness() {
        guard !active else { return }
        for (uuid, id) in displays {
            if let value = readBrightness(id) { awake.displays[uuid] = value }
        }
        for id in keyboard.copyKeyboardBacklightIDs().map(\.uint64Value) {
            let value = keyboard.brightnessForKeyboard(id)
            if value.isFinite, (0...1).contains(value) { awake.keyboards[id] = value }
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: journal, options: .atomic)
    }

    @discardableResult
    func begin() -> Bool {
        if active { return true }
        guard recover() else { return false }
        for (uuid, id) in displays {
            if let value = readBrightness(id) { saved.displays[uuid] = awake.displays[uuid] ?? value }
        }
        let connected = Set(keyboard.copyKeyboardBacklightIDs().map(\.uint64Value))
        saved.keyboards = awake.keyboards.filter { connected.contains($0.key) }
        guard !saved.empty else { return false }
        do { try persist() } catch { saved = State(); NSLog("Codex Limit: cannot save brightness: %@", error.localizedDescription); return false }
        active = true
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Codex Limit" as CFString, &displayAssertion) == kIOReturnSuccess
        else { restore(); return false }
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        let display = CGMainDisplayID()
        if CGDisplayHideCursor(display) == .success { cursorDisplay = display }
        for id in saved.keyboards.keys { _ = keyboard.setBrightness(0, fadeSpeed: 0, commit: false, forKeyboard: id) }
        maintain()
        return true
    }

    func maintain() {
        guard active else { return }
        // loginwindow may reveal the cursor on display wake; keep the hide count balanced.
        if let display = cursorDisplay, cursorVisible() { CGDisplayShowCursor(display); CGDisplayHideCursor(display) }
        for (uuid, id) in displays {
            guard let original = saved.displays[uuid] else { continue }
            let target = min(original, Self.brightness)
            if let current = readBrightness(id), abs(current - target) > 0.0001 { _ = setBrightness(id, target) }
        }
        for id in saved.keyboards.keys where keyboard.brightnessForKeyboard(id) != 0 {
            _ = keyboard.setBrightness(0, fadeSpeed: 0, commit: false, forKeyboard: id)
        }
    }

    @discardableResult
    func recover() -> Bool {
        guard !active else { return false }
        do {
            if saved.empty, FileManager.default.fileExists(atPath: journal.path) {
                saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: journal))
                guard saved.valid else { saved = State(); throw CocoaError(.fileReadCorruptFile) }
                awake = saved
            }
            restore()
            return saved.empty && !FileManager.default.fileExists(atPath: journal.path)
        } catch { NSLog("Codex Limit: recovery failed: %@", error.localizedDescription); return false }
    }

    func restore() {
        active = false
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if let display = cursorDisplay {
            CGDisplayShowCursor(display)
            _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanFalse)
            cursorDisplay = nil
        }
        guard !saved.empty else { return }
        let connected = displays
        saved.displays = saved.displays.filter { uuid, value in
            guard let id = connected[uuid] else { return true }
            return setBrightness(id, value) != 0
        }
        saved.keyboards = saved.keyboards.filter { id, value in
            // Committing the ORIGINAL level also releases the temporary suspension and mute.
            !keyboard.setBrightness(value, fadeSpeed: 0, commit: true, forKeyboard: id)
        }
        do {
            if saved.empty { try FileManager.default.removeItem(at: journal) }
            else { try persist() }
        } catch { NSLog("Codex Limit: restoration pending: %@", error.localizedDescription) }
    }
}
