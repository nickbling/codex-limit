import Foundation
import Darwin

func nextMinute(after date: Date = .now) -> Date {
    Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
}

// Only the percentage crosses into the screen saver; never account credentials.
struct UsageSnapshot: Codable {
    let value: String
    let updatedAt: Date

    static var url: URL {
        // NSHomeDirectory() points at the host's sandbox inside a .saver.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Caches/local.codex-limit/remaining.json")
    }

    func displayValue(now: Date = .now) -> String {
        guard (0...150).contains(now.timeIntervalSince(updatedAt)),
              value.hasSuffix("%"), let percent = Int(value.dropLast()),
              (0...100).contains(percent) else { return "--" }
        return "\(percent)%"
    }

    static func read() -> String {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data) else { return "--" }
        return snapshot.displayValue()
    }

    static func write(_ value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Self(value: value, updatedAt: .now)).write(to: url, options: .atomic)
    }
}
