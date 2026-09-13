import AppKit
import ScreenSaver
import CoreText

@MainActor
@objc(CodexSaverView)
final class CodexSaverView: ScreenSaverView {
    private var minuteTimer: Timer?
    private var displayedValue = ""
    private var displayedTime = ""
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override func startAnimation() {
        super.startAnimation()
        scheduleClock()
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleClock),
            name: .NSSystemClockDidChange, object: nil)
    }

    override func stopAnimation() {
        super.stopAnimation()
        minuteTimer?.invalidate()
        minuteTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Time and weekly Codex limit remaining")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1
    }

    @objc private func scheduleClock() {
        minuteTimer?.invalidate()
        let timer = Timer(fireAt: nextMinute(), interval: 60, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
        updateDisplay()
    }

    @objc private func updateDisplay() {
        let value = UsageSnapshot.read(), time = clock.string(from: .now)
        guard value != displayedValue || time != displayedTime else { return }
        displayedValue = value
        displayedTime = time
        needsDisplay = true
    }

    // The minute timer changes the clock; this also picks up the asynchronous Codex response.
    override func animateOneFrame() { updateDisplay() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let value = UsageSnapshot.read(), time = clock.string(from: .now)
        let size = min(bounds.width * 0.22, bounds.height * 0.32)
        let color = NSColor.white
        func line(_ text: String, font: NSFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        let percent = line(value, font: .systemFont(ofSize: size, weight: .bold))
        let hour = line(time, font: .monospacedDigitSystemFont(ofSize: size * 0.28, weight: .medium))
        let percentInk = CTLineGetBoundsWithOptions(percent, .useGlyphPathBounds)
        let hourInk = CTLineGetBoundsWithOptions(hour, .useGlyphPathBounds)
        let gap = size * 0.22
        let bottom = bounds.midY - (percentInk.height + gap + hourInk.height) / 2
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - percentInk.midX, y: bottom - percentInk.minY)
        CTLineDraw(percent, context)
        context.textPosition = CGPoint(x: bounds.midX - hourInk.midX, y: bottom + percentInk.height + gap - hourInk.minY)
        CTLineDraw(hour, context)
        context.restoreGState()
        setAccessibilityValue("\(time), \(value == "--" ? "Usage unavailable" : value)")
    }
}
