import XCTest
@testable import MeetingTranscriber

/// v1.4: identidade da reunião (Calendar, título, argumentos da CLI).
@MainActor
final class MeetingIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - Seleção do evento pelo botão

    func testPicksMeetingInProgressWhenClickedAfterItStarted() {
        let result = CalendarMeetingSelector.forRecording(from: [
            candidate("Atual", start: -3, end: 57),
            candidate("Seguinte", start: 60, end: 90)
        ], now: now)

        XCTAssertEqual(result?.title, "Atual")
    }

    func testPrefersStartingMeetingOverOneThatOverran() {
        let result = CalendarMeetingSelector.forRecording(from: [
            candidate("Estourou", start: -55, end: 10),
            candidate("Começando", start: 3, end: 33)
        ], now: now)

        XCTAssertEqual(result?.title, "Começando")
    }

    func testIgnoresEndedLongAndIneligibleEvents() {
        let result = CalendarMeetingSelector.forRecording(from: [
            candidate("Terminou", start: -60, end: -5),
            candidate("Bloco de foco", start: -60, end: 9 * 60),
            candidate("Pendente", start: 1, end: 30, participation: .ineligible),
            candidate("Cancelada", start: 2, end: 30, isCancelled: true),
            candidate("Dia inteiro", start: -60, end: 23 * 60, isAllDay: true),
            candidate("Válida", start: 20, end: 50)
        ], now: now)

        XCTAssertEqual(result?.title, "Válida")
    }

    func testCarriesIdentityAndAttendeesOfTheChosenEvent() throws {
        let result = try XCTUnwrap(CalendarMeetingSelector.forRecording(from: [
            candidate(
                "Checkpoint",
                start: 0,
                end: 30,
                eventIdentifier: "evt-1",
                organizer: "Ana",
                attendees: ["Ana", "Bruno"]
            )
        ], now: now))

        XCTAssertEqual(result.eventIdentifier, "evt-1")
        XCTAssertEqual(result.endDate, date(30))
        XCTAssertEqual(result.organizerName, "Ana")
        XCTAssertEqual(result.attendeeNames, ["Ana", "Bruno"])
    }

    func testDeduplicatesSameEventFromTwoCalendars() {
        let result = CalendarMeetingSelector.forRecording(from: [
            candidate("Sync", start: 5, end: 35, calendar: "exchange", external: "ext-1"),
            candidate("Sync", start: 5, end: 35, calendar: "google", external: "ext-1")
        ], now: now)

        XCTAssertEqual(result?.title, "Sync")
    }

    func testDisplayNamesDropEmailsDuplicatesAndBlanks() {
        let names = CalendarMeetingSelector.displayNames(
            ["Ana Souza", nil, " ", "bruno@example.com", "ana souza", "Carla"]
        )

        XCTAssertEqual(names, ["Ana Souza", "Carla"])
    }

    // MARK: - Título e associação ao evento

    func testDefaultTitleUsesTheGivenStartTime() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertTrue(AppState.defaultTitle(at: start).hasPrefix("Reunião "))
        XCTAssertNotEqual(AppState.defaultTitle(at: start), AppState.defaultTitle(at: start.addingTimeInterval(3600)))
    }

    func testEditedTitleDropsCalendarAssociation() {
        let meeting = CalendarMeeting(title: "Checkpoint", startDate: now)

        XCTAssertEqual(
            AppState.calendarMeetingForTitle("Checkpoint — x", selected: meeting, selectedTitle: "Checkpoint — x"),
            meeting
        )
        XCTAssertNil(AppState.calendarMeetingForTitle("Outra reunião", selected: meeting, selectedTitle: "Checkpoint — x"))
        XCTAssertNil(AppState.calendarMeetingForTitle("Checkpoint — x", selected: nil, selectedTitle: nil))
    }

    // MARK: - Mic sem áudio

    func testMicStallUsesReceptionTimestamps() {
        let fresh = health(received: 10, lastReceived: mach_absolute_time())
        let never = health(received: 0, lastReceived: nil)

        XCTAssertFalse(AppState.micIsStalled(health: fresh, secondsSinceCaptureStart: 60))
        XCTAssertTrue(AppState.micIsStalled(health: never, secondsSinceCaptureStart: 6))
        XCTAssertFalse(AppState.micIsStalled(health: never, secondsSinceCaptureStart: 3))
    }

    // MARK: - Argumentos da CLI

    func testArgumentsCarryLocalTimeVocabularyAndCalendar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = directory.appendingPathComponent("vocabulary.json")
        try Data("{\"terms\":[\"X\"]}".utf8).write(to: vocabulary)
        let meeting = CalendarMeeting(
            title: "Checkpoint",
            startDate: now,
            endDate: now.addingTimeInterval(1800),
            organizerName: "Ana",
            attendeeNames: ["Ana", "Bruno"]
        )

        let args = TranscriptionRunner.arguments(
            script: "s.py",
            title: "Checkpoint — x",
            language: "auto",
            outputDir: directory,
            sessionID: nil,
            recordedAt: now,
            calendarMeeting: meeting,
            vocabularyURL: vocabulary
        )

        let recordedAt = try XCTUnwrap(value(after: "--recorded-at", in: args))
        if TimeZone.current.secondsFromGMT(for: now) != 0 {
            XCTAssertFalse(recordedAt.hasSuffix("Z"), "horário deve sair com o fuso local")
        }
        XCTAssertEqual(value(after: "--vocabulary", in: args), vocabulary.path)
        XCTAssertEqual(value(after: "--calendar-title", in: args), "Checkpoint")
        XCTAssertEqual(value(after: "--calendar-organizer", in: args), "Ana")
        XCTAssertNotNil(value(after: "--calendar-end", in: args))
        XCTAssertEqual(args.filter { $0 == "--participant" }.count, 2)
    }

    func testArgumentsSkipMissingVocabularyAndCalendar() {
        let args = TranscriptionRunner.arguments(
            script: "s.py",
            title: "Reunião",
            language: "pt",
            outputDir: URL(fileURLWithPath: "/tmp"),
            sessionID: nil,
            recordedAt: nil,
            calendarMeeting: nil,
            vocabularyURL: URL(fileURLWithPath: "/nonexistent/vocabulary.json")
        )

        XCTAssertFalse(args.contains("--vocabulary"))
        XCTAssertFalse(args.contains("--calendar-title"))
        XCTAssertFalse(args.contains("--participant"))
    }

    // MARK: - Persistência

    @MainActor
    func testCalendarMeetingSurvivesManifestRoundTripAndOldManifestsStillLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let meeting = CalendarMeeting(title: "Checkpoint", startDate: now, attendeeNames: ["Ana"])
        let job = TranscriptionJob(
            id: UUID(),
            title: "Checkpoint — x",
            language: "auto",
            micURL: nil,
            systemURL: nil,
            outputDir: root,
            sysOffsetMs: 0,
            createdAt: now,
            startedAt: nil,
            completedAt: nil,
            status: .queued,
            calendarMeeting: meeting
        )

        try store.save(job)
        let loaded = try XCTUnwrap(store.loadJobs().first)
        XCTAssertEqual(loaded.calendarMeeting, meeting)

        // Manifest da v1.3 (sem a chave calendarMeeting) continua legível.
        let legacyID = UUID()
        let legacyDirectory = root.appendingPathComponent(legacyID.uuidString)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = """
        {"captureIntegrity":{"details":[],"status":"complete"},"createdAt":"2026-09-22T18:58:52Z",
         "exportedToSecondBrain":false,"hidden":false,"id":"\(legacyID.uuidString)","language":"auto",
         "outputDirectory":"\(root.path)","progress":0,"schemaVersion":1,"state":"queued",
         "sysOffsetMs":0,"title":"Antiga"}
        """
        try Data(legacy.utf8).write(to: legacyDirectory.appendingPathComponent("manifest.json"))
        let reloaded = store.loadJobs()
        let old = try XCTUnwrap(reloaded.first { $0.id == legacyID })
        XCTAssertNil(old.calendarMeeting)
        XCTAssertEqual(old.title, "Antiga")
    }

    // MARK: - Helpers

    private func candidate(
        _ title: String,
        start: Int,
        end: Int,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        participation: CalendarParticipation = .acceptedAttendee,
        calendar: String = "calendar",
        eventIdentifier: String = "event",
        external: String? = nil,
        organizer: String? = nil,
        attendees: [String] = []
    ) -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            title: title,
            startDate: date(start),
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            participation: participation,
            calendarIdentifier: calendar,
            eventIdentifier: eventIdentifier,
            endDate: date(end),
            externalIdentifier: external,
            organizerName: organizer,
            attendeeNames: attendees
        )
    }

    private func date(_ minutes: Int) -> Date {
        now.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func health(received: UInt64, lastReceived: UInt64?) -> AudioCaptureHealth {
        AudioCaptureHealth(
            receivedBufferCount: received,
            writtenByteCount: 0,
            firstBufferHostTime: lastReceived,
            lastBufferHostTime: lastReceived,
            firstErrorDescription: nil,
            recoveryAttemptCount: 0,
            recoveryErrorDescription: nil,
            streamStopErrorDescription: nil,
            lastReceivedBufferHostTime: lastReceived
        )
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
