import Foundation
import TermindApplication
import TermindPresentation
import Testing

@Suite
struct ChatMessageTimestampTests {
    @Test
    func todayUsesOnlyTheLocalizedShortTime() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let locale = Locale(identifier: "zh-Hans")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let message = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 26, hour: 9, minute: 5
                )))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 26, hour: 17
                )))

        #expect(
            ChatMessageTimestampFormatter.string(
                for: message, now: now, calendar: calendar,
                locale: locale, timeZone: timeZone
            )
                == expected(
                    message, dateStyle: .none, locale: locale,
                    calendar: calendar, timeZone: timeZone
                ))
    }

    @Test
    func anOlderDayIncludesLocalizedDateAndTime() throws {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let message = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 25, hour: 23, minute: 15
                )))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026, month: 8, day: 26, hour: 8
                )))

        #expect(
            ChatMessageTimestampFormatter.string(
                for: message, now: now, calendar: calendar,
                locale: locale, timeZone: timeZone
            )
                == expected(
                    message, dateStyle: .short, locale: locale,
                    calendar: calendar, timeZone: timeZone
                ))
    }

    private func expected(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
