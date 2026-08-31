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
        // the run-merger emits 지난 7일, 오늘, then 지난 7일 again: two
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

    /// group() and rowLabel() each carry their own copy of the -7 arithmetic,
    /// so one can be edited without the other. Sweeping a year of dates and
    /// checking that the label's *style* always matches the bucket is what
    /// catches that drift: change -7 in one of them and the day they now
    /// disagree about fails here.
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
