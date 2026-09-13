import AppKit
import ScreenSaver

@MainActor @objc private protocol KeyboardReading {
    func copyKeyboardBacklightIDs() -> [NSNumber]
    func brightnessForKeyboard(_ id: UInt64) -> Float
    func isAutoBrightnessEnabledForKeyboard(_ id: UInt64) -> Bool
    func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool, forKeyboard id: UInt64) -> Bool
}

@main
@MainActor
struct Checks {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--hardware" { try checkHardware(); return }
        let now = Date()
        assert(UsageSnapshot(value: "66%", updatedAt: now).displayValue(now: now) == "66%")
        for value in ["--", "101%", "-1%", "nan%", "66", "<script>"] {
            assert(UsageSnapshot(value: value, updatedAt: now).displayValue(now: now) == "--")
        }
        assert(UsageSnapshot(value: "66%", updatedAt: now.addingTimeInterval(-151)).displayValue(now: now) == "--")
        assert(UsageSnapshot(value: "66%", updatedAt: now.addingTimeInterval(1)).displayValue(now: now) == "--")
        for value in ["0%", "100%"] {
            let snapshot = UsageSnapshot(value: value, updatedAt: now)
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
            assert(decoded.displayValue(now: now) == value)
        }
        let app = NSApplication.shared
        let bundle = Bundle(path: CommandLine.arguments[1])!
        guard let viewClass = bundle.principalClass as? ScreenSaverView.Type,
              let view = viewClass.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), isPreview: true)
        else { fatalError("Screen saver bundle failed to load") }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.startAnimation()
        view.animateOneFrame()
        assert(view.animationTimeInterval == 1)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        assert(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3 && !bitmap.isPlanar)
        let pixels = bitmap.bitmapData!
        var brightest = UInt8(0)
        var rowBounds: [(min: Int, max: Int)] = []
        for y in 0..<bitmap.pixelsHigh {
            var rowMin = bitmap.pixelsWide, rowMax = -1
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
                let light = max(pixels[offset], pixels[offset + 1], pixels[offset + 2])
                brightest = max(brightest, light)
                if light > 2 {
                    rowMin = min(rowMin, x); rowMax = max(rowMax, x)
                }
            }
            rowBounds.append((rowMin, rowMax))
        }
        var bands: [ClosedRange<Int>] = []
        for y in rowBounds.indices where rowBounds[y].max >= 0 {
            if let previous = bands.last, previous.upperBound == y - 1 {
                bands[bands.count - 1] = previous.lowerBound...y
            } else { bands.append(y...y) }
        }
        assert(brightest == 255, "White text must not be pre-dimmed")
        assert(bands.count == 2, "Clock and percentage must be two separate lines")
        let hour = bands[0], percent = bands[1] // Bitmap rows run from top to bottom.
        if UsageSnapshot.read() != "--" {
            assert(hour.count < percent.count / 2, "Clock must be substantially smaller")
        }
        assert(percent.lowerBound - hour.upperBound > hour.count / 2, "Keep a visible vertical gap")
        for band in bands {
            let left = band.map { rowBounds[$0].min }.min()!
            let right = band.map { rowBounds[$0].max }.max()!
            assert(abs(Double(left + right + 1) / 2 - Double(bitmap.pixelsWide) / 2) <= 2, "Center each line independently")
        }
        assert(abs(Double(hour.lowerBound + percent.upperBound + 1) / 2 - Double(bitmap.pixelsHigh) / 2) <= 2, "Center the group vertically")
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if CommandLine.arguments.contains("--minute") {
            let before = view.accessibilityValue() as? String
            RunLoop.main.run(until: nextMinute().addingTimeInterval(0.15))
            let after = view.accessibilityValue() as? String
            assert(after != before, "Clock must redraw at the new minute, without a manual animateOneFrame call")
            print("OK: clock changed at the minute boundary")
        }
        view.stopAnimation()
        withExtendedLifetime((app, window)) {}
        print("OK: cache, rendering, white clock above percentage, centering and gap")
    }

    private static func checkHardware() throws {
        _ = NSApplication.shared
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("codex-limit-hardware-check.json")
        let quiet = try QuietDisplay(journal: journal)
        guard quiet.recover() else { throw CocoaError(.fileReadCorruptFile) }
        let client = (NSClassFromString("KeyboardBrightnessClient") as! NSObject.Type).init()
        let keyboard = unsafeBitCast(client, to: (any KeyboardReading).self)
        let ids = keyboard.copyKeyboardBacklightIDs().map(\.uint64Value)
        var before: [Float] = [], automatic: [Bool] = []
        for id in ids {
            before.append(keyboard.brightnessForKeyboard(id))
            automatic.append(keyboard.isAutoBrightnessEnabledForKeyboard(id))
        }
        quiet.rememberBrightness()
        // Reproduce entering after idle dimming: only the previously captured levels may be restored.
        defer {
            quiet.restore()
            for (id, value) in zip(ids, before) { _ = keyboard.setBrightness(value, fadeSpeed: 0, commit: true, forKeyboard: id) }
        }
        for id in ids { _ = keyboard.setBrightness(0, fadeSpeed: 0, commit: false, forKeyboard: id) }
        quiet.begin()
        let original = try Data(contentsOf: journal)
        quiet.begin()
        let unchanged = try Data(contentsOf: journal) == original
        assert(unchanged, "Never save dimmed values over originals")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        var off = true
        for id in ids { off = keyboard.brightnessForKeyboard(id) == 0 && off }
        let state = try JSONDecoder().decode(QuietDisplay.State.self, from: original)
        quiet.restore()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var after: [Float] = [], afterAutomatic: [Bool] = []
        for id in ids {
            after.append(keyboard.brightnessForKeyboard(id))
            afterAutomatic.append(keyboard.isAutoBrightnessEnabledForKeyboard(id))
        }
        assert(off && zip(before, after).allSatisfy { abs($0 - $1) < 0.002 }, "Restore the actual previous keyboard level, including intentional zero")
        assert(afterAutomatic == automatic)
        assert(!FileManager.default.fileExists(atPath: journal.path))
        quiet.restore()
        print("OK: keyboard \(before) → off → \(after); settings preserved; saved displays: \(state.displays.count)")
    }
}
