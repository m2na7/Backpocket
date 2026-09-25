import Foundation

/// The Apple Notes-style recency buckets the notes column is grouped by:
/// Today / Last 7 Days / Previous 30 Days / current-year months /
/// year+month beyond.
/// Grouping keys off usedAt — the sort key — so buckets stay contiguous in
/// the already-sorted list and never interleave.
enum NoteGroup: Equatable {
    /// Pinned notes sit above every date bucket, the way the Notes app
    /// keeps them.
    case pinned
    case today
    case last7Days
    case last30Days
    /// Preformatted, localized: "July" within the current year,
    /// "December 2025" for earlier years.
    case month(String)

    /// A stable identity for list diffing.
    var id: String {
        switch self {
        case .pinned: "pinned"
        case .today: "today"
        case .last7Days: "last7"
        case .last30Days: "last30"
        case .month(let label): label
        }
    }

    /// now/calendar/locale are injectable so tests can pin a reference date
    /// instead of flaking at midnight and month boundaries.
    ///
    /// One note at a time; a whole list goes through a shared `NoteClock`.
    @MainActor
    static func group(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> NoteGroup {
        var clock = NoteClock(now: now, calendar: calendar, locale: locale)
        return clock.group(for: date)
    }

    /// Row timestamps mirror the buckets, the way the Notes app labels rows:
    /// a clock time today, a weekday within the week, a date beyond.
    @MainActor
    static func rowLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var clock = NoteClock(now: now, calendar: calendar, locale: locale)
        return clock.rowLabel(for: date)
    }
}

/// Everything bucketing and labelling a note needs to know about `now`,
/// worked out once for a whole list instead of once per note.
///
/// The notes list is unbounded, and every recompute used to redo the same
/// calendar arithmetic for each note — the start of today, the 7- and 30-day
/// windows, the current year — and look its formatter up by a freshly built
/// key, twice. Here the windows are fixed once and a note is placed by
/// comparing dates. What is formatted for a day is kept while the next note
/// falls on that same day, and the store hands notes over sorted, so a busy
/// day formats once.
///
/// The day is the unit of reuse, not the month or the year, because it is
/// the only one that never straddles a change of era: a month label cached
/// across one would carry the old era's year into the new one.
@MainActor
struct NoteClock {
    private let now: Date
    private let calendar: Calendar
    private let locale: Locale
    private let startOfToday: Date
    private let startOfTomorrow: Date
    private let weekAgo: Date?
    private let monthAgo: Date?
    private let year: Int

    private var formatters: [Style: DateFormatter] = [:]
    private var day = Day()

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        startOfToday = calendar.startOfDay(for: now)
        // A calendar that cannot say where today ends has never been seen;
        // treating everything after its start as today is the least wrong.
        startOfTomorrow = calendar.dateInterval(of: .day, for: now)?.end ?? .distantFuture
        // Counted back from the start of today, not from now, so each window
        // is a whole number of days whatever the hour — and computed from it
        // rather than as 7 × 86,400 seconds, so a DST change inside the window
        // still lands the boundary on a midnight.
        weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday)
        monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)
        year = calendar.component(.year, from: now)
    }

    mutating func group(for date: Date) -> NoteGroup {
        // A clock correction can leave a stamp in the future, which matches no
        // window below and would open a second section carrying the same id as
        // the first. The nearest truthful bucket is today's.
        if date >= now || isToday(date) { return .today }
        if let weekAgo, date >= weekAgo { return .last7Days }
        if let monthAgo, date >= monthAgo { return .last30Days }
        return .month(label(date, isThisYear(date) ? .month : .yearMonth))
    }

    /// A stamp later than today still gets a weekday rather than a date: it is
    /// past the week window's start, which is all that test asks.
    mutating func rowLabel(for date: Date) -> String {
        // The one label finer than a day, so the one that is never reused.
        if isToday(date) { return formatter(.time).string(from: date) }
        if let weekAgo, date >= weekAgo { return label(date, .weekday) }
        return label(date, isThisYear(date) ? .monthDay : .shortDate)
    }

    /// Half-open on purpose: `DateInterval.contains` counts its end, and the
    /// end of today is the first instant of tomorrow.
    private func isToday(_ date: Date) -> Bool {
        startOfToday <= date && date < startOfTomorrow
    }

    /// Compared by the year component rather than by an interval: that is
    /// the question the labels have always asked, and under an era-based
    /// calendar the two answers differ.
    private mutating func isThisYear(_ date: Date) -> Bool {
        moveDay(to: date)
        return day.isThisYear
    }

    /// Only for the styles that print nothing finer than the day, which is
    /// what makes reusing a label across the day exact.
    private mutating func label(_ date: Date, _ style: Style) -> String {
        moveDay(to: date)
        if let label = day.labels[style] { return label }
        let label = formatter(style).string(from: date)
        day.labels[style] = label
        return label
    }

    private mutating func moveDay(to date: Date) {
        guard !day.contains(date) else { return }
        day = Day(
            interval: calendar.dateInterval(of: .day, for: date),
            isThisYear: calendar.component(.year, from: date) == year
        )
    }

    private mutating func formatter(_ style: Style) -> DateFormatter {
        if let formatter = formatters[style] { return formatter }
        let formatter =
            switch style {
            case .time: DateFormatters.timeOnly(calendar: calendar, locale: locale)
            case .weekday: DateFormatters.templated("EEEE", calendar: calendar, locale: locale)
            case .monthDay: DateFormatters.templated("MMMd", calendar: calendar, locale: locale)
            case .shortDate: DateFormatters.shortDate(calendar: calendar, locale: locale)
            case .month: DateFormatters.templated("MMMM", calendar: calendar, locale: locale)
            case .yearMonth:
                DateFormatters.templated("yMMMM", calendar: calendar, locale: locale)
            }
        formatters[style] = formatter
        return formatter
    }

    private enum Style {
        case time
        case weekday
        case monthDay
        case shortDate
        case month
        case yearMonth
    }

    /// The calendar day of the last note placed, and what has been worked
    /// out for it so far.
    private struct Day {
        /// Nil until a note is placed, and should the calendar ever fail to
        /// answer — either way nothing is reused.
        var interval: DateInterval?
        var isThisYear = false
        var labels: [Style: String] = [:]

        func contains(_ date: Date) -> Bool {
            guard let interval else { return false }
            return interval.start <= date && date < interval.end
        }
    }
}

/// Building a DateFormatter costs tens of microseconds, and refilter labels
/// every note on every keystroke — notes are exempt from expiry and the
/// history cap, so that list is unbounded.
@MainActor
enum DateFormatters {
    private static var cache: [String: DateFormatter] = [:]

    static func templated(
        _ template: String, calendar: Calendar, locale: Locale
    ) -> DateFormatter {
        formatter(key: "t:\(template)", calendar: calendar, locale: locale) {
            $0.setLocalizedDateFormatFromTemplate(template)
        }
    }

    static func timeOnly(calendar: Calendar, locale: Locale) -> DateFormatter {
        formatter(key: "timeOnly", calendar: calendar, locale: locale) {
            $0.dateStyle = .none
            $0.timeStyle = .short
        }
    }

    static func shortDate(calendar: Calendar, locale: Locale) -> DateFormatter {
        formatter(key: "shortDate", calendar: calendar, locale: locale) {
            $0.dateStyle = .short
            $0.timeStyle = .none
        }
    }

    private static func formatter(
        key: String,
        calendar: Calendar,
        locale: Locale,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        // Calendar, locale AND time zone are part of the key: tests pin them,
        // and a cached formatter built for another one would format wrongly.
        // The zone belongs here because it is a separate axis — two calendars
        // agreeing on identifier can still disagree on what hour it is.
        let key =
            "\(key)|\(locale.identifier)|\(calendar.identifier)"
            + "|\(calendar.timeZone.identifier)"
        if let cached = cache[key] { return cached }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        // Assigning `calendar` does NOT carry its time zone over; a
        // DateFormatter keeps its own, defaulting to the system's. In the app
        // both come from `.current` so the two agree and nothing shows. In a
        // test that pins Asia/Seoul the formatter kept rendering in the
        // machine's zone, which passed in Seoul and failed on a UTC runner —
        // the same instant labelled nine hours apart.
        formatter.timeZone = calendar.timeZone
        configure(formatter)
        cache[key] = formatter
        return formatter
    }
}
