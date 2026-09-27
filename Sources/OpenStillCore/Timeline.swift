import Foundation

/// Photos grouped by year, month and day of capture, newest first.
/// Capture dates are the camera's clock reading (stored as UTC), so days are the photographer's local days.
public struct Timeline: Equatable {
    public struct Day: Equatable, Identifiable {
        public var year: Int, month: Int, day: Int
        public var photos: [UUID]
        public var id: String { String(format: "%04d-%02d-%02d", year, month, day) }
        public var date: Date { Timeline.calendar.date(from: DateComponents(year: year, month: month, day: day))! }
    }
    public struct Month: Equatable, Identifiable {
        public var year: Int, month: Int
        public var days: [Day]
        public var id: String { String(format: "%04d-%02d", year, month) }
        public var count: Int { days.reduce(0) { $0 + $1.photos.count } }
        public var photos: [UUID] { days.flatMap(\.photos) }
    }
    public struct Year: Equatable, Identifiable {
        public var year: Int
        public var months: [Month]
        public var id: Int { year }
        public var count: Int { months.reduce(0) { $0 + $1.count } }
        public var photos: [UUID] { months.flatMap(\.photos) }
    }
    public var years: [Year]
    /// Photos without a capture date.
    public var undated: [UUID]

    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()

    /// Groups photos by capture date. Within a day photos are in capture order.
    public init(_ photos: [(id: UUID, captured: Date?)]) {
        var undated: [UUID] = []
        var byDay: [String: (Int, Int, Int, [(Date, UUID)])] = [:]
        for p in photos {
            guard let date = p.captured, date > Date(timeIntervalSince1970: -2_208_988_800) else { undated.append(p.id); continue }   // before 1900 is a bad clock
            let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
            guard let y = c.year, let m = c.month, let d = c.day else { undated.append(p.id); continue }
            let key = String(format: "%04d-%02d-%02d", y, m, d)
            byDay[key, default: (y, m, d, [])].3.append((date, p.id))
        }
        var years: [Int: [Int: [Day]]] = [:]
        for (_, entry) in byDay {
            let ordered = entry.3.sorted { $0.0 == $1.0 ? $0.1.uuidString < $1.1.uuidString : $0.0 < $1.0 }.map(\.1)
            years[entry.0, default: [:]][entry.1, default: []].append(Day(year: entry.0, month: entry.1, day: entry.2, photos: ordered))
        }
        self.years = years.keys.sorted(by: >).map { y in
            Year(year: y, months: years[y]!.keys.sorted(by: >).map { m in Month(year: y, month: m, days: years[y]![m]!.sorted { $0.day > $1.day }) })
        }
        self.undated = undated
    }
    public init(_ photos: [CatalogPhoto]) { self.init(photos.map { (id: $0.id, captured: $0.captured) }) }

    public var count: Int { years.reduce(0) { $0 + $1.count } + undated.count }

    /// "March 2024".
    public static func title(year: Int, month: Int) -> String {
        let f = DateFormatter(); f.timeZone = calendar.timeZone; f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f.string(from: calendar.date(from: DateComponents(year: year, month: month, day: 1))!)
    }
    /// "Saturday, March 9".
    public static func title(_ day: Day) -> String {
        let f = DateFormatter(); f.timeZone = calendar.timeZone; f.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        return f.string(from: day.date)
    }
}
