import Foundation
import Testing

@testable import BackpocketKit

/// Pinned to a fixed reference date and locale so month/weekday boundaries
/// never make these flaky.
@MainActor
@Suite struct NoteGroupingTests {
    private let locale = Locale(identifier: "ko_KR")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    /// 2026-08-19 12:00 KST, a Wednesday.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 12))!
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 10,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    private func group(_ date: Date) -> NoteGroup {
        NoteGroup.group(for: date, now: now, calendar: calendar, locale: locale)
    }

    private func label(_ date: Date) -> String {
        NoteGroup.rowLabel(for: date, now: now, calendar: calendar, locale: locale)
    }

    @Test func bucketsFollowTheNotesAppConvention() {
        #expect(group(date(2026, 8, 19)) == .today)
        #expect(group(date(2026, 8, 14)) == .last7Days)
        #expect(group(date(2026, 8, 1)) == .last30Days)
        #expect(group(date(2026, 7, 14)) == .month("7월"))
        #expect(group(date(2025, 12, 9)) == .month("2025년 12월"))
    }

    @Test func theSevenDayWindowEndsAtMidnightSevenDaysBack() {
        // The window runs from the start of today, not from now, so it is a
        // whole number of days regardless of the hour: 08-12 00:00 is in,
        // one second earlier is out. Widening it to -14 — or narrowing it to
        // -6 — moves exactly these two dates.
        #expect(group(date(2026, 8, 12, hour: 0, minute: 0)) == .last7Days)
        #expect(group(date(2026, 8, 11, hour: 23, minute: 59, second: 59)) == .last30Days)
        #expect(group(date(2026, 8, 13)) == .last7Days)
        #expect(group(date(2026, 8, 18, hour: 23)) == .last7Days)
    }

    @Test func theThirtyDayWindowEndsAtMidnightThirtyDaysBack() {
        // 30 days before 2026-08-19 is 2026-07-20; anything older falls
        // through to a month bucket.
        #expect(group(date(2026, 7, 20, hour: 0, minute: 0)) == .last30Days)
        #expect(group(date(2026, 7, 19, hour: 23, minute: 59, second: 59)) == .month("7월"))
    }

    @Test func monthLabelsCarryTheYearOnlyBeyondTheCurrentOne() {
        // Within this year the year would be noise on every row; across the
        // boundary its absence would make December 2025 and December 2026
        // one section.
        #expect(group(date(2026, 1, 5)) == .month("1월"))
        #expect(group(date(2025, 12, 31)) == .month("2025년 12월"))
        #expect(group(date(2025, 8, 19)) == .month("2025년 8월"))
    }

    @Test func aFutureStampLandsInToday() {
        // A clock correction (or a machine that woke up ahead) leaves stamps
        // in the future. They match no window below, and an unbucketed stamp
        // sorts above today's notes while landing in a different bucket — so
        // the run-merger emits Last 7 Days, Today, then Last 7 Days again: two
        // sections carrying the same id.
        #expect(group(date(2026, 8, 19, hour: 23)) == .today)
        #expect(group(date(2026, 8, 25)) == .today)
        #expect(group(date(2027, 3, 1)) == .today)
    }

    /// Sections are built by merging adjacent runs, so a bucket that is not
    /// contiguous in the sorted list opens a second section with the same id.
    /// SwiftUI diffing against duplicate ids is undefined behavior, and the
    /// list visibly doubles its headers.
    @Test func noTwoSectionsEverShareAnId() {
        var notes: [Item] = []
        // A spread wide enough to hit every bucket, plus the future stamp and
        // pinned notes that jump to the top regardless of their date.
        for daysBack in [-30, -1, 0, 1, 3, 7, 8, 20, 30, 31, 60, 200, 400] {
            let note = Item(content: "note \(daysBack)", isNote: true)
            note.usedAt = calendar.date(byAdding: .day, value: -daysBack, to: now)!
            notes.append(note)
        }
        for daysBack in [0, 9, 45] {
            let pinned = Item(content: "pinned \(daysBack)", isNote: true)
            pinned.usedAt = calendar.date(byAdding: .day, value: -daysBack, to: now)!
            pinned.isPinned = true
            notes.append(pinned)
        }

        // Exactly the store's order: pinned first, then most recent first.
        notes.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.usedAt > rhs.usedAt
        }

        let lists = PanelLists.make(
            items: notes, query: "", links: .keep, now: now)
        let ids = lists.noteSections.map(\.id)

