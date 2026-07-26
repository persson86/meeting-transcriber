import XCTest
@testable import MeetingTranscriber

final class CalendarMeetingSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testSelectsEarliestAcceptedFutureMeeting() {
        let result = select([
            candidate(title: "Later", minutesFromNow: 45),
            candidate(
                title: "Pending",
                minutesFromNow: 5,
                participation: .ineligible
            ),
            candidate(title: "Next", minutesFromNow: 15)
        ])

        XCTAssertEqual(
            result,
            CalendarMeeting(title: "Next", startDate: date(minutesFromNow: 15))
        )
    }

    func testExcludesPastAllDayAndCancelledEvents() {
        let result = select([
            candidate(title: "Past", minutesFromNow: -1),
            candidate(title: "All day", minutesFromNow: 5, isAllDay: true),
            candidate(title: "Cancelled", minutesFromNow: 10, isCancelled: true),
            candidate(title: "Eligible", minutesFromNow: 20)
        ])

        XCTAssertEqual(result?.title, "Eligible")
    }

    func testIncludesMeetingOrganizedByCurrentUserWithParticipants() {
        let result = select([
            candidate(
                title: "Organized meeting",
                minutesFromNow: 10,
                participation: .currentUserOrganizerWithParticipants
            )
        ])

        XCTAssertEqual(result?.title, "Organized meeting")
    }

    func testExcludesCandidateWithoutEligibleParticipation() {
        let result = select([
            candidate(
                title: "Focus block",
                minutesFromNow: 10,
                participation: .ineligible
            )
        ])

        XCTAssertNil(result)
    }

    func testExcludesEventAtEndOfTwentyFourHourWindow() {
        let result = select([
            candidate(title: "Tomorrow", minutesFromNow: 24 * 60)
        ])

        XCTAssertNil(result)
    }

    func testIncludesEventStartingNow() {
        let result = select([
            candidate(title: "Now", minutesFromNow: 0)
        ])

        XCTAssertEqual(result?.title, "Now")
    }

    func testUsesDeterministicTitleTieBreaker() {
        let result = select([
            candidate(title: "Zulu", minutesFromNow: 10),
            candidate(title: "Alpha", minutesFromNow: 10)
        ])

        XCTAssertEqual(result?.title, "Alpha")
    }

    func testFallsBackForBlankEventTitle() {
        let result = select([
            candidate(title: "  ", minutesFromNow: 10)
        ])

        XCTAssertEqual(result?.title, "Reunião")
    }

    private func select(_ candidates: [CalendarMeetingCandidate]) -> CalendarMeeting? {
        CalendarMeetingSelector.next(
            from: candidates,
            now: now,
            endDate: date(minutesFromNow: 24 * 60)
        )
    }

    private func candidate(
        title: String?,
        minutesFromNow: Int,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        participation: CalendarParticipation = .acceptedAttendee,
        calendarIdentifier: String = "calendar",
        eventIdentifier: String = "event"
    ) -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            title: title,
            startDate: date(minutesFromNow: minutesFromNow),
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            participation: participation,
            calendarIdentifier: calendarIdentifier,
            eventIdentifier: eventIdentifier
        )
    }

    private func date(minutesFromNow: Int) -> Date {
        now.addingTimeInterval(TimeInterval(minutesFromNow * 60))
    }
}
