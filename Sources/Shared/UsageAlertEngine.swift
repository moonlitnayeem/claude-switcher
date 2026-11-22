import Foundation

struct UsageAlertAccountSample: Equatable {
    let id: String
    let name: String
    let isPrimary: Bool
    var fablePercent: Int?
    var fableReset: Date?
    var weeklyPercent: Int?
    var weeklyReset: Date?
    var sessionPercent: Int?
    var sessionReset: Date?
}

struct UsageAlertEvent: Equatable {
    enum Kind: String, Equatable {
        case primaryFableFull
        case primaryWeeklyFull
        case backupFable85
        case backupFable95
        case backupFableFull
        case fableReset
        case weeklyReset
    }

    let kind: Kind
    let accountID: String
    let accountName: String
    let percent: Int
    let dedupeKey: String
}

struct UsageAlertEngine {
    struct PreviousReading: Codable, Equatable {
        var fablePercent: Int?
        var fableReset: Date?
        var weeklyPercent: Int?
        var weeklyReset: Date?
    }

    var notifiedKeys: Set<String> = []
    var previous: [String: PreviousReading] = [:]

    mutating func evaluate(_ samples: [UsageAlertAccountSample], now: Date = Date()) -> [UsageAlertEvent] {
        var events: [UsageAlertEvent] = []
        for sample in samples {
            let prior = previous[sample.id]
            let fableStamp = Self.windowStamp(sample.fableReset ?? sample.weeklyReset, fallbackNow: now)
            let weekStamp = Self.windowStamp(sample.weeklyReset, fallbackNow: now)

            // Detect resets from a previously high/exhausted window into a fresh window.
            if let oldFable = prior?.fablePercent, oldFable >= 80,
               let curFable = sample.fablePercent, curFable < 20,
               prior?.fableReset != sample.fableReset {
                let key = "reset-fable:\(sample.id):\(fableStamp)"
                if mark(key) {
                    events.append(UsageAlertEvent(kind: .fableReset, accountID: sample.id,
                                                  accountName: sample.name, percent: curFable, dedupeKey: key))
                }
            }
            if let oldWeek = prior?.weeklyPercent, oldWeek >= 80,
               let curWeek = sample.weeklyPercent, curWeek < 20,
               prior?.weeklyReset != sample.weeklyReset {
                let key = "reset-week:\(sample.id):\(weekStamp)"
                if mark(key) {
                    events.append(UsageAlertEvent(kind: .weeklyReset, accountID: sample.id,
                                                  accountName: sample.name, percent: curWeek, dedupeKey: key))
                }
            }

            if sample.isPrimary {
                if let fable = sample.fablePercent, fable >= 100 {
                    let key = "main-fable-100:\(sample.id):\(fableStamp)"
                    if prior != nil, (prior?.fablePercent ?? 0) < 100, mark(key) {
                        events.append(UsageAlertEvent(kind: .primaryFableFull, accountID: sample.id,
                                                      accountName: sample.name, percent: 100, dedupeKey: key))
                    } else {
                        _ = mark(key)
                    }
                }
                if let week = sample.weeklyPercent, week >= 100 {
                    let key = "main-week-100:\(sample.id):\(weekStamp)"
                    if prior != nil, (prior?.weeklyPercent ?? 0) < 100, mark(key) {
                        events.append(UsageAlertEvent(kind: .primaryWeeklyFull, accountID: sample.id,
                                                      accountName: sample.name, percent: 100, dedupeKey: key))
                    } else {
                        _ = mark(key)
                    }
                }
            } else if let fable = sample.fablePercent {
                if fable >= 100 {
                    let key = "backup-fable-100:\(sample.id):\(fableStamp)"
                    if prior != nil, (prior?.fablePercent ?? 0) < 100, mark(key) {
                        events.append(UsageAlertEvent(kind: .backupFableFull, accountID: sample.id,
                                                      accountName: sample.name, percent: fable, dedupeKey: key))
                    } else {
                        _ = mark(key)
                    }
                } else if fable >= 95 {
                    let key = "backup-fable-95:\(sample.id):\(fableStamp)"
                    if prior != nil, (prior?.fablePercent ?? 0) < 95, mark(key) {
                        events.append(UsageAlertEvent(kind: .backupFable95, accountID: sample.id,
                                                      accountName: sample.name, percent: fable, dedupeKey: key))
                    } else {
                        _ = mark(key)
                    }
                } else if fable >= 85 {
                    let key = "backup-fable-85:\(sample.id):\(fableStamp)"
                    if prior != nil, (prior?.fablePercent ?? 0) < 85, mark(key) {
                        events.append(UsageAlertEvent(kind: .backupFable85, accountID: sample.id,
                                                      accountName: sample.name, percent: fable, dedupeKey: key))
                    } else {
                        _ = mark(key)
                    }
                }
            }

            previous[sample.id] = PreviousReading(
                fablePercent: sample.fablePercent ?? prior?.fablePercent,
                fableReset: sample.fableReset ?? prior?.fableReset,
                weeklyPercent: sample.weeklyPercent ?? prior?.weeklyPercent,
                weeklyReset: sample.weeklyReset ?? prior?.weeklyReset
            )
        }
        if notifiedKeys.count > 128 {
            notifiedKeys = Set(notifiedKeys.sorted().suffix(96))
        }
        return events
    }

    private mutating func mark(_ key: String) -> Bool {
        notifiedKeys.insert(key).inserted
    }

    private static func windowStamp(_ date: Date?, fallbackNow: Date) -> Int {
        if let date { return Int(date.timeIntervalSince1970.rounded()) }
        return Int((fallbackNow.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}