        #expect(Set(ids).count == ids.count, "duplicate section id in \(ids)")
        // And the sections cover every note exactly once.
        #expect(lists.noteSections.reduce(0) { $0 + $1.rows.count } == notes.count)
    }

    @Test func rowLabelsMirrorTheBuckets() {
        #expect(label(date(2026, 8, 19, hour: 9)) == "오전 9:00")
        #expect(label(date(2026, 8, 14)) == "금요일")
        #expect(label(date(2026, 8, 1)) == "8월 1일")
        #expect(label(date(2025, 12, 9)) == "2025. 12. 9.")
    }

    /// group() and rowLabel() each make their own test against the week
    /// window, so one can be edited without the other. Sweeping a year of
    /// dates and checking that the label's *style* always matches the bucket
    /// is what catches that drift: change the comparison in one of them and
    /// the day they now disagree about fails here.
    @Test func everyPastDateGetsALabelStyleMatchingItsBucket() {
        for daysBack in 0...400 {
            for hour in [0, 9, 23] {
                let atHour = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
                let stamp = calendar.date(byAdding: .day, value: -daysBack, to: atHour)!
                // A same-day stamp later than `now` is a future stamp; those
                // are bucketed by the clock-correction rule, not by style.
                guard stamp < now else { continue }

                let sameYear =
                    calendar.component(.year, from: stamp) == calendar.component(.year, from: now)
                let expected: String
                switch group(stamp) {
                case .today: expected = style(stamp, .time)
                case .last7Days: expected = style(stamp, .weekday)
                case .last30Days, .month: expected = style(stamp, sameYear ? .monthDay : .shortDate)
                case .pinned:
                    // group(for:) is handed a date and nothing else, so it
                    // cannot know a note is pinned — the caller places that
                    // bucket. Inventing it here would put unpinned notes
                    // above the date sections.
                    Issue.record("group(for:) returned .pinned for a plain date")
                    continue
                }
                #expect(label(stamp) == expected, "\(daysBack) days back at \(hour):00")
            }
        }
    }

    private enum LabelStyle {
        case time
        case weekday
        case monthDay
        case shortDate
    }

    private func style(_ date: Date, _ style: LabelStyle) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        // Assigning `calendar` does not carry its time zone; without this the
        // expected side of every comparison renders in whatever zone the
        // machine is set to, and the suite passes in Seoul and fails on a UTC
        // runner. Same omission as the one this caught in DateFormatters.
        formatter.timeZone = calendar.timeZone
        switch style {
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .weekday:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        case .monthDay:
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        case .shortDate:
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// `NoteClock` places a note by comparing it with boundaries worked out
    /// once, and reuses what it formatted for a day, where the functions it
    /// replaced asked the calendar afresh for every note. Nothing the user
    /// sees may differ, so the clock is held to a verbatim copy of those
    /// functions: two years of stamps 37 minutes apart, future stamps
    /// included, so every hour of the day, both New Year's Eves and every DST
    /// change come up, in a zone with DST and one without. `now` sits just
    /// after a DST change, so both windows straddle it.
    ///
    /// The four shipped languages take turns, one stamp each. Where a day, a
    /// window or a year begins depends on the zone alone, so every stamp
    /// still tests that; the language only changes what a formatter prints,
    /// and each one still sees about ten stamps a day. A full sweep per
    /// language would cost four times as much to test nothing more.
    ///
    /// Two more `now`s get only the stamps around their windows, which is
    /// where they differ: one inside the repeated hour of a DST change, where
    /// today is 25 hours long, and one minutes into a new year, where most of
    /// the last 30 days belong to the year before.
    @Test(arguments: ["Asia/Seoul", "America/Los_Angeles"])
    func theClockMatchesTheFunctionsItReplaced(zone: String) throws {
        let calendars = try ["en_US", "ko_KR", "ja_JP", "zh_Hans"].map { id in
            let locale = Locale(identifier: id)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            return (calendar: calendar, locale: locale)
        }
        func date(_ components: DateComponents) throws -> Date {
            try #require(calendars[0].calendar.date(from: components))
        }

        let afterDSTStart = try date(DateComponents(year: 2026, month: 3, day: 10, hour: 9))
        let insideRepeatedHour = try date(
            DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30))
        let newYear = try date(DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 10))
        let sweeps = [
            (now: afterDSTStart, future: 60.0, past: 670.0),
            (now: insideRepeatedHour, future: 3, past: 40),
            (now: newYear, future: 3, past: 40),
        ]

        for sweep in sweeps {
            let stamps = stamps(
                from: sweep.now.addingTimeInterval(sweep.future * 86_400),
                to: sweep.now.addingTimeInterval(-sweep.past * 86_400))
            let edges = edges(of: sweep.now, calendar: calendars[0].calendar)
            for (turn, pair) in calendars.enumerated() {
                let mine = stride(from: turn, to: stamps.count, by: calendars.count).map {
                    stamps[$0]
                }
                let mismatches = mismatches(
                    in: (mine + edges).sorted(by: >), now: sweep.now, calendar: pair.calendar,
                    locale: pair.locale)
                #expect(mismatches.isEmpty, "\(pair.locale.identifier) at \(sweep.now)")
            }
        }
    }

    /// Under an era-based calendar the year component restarts mid-year, and
    /// once — Showa 64 to Heisei 1, on 1989-01-08 — mid-month: January 1989
    /// is two month labels and two answers to "this year?". Caching a label
    /// across that month is the mistake the clock's per-day reuse rules out.
    @Test func theClockMatchesTheFunctionsItReplacedAcrossAnEraChange() throws {
        let locale = Locale(identifier: "ja_JP@calendar=japanese")
        var calendar = Calendar(identifier: .japanese)
        calendar.locale = locale
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let now = try #require(
            gregorian.date(from: DateComponents(year: 1989, month: 2, day: 20, hour: 15)))

        let stamps = stamps(
            from: now.addingTimeInterval(3 * 86_400), to: now.addingTimeInterval(-400 * 86_400))
        let mismatches = mismatches(
            in: (stamps + edges(of: now, calendar: calendar)).sorted(by: >), now: now,
            calendar: calendar, locale: locale)
        #expect(mismatches.isEmpty)

        // The case this exists for, stated outright: the week of Showa 64
        // must not borrow Heisei's label, nor the other way round.
        var clock = NoteClock(now: now, calendar: calendar, locale: locale)
        let showa = try #require(
            gregorian.date(from: DateComponents(year: 1989, month: 1, day: 5, hour: 12)))
        let heisei = try #require(
            gregorian.date(from: DateComponents(year: 1989, month: 1, day: 20, hour: 12)))
        #expect(clock.group(for: heisei) != clock.group(for: showa))
    }

    /// Newest first, 37 minutes apart: a step that shares no factor with the
    /// minutes in a day, so over the weeks it lands on every time of day.
    private func stamps(from newest: Date, to oldest: Date) -> [Date] {
        Array(stride(from: newest, to: oldest, by: -37 * 60))
    }

    /// The instants the windows turn on, and the second before each — the
    /// sweep never lands exactly on a midnight, and whether a boundary counts
    /// as inside is the easiest thing to get wrong.
    private func edges(of now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let turns = [
            calendar.date(byAdding: .day, value: 1, to: today)!,
            today,
            calendar.date(byAdding: .day, value: -7, to: today)!,
            calendar.date(byAdding: .day, value: -30, to: today)!,
            calendar.dateInterval(of: .year, for: now)!.start,
            now,
        ]
        return turns.flatMap { [$0, $0.addingTimeInterval(-1)] }
    }

    /// Runs the old functions once per stamp, then one shared clock over the
    /// same stamps newest first — the order the store hands notes over — and
    /// again oldest first, since nothing about reusing a day may depend on the
    /// direction. `group` and `rowLabel` alternate on the one clock, as they
    /// do in the list. Every seventh stamp also goes through the static
    /// wrappers, which build a clock per call.
    ///
    /// Only the first few are returned: a broken clock disagrees thousands of
    /// times, and the failure prints whatever comes back.
    private func mismatches(
        in stamps: [Date], now: Date, calendar: Calendar, locale: Locale
    ) -> [String] {
        let expected = stamps.map {
            (
                group: LegacyNoteGroup.group(for: $0, now: now, calendar: calendar, locale: locale),
                label: LegacyNoteGroup.rowLabel(
                    for: $0, now: now, calendar: calendar, locale: locale)
            )
        }

        var mismatches: [String] = []
        for order in [Array(stamps.indices), stamps.indices.reversed()] {
            var clock = NoteClock(now: now, calendar: calendar, locale: locale)
            for index in order {
                let group = clock.group(for: stamps[index])
                let label = clock.rowLabel(for: stamps[index])
                if group != expected[index].group || label != expected[index].label {
                    mismatches.append("\(stamps[index]): \(group) \(label) != \(expected[index])")
                }
            }
        }
        for index in stride(from: 0, to: stamps.count, by: 7) {
            let group = NoteGroup.group(
                for: stamps[index], now: now, calendar: calendar, locale: locale)
            let label = NoteGroup.rowLabel(
                for: stamps[index], now: now, calendar: calendar, locale: locale)
            if group != expected[index].group || label != expected[index].label {
                mismatches.append("wrapper \(stamps[index]): \(group) \(label)")
            }
        }
        return Array(mismatches.prefix(3))
    }

    @Test func groupIdsAreStableAndDistinct() {
        let ids = [
            NoteGroup.today.id,
            NoteGroup.last7Days.id,
            NoteGroup.last30Days.id,
            NoteGroup.month("7월").id,
            NoteGroup.month("2025년 12월").id,
        ]
        #expect(Set(ids).count == ids.count)
    }
}

/// `NoteGroup.group(for:)` and `rowLabel(for:)` as they stood before
/// `NoteClock`, verbatim. They are what the notes column showed, so they are
/// the reference the clock is swept against — not a second implementation to
/// keep in step, and not to be edited.
@MainActor
private enum LegacyNoteGroup {
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
