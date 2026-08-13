import Foundation

/// Formats the portal's "/Date(1786512600000+0200)/" timestamps.
enum PunchFormat {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm"
        return f
    }()

    static func wallTime(_ raw: String) -> String {
        guard let (ms, offsetSeconds) = wallClockDate(raw) else { return "?" }
        // The portal encodes the server-local wall-clock as if UTC, with the
        // offset embedded: adding the offset to the raw values gives the true
        // wall-clock time regardless of the machine's timezone.
        let local = Date(timeIntervalSince1970: ms / 1000.0 + offsetSeconds)
        return timeFormatter.string(from: local)
    }

    /// Parses "/Date(1786512600000+0200)/" into the raw milliseconds and the
    /// embedded offset in seconds.
    static func wallClockDate(_ raw: String) -> (ms: Double, offsetSeconds: Double)? {
        let trimmed = raw.replacingOccurrences(of: #".*/Date\("#, with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.prefix { $0.isNumber }
        guard let ms = Double(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        var offsetSeconds: Double = 0
        if rest.hasPrefix("+") || rest.hasPrefix("-") {
            let sign: Double = rest.first == "+" ? 1 : -1
            let digits2 = rest.dropFirst()
            let hours = Double(digits2.prefix(2)) ?? 0
            let minutes = Double(digits2.dropFirst(2).prefix(2)) ?? 0
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        }
        return (ms, offsetSeconds)
    }

    /// Raw epoch milliseconds for sorting (offset-independent).
    static func ms(_ raw: String) -> Double {
        (VTAPIClient.parseMSDate(raw)?.timeIntervalSince1970 ?? 0) * 1000.0
    }
}