import Foundation

/// A reading for the account dashboard. The relay never consumes this file.
enum ClaudeUsageDisplay {
    enum Source: String, Codable {
        case copiedFromClaude = "Copied from Claude"
        case claudeUsagePage = "Claude usage page"
        case graftUsage = "Graft usage report"
        case relay = "Graft relay"

        fileprivate var isPageReading: Bool { self == .copiedFromClaude || self == .claudeUsagePage }
    }

    struct Values: Equatable {
        var weekly: Int?
        var fable: Int?
        var isEmpty: Bool { weekly == nil && fable == nil }
    }

    struct Metric: Codable, Equatable {
        let percent: Int
        let observedAt: Date
        let source: Source

        fileprivate func isCurrent(at now: Date) -> Bool {
            let age = now.timeIntervalSince(observedAt)
            return (0...100).contains(percent) && age >= 0 && age < 5 * 60 * 60
        }
    }

    struct Reading: Codable, Equatable {
        var weekly: Metric?
        var fable: Metric?
    }

    private enum Window { case weekly, fable }
    private enum DisplayError: Error { case invalidReading }

    static func parse(_ text: String) -> Values {
        var window: Window?
        var weekly: Set<Int> = [], fable: Set<Int> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch line {
            case "this week": window = .weekly
            case "fable": window = .fable
            case "": continue
            default:
                guard let section = window else { continue }
                if line.hasPrefix("resets ") || line == "starts with your first message" { continue }
                if section == .fable, line.range(of: #"^up to [0-9]{1,3}% of your weekly limit$"#,
                                                   options: .regularExpression) != nil { continue }
                if let percent = percentUsed(line) {
                    switch section {
                    case .weekly: weekly.insert(percent)
                    case .fable: fable.insert(percent)
                    }
                }
                // New sections (including usage credits) can have their own percentages.
                window = nil
            }
        }
        return Values(weekly: weekly.count == 1 ? weekly.first : nil,
                      fable: fable.count == 1 ? fable.first : nil)
    }

    private static func percentUsed(_ line: String) -> Int? {
        guard line.range(of: #"^[0-9]{1,3} ?% used$"#, options: .regularExpression) != nil,
              let value = Int(line.prefix(while: \.isNumber)), value <= 100 else { return nil }
        return value
    }

    private static func file(for account: UUID) -> URL {
        Graft.graftFolder.appending(path: "display-usage").appending(path: account.uuidString.lowercased() + ".json")
    }

    private static func saved(for account: UUID) throws -> Reading {
        do {
            return try JSONDecoder().decode(Reading.self, from: Data(contentsOf: file(for: account)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Reading()
        }
    }

    /// Legacy reports only identify the profile. It may have signed into another
    /// account between a usage observation and the next dashboard refresh.
    static func graftReadings(at url: URL, now: Date = Date()) -> [UUID: Reading] {
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = report["profiles"] as? [Any] else { return [:] }
        let timestamp = ISO8601DateFormatter()
        let fraction = ISO8601DateFormatter()
        fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ field: Any?) -> Date? {
            guard let text = field as? String,
                  text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#,
                             options: .regularExpression) != nil else { return nil }
            return timestamp.date(from: text) ?? fraction.date(from: text)
        }

        var result: [UUID: Reading] = [:]
        for case let row as [String: Any] in rows {
            guard let id = row["accountUuid"] as? String, let account = UUID(uuidString: id),
                  let live = row["live"] as? NSNumber, CFGetTypeID(live) == CFBooleanGetTypeID(),
                  live.boolValue, row["note"] == nil, let observed = date(row["refreshedAt"]) else { continue }
            func metric(_ key: String) -> Metric? {
                guard let number = row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let percent = Int(exactly: number.doubleValue) else { return nil }
                if let reset = row[key + "Reset"] {
                    guard let end = date(reset), end > now else { return nil }
                }
                let sample = Metric(percent: percent, observedAt: observed, source: .graftUsage)
                return sample.isCurrent(at: now) ? sample : nil
            }
            var reading = result[account] ?? Reading()
            reading.weekly = newer(reading.weekly, metric("week"))
            reading.fable = newer(reading.fable, metric("fable"))
            if reading.weekly != nil || reading.fable != nil { result[account] = reading }
        }
        return result
    }

    static func load(account: UUID, relayWeekly: Metric? = nil, relayFable: Metric? = nil,
                     graftReading: Reading? = nil, now: Date = Date()) -> Reading {
        let stored = try? saved(for: account)
        func page(_ metric: Metric?) -> Metric? {
            metric.flatMap { $0.source.isPageReading && $0.isCurrent(at: now) ? $0 : nil }
        }
        func graft(_ metric: Metric?) -> Metric? {
            metric.flatMap { $0.source == .graftUsage && $0.isCurrent(at: now) ? $0 : nil }
        }
        let relayW = relayWeekly.flatMap { $0.source == .relay && $0.isCurrent(at: now) ? $0 : nil }
        let relayF = relayFable.flatMap { $0.source == .relay && $0.isCurrent(at: now) ? $0 : nil }
        let weekly = newer(page(stored?.weekly), graft(graftReading?.weekly))
        let fable = newer(page(stored?.fable), graft(graftReading?.fable))
        return Reading(weekly: newer(weekly, relayW), fable: newer(fable, relayF))
    }

    private static func newer(_ existing: Metric?, _ incoming: Metric?) -> Metric? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        if incoming.observedAt == existing.observedAt {
            // A relay timestamp can cover cached values from an earlier response.
            if incoming.source == .claudeUsagePage { return incoming }
            if existing.source == .relay { return incoming }
        }
        return incoming.observedAt > existing.observedAt ? incoming : existing
    }

    static func save(_ values: Values, account: UUID, source: Source = .copiedFromClaude,
                     observedAt: Date = Date()) throws {
        guard source.isPageReading, !values.isEmpty, observedAt <= Date(),
              [values.weekly, values.fable].compactMap({ $0 }).allSatisfy({ (0...100).contains($0) })
        else { throw DisplayError.invalidReading }
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }
        var reading = try saved(for: account)
        func merged(_ previous: Metric?, _ percent: Int?) -> Metric? {
            newer(previous, percent.map { Metric(percent: $0, observedAt: observedAt, source: source) })
        }
        reading.weekly = merged(reading.weekly, values.weekly)
        reading.fable = merged(reading.fable, values.fable)
        try UsagePool.writePrivate(JSONEncoder().encode(reading), to: file(for: account))
    }

    static func clear(account: UUID) throws {
        Graft.enterStateLock()
        defer { Graft.leaveStateLock() }
        do { try FileManager.default.removeItem(at: file(for: account)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
}
