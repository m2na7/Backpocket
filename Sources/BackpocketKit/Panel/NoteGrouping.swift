import Foundation

/// The Apple Notes-style recency buckets the notes column is grouped by:
/// 오늘 / 지난 7일 / 이전 30일 / current-year months / year+month beyond.
/// Grouping keys off usedAt — the sort key — so buckets stay contiguous in
/// the already-sorted list and never interleave.
enum NoteGroup: Equatable {
    /// Pinned notes sit above every date bucket, the way the Notes app
    /// keeps them.
    case pinned
    case today
    case last7Days
    case last30Days
    /// Preformatted, localized: "7월" within the current year, "2025년 12월"
    /// for earlier years.
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
    @MainActor
    static func group(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> NoteGroup {
        // A clock correction can leave a stamp in the future, which matches no
        // window below and would open a second section carrying the same id as
        // the first. The nearest truthful bucket is today's.
        if date >= now || calendar.isDate(date, inSameDayAs: now) { return .today }

        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
            date >= weekAgo
        {
            return .last7Days
        }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday),
            date >= monthAgo
        {
            return .last30Days
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatters.templated(
            sameYear ? "MMMM" : "yMMMM", calendar: calendar, locale: locale)
        return .month(formatter.string(from: date))
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
        let formatter: DateFormatter
        if calendar.isDate(date, inSameDayAs: now) {
            formatter = DateFormatters.timeOnly(calendar: calendar, locale: locale)
        } else if let weekAgo = calendar.date(
            byAdding: .day, value: -7, to: calendar.startOfDay(for: now)),
            date >= weekAgo
        {
            formatter = DateFormatters.templated("EEEE", calendar: calendar, locale: locale)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter = DateFormatters.templated("MMMd", calendar: calendar, locale: locale)
        } else {
            formatter = DateFormatters.shortDate(calendar: calendar, locale: locale)
        }
        return formatter.string(from: date)
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
