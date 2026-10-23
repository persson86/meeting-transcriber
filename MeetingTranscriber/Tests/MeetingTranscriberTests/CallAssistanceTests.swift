import XCTest
import UserNotifications
@testable import MeetingTranscriber

/// Assistência Teams (2.0), sem hardware: detector com relógio virtual, filtro
/// de processos, casamento com o Calendar e o coordenador com captura e
/// notificações falsas. O invariante central: só gesto explícito sobre a oferta
/// vigente inicia ou encerra; o detector nunca.
final class CallEpisodeDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ detector: inout CallEpisodeDetector, _ samples: [(TimeInterval, Bool?)]) -> [CallEpisodeDetector.Event] {
        samples.compactMap { time, active in
            detector.ingest(active: active, at: time, wall: t0.addingTimeInterval(time))
        }
    }

    func testStartNeedsStableInputAndReportsWhenItBegan() {
        var detector = CallEpisodeDetector()
        let events = feed(&detector, [(0, false), (1, true), (2, true), (3, true)])
        XCTAssertEqual(events.count, 1)
        guard case .started(_, let at, let observed) = events.first else { return XCTFail("sem início") }
        XCTAssertEqual(at, t0.addingTimeInterval(1))
        XCTAssertTrue(observed)
    }

    func testBlipShorterThanStabilityIsIgnored() {
        var detector = CallEpisodeDetector()
        XCTAssertTrue(feed(&detector, [(0, false), (1, true), (2, false), (3, false)]).isEmpty)
        XCTAssertNil(detector.activeEpisode)
    }

    func testMuteGapAndDeviceSwitchDoNotEndTheEpisode() {
        var detector = CallEpisodeDetector()
        let start = feed(&detector, [(0, false), (1, true), (3, true)])
        let episode = detector.activeEpisode
        XCTAssertEqual(start.count, 1)
        // Lacuna de 11 s (troca de fone): menor que a tolerância de 12 s.
        let gap = feed(&detector, (4...14).map { (TimeInterval($0), false) } + [(15, true), (16, true)])
        XCTAssertTrue(gap.isEmpty)
        XCTAssertEqual(detector.activeEpisode, episode)
    }

    func testEndAfterStableSilenceCarriesTheMomentInputStopped() {
        var detector = CallEpisodeDetector()
        _ = feed(&detector, [(0, false), (1, true), (3, true)])
        let episode = detector.activeEpisode
        let events = feed(&detector, (10...22).map { (TimeInterval($0), false) })
        XCTAssertEqual(events, [.ended(episode: episode!, at: t0.addingTimeInterval(10))])
        XCTAssertNil(detector.activeEpisode)
    }

    func testUnknownReadsNeverEndOrStart() {
        var detector = CallEpisodeDetector()
        _ = feed(&detector, [(0, false), (1, true), (3, true), (4, false)])
        let events = feed(&detector, (5...60).map { (TimeInterval($0), nil) })
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(detector.activeEpisode)

        var idle = CallEpisodeDetector()
        XCTAssertTrue(feed(&idle, (0...30).map { (TimeInterval($0), nil) }).isEmpty)
    }

    func testUnknownGapDoesNotCountAsSilence() {
        var detector = CallEpisodeDetector()
        _ = feed(&detector, [(0, false), (1, true), (3, true), (10, false)])
        var events = feed(&detector, (11...100).map { (TimeInterval($0), nil) })
        events += feed(&detector, [(101, false)])
        XCTAssertTrue(events.isEmpty, "o silêncio recomeça a contar na leitura conhecida")
        XCTAssertEqual(feed(&detector, (102...113).map { (TimeInterval($0), false) }).count, 1)
    }

    func testUnknownInterruptsARisingStart() {
        var detector = CallEpisodeDetector()
        XCTAssertTrue(feed(&detector, [(0, false), (1, true), (2, nil), (3, true), (4, true)]).isEmpty)
        XCTAssertEqual(feed(&detector, [(5, true)]).count, 1)
    }

    func testActivityAlreadyRunningAtFirstReadIsNotAnObservedStart() {
        var detector = CallEpisodeDetector()
        let events = feed(&detector, [(0, true), (1, true), (2, true)])
        guard case .started(_, _, let observed) = events.first else { return XCTFail("sem início") }
        XCTAssertFalse(observed)
    }

    func testNewEpisodeAfterEndGetsNewIdentity() {
        var detector = CallEpisodeDetector()
        _ = feed(&detector, [(0, false), (1, true), (3, true)])
        let first = detector.activeEpisode
        _ = feed(&detector, (4...17).map { (TimeInterval($0), false) })
        _ = feed(&detector, [(18, true), (20, true)])
        XCTAssertNotNil(detector.activeEpisode)
        XCTAssertNotEqual(detector.activeEpisode, first)
    }
}

final class CallAppMatcherTests: XCTestCase {
    private func process(_ pid: pid_t, _ bundle: String, path: String = "", input: Bool = true, output: Bool = false) -> AudioProcessActivity {
        AudioProcessActivity(pid: pid, bundleID: bundle, executablePath: path, isRunningInput: input, isRunningOutput: output)
    }

    func testTeamsInputCountsButOwnProcessAndOutputOnlyDoNot() {
        let matcher = CallAppMatcher(excludedPID: 42)
        XCTAssertEqual(matcher.callActive(in: [process(10, "com.microsoft.teams2")]), true)
        XCTAssertEqual(matcher.callActive(in: [process(11, "com.microsoft.teams2.helper")]), true)
        XCTAssertEqual(matcher.callActive(in: [process(10, "com.microsoft.teams2", input: false, output: true)]), false)
        XCTAssertEqual(matcher.callActive(in: [process(42, "com.microsoft.teams2")]), false)
        XCTAssertEqual(matcher.callActive(in: [process(12, "com.google.Chrome")]), false)
        XCTAssertEqual(matcher.callActive(in: [process(13, "com.apple.audio.Core-Audio-Driver-Service.helper")]), false)
        XCTAssertNil(matcher.callActive(in: nil))
    }

    func testUnreadableTeamsProcessIsUnknownUnlessAnotherConfirmsInput() {
        let matcher = CallAppMatcher(excludedPID: 1)
        let unreadable = AudioProcessActivity(pid: 10, bundleID: "com.microsoft.teams2", executablePath: "", isRunningInput: nil, isRunningOutput: nil)
        XCTAssertNil(matcher.callActive(in: [unreadable]))
        XCTAssertEqual(matcher.callActive(in: [unreadable, process(11, "com.microsoft.teams2.helper")]), true)
        XCTAssertEqual(matcher.callActive(in: [process(12, "com.google.Chrome", input: false)]), false)
    }

    func testHelperWithoutBundleIDMatchesByExecutablePath() {
        let matcher = CallAppMatcher(excludedPID: 1)
        let helper = process(20, "", path: "/Applications/Microsoft Teams.app/Contents/Helpers/Microsoft Teams WebView.app/Contents/MacOS/Microsoft Teams WebView Helper")
        XCTAssertEqual(matcher.callActive(in: [helper]), true)
        XCTAssertEqual(matcher.callActive(in: [process(21, "", path: "/usr/bin/afplay")]), false)
    }

    func testExtraBundleIDsComeFromDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "matcher-\(UUID().uuidString)"))
        defaults.set(["io.example.call"], forKey: "assistanceExtraBundleIDs")
        let matcher = CallAppMatcher.configured(defaults: defaults)
        XCTAssertTrue(matcher.matches(process(30, "io.example.call")))
        XCTAssertTrue(matcher.matches(process(31, "com.microsoft.teams2")))
    }

    func testRealCoreAudioReadIsMetadataOnly() {
        // Somente leitura de propriedades do HAL; nunca abre dispositivo.
        guard CallAssistant.platformSupported else { return }
        let snapshot = CoreAudioProcessActivityProvider().snapshot()
        XCTAssertNotNil(snapshot)
    }
}

final class CalendarStartMatchTests: XCTestCase {
    private let call = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ title: String, offset: TimeInterval, external: String? = nil, participation: CalendarParticipation = .acceptedAttendee) -> CalendarMeetingCandidate {
        CalendarMeetingCandidate(
            title: title,
            startDate: call.addingTimeInterval(offset),
            isAllDay: false,
            isCancelled: false,
            participation: participation,
            calendarIdentifier: "cal",
            eventIdentifier: UUID().uuidString,
            endDate: call.addingTimeInterval(offset + 3600),
            externalIdentifier: external,
            organizerName: "Org",
            attendeeNames: ["Ana"]
        )
    }

    func testUniqueEventInsideToleranceInclusive() {
        let match = CalendarMeetingSelector.startingNear(call, from: [candidate("Sync", offset: -300)], tolerance: 300)
        XCTAssertEqual(match?.title, "Sync")
        XCTAssertEqual(match?.attendeeNames, ["Ana"])
    }

    func testOutsideToleranceIsExcluded() {
        XCTAssertNil(CalendarMeetingSelector.startingNear(call, from: [candidate("Sync", offset: -300.001)], tolerance: 300))
        XCTAssertNil(CalendarMeetingSelector.startingNear(call, from: [candidate("Sync", offset: 3600)], tolerance: 300))
    }

    func testTwoCandidatesHaveNoSilentTieBreak() {
        let candidates = [candidate("A", offset: -60), candidate("B", offset: 60)]
        XCTAssertNil(CalendarMeetingSelector.startingNear(call, from: candidates, tolerance: 300))
    }

    func testSameEventInTwoCalendarsCountsOnce() {
        let candidates = [candidate("A", offset: 0, external: "x"), candidate("A", offset: 0, external: "x")]
        XCTAssertEqual(CalendarMeetingSelector.startingNear(call, from: candidates, tolerance: 300)?.title, "A")
    }

    func testDeclinedOrNotParticipatingIsIgnored() {
        let candidates = [candidate("Recusada", offset: 0, participation: .ineligible), candidate("Minha", offset: 120)]
        XCTAssertEqual(CalendarMeetingSelector.startingNear(call, from: candidates, tolerance: 300)?.title, "Minha")
    }
}

// MARK: - Coordenador

@MainActor
private final class FakeRecorder: RecordingControl {
    weak var assistant: CallAssistant?
    var activeSessionID: UUID?
    var isRecordingNow: Bool { activeSessionID != nil }
    var canStartCapture: Bool { activeSessionID == nil }
    var starts: [(origin: RecordingOrigin, title: String?, meeting: CalendarMeeting?)] = []
    var stops: [String] = []

    @discardableResult
    func startRecording(origin: RecordingOrigin, title: String?, calendarMeeting: CalendarMeeting?) -> UUID? {
        guard canStartCapture else { return nil }
        let id = UUID()
        starts.append((origin, title, calendarMeeting))
        activeSessionID = id
        assistant?.captureStarted(sessionID: id, origin: origin)
        return id
    }

    func stopRecording(reason: String) {
        guard let id = activeSessionID else { return }
        stops.append(reason)
        activeSessionID = nil
        assistant?.captureEnded(sessionID: id)
    }
}

@MainActor
private final class FakeNotifier: AssistanceNotifying {
    var posted: [CallAssistant.Offer] = []
    var removed: [UUID] = []
    func postOffer(_ offer: CallAssistant.Offer) { posted.append(offer) }
    func removeOffer(id: UUID) { removed.append(id) }
}

private struct NoProvider: AudioProcessActivityProviding {
    func snapshot() -> [AudioProcessActivity]? { [] }
}

@MainActor
final class CallAssistantTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var notifier: FakeNotifier!
    private var assistant: CallAssistant!
    private var clock: TimeInterval = 1000
    private var calendarResult: CalendarMeeting?
    private var calendarQueries: [Date] = []
    private let wall0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        recorder = FakeRecorder()
        notifier = FakeNotifier()
        calendarResult = nil
        calendarQueries = []
        clock = 1000
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-\(UUID().uuidString)"))
        assistant = CallAssistant(
            recorder: recorder,
            notifier: notifier,
            provider: NoProvider(),
            calendarMatch: { [unowned self] date in
                self.calendarQueries.append(date)
                return self.calendarResult
            },
            defaults: defaults,
            uptime: { [unowned self] in self.clock },
            pollInterval: nil
        )
        recorder.assistant = assistant
        // Sem polling real: os testes alimentam o detector à mão.
        assistant.setEnabled(true)
    }

    /// Avança o relógio virtual com o microfone do Teams ativo ou não.
    private func run(_ active: Bool?, seconds: Int) async {
        for _ in 0..<seconds {
            clock += 1
            assistant.ingest(active: active, at: clock, wall: wall0.addingTimeInterval(clock))
        }
        for _ in 0..<5 { await Task.yield() }
    }

    private func meeting(_ title: String = "Sync de Produto") -> CalendarMeeting {
        CalendarMeeting(title: title, startDate: wall0, endDate: wall0.addingTimeInterval(3600), attendeeNames: ["Ana"])
    }

    func testDisabledAssistanceNeverOffers() async {
        assistant.setEnabled(false)
        await run(true, seconds: 10)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testCallStartOffersOnceWithCalendarTitleAndNeverRecordsByItself() async {
        calendarResult = meeting()
        await run(false, seconds: 1)
        await run(true, seconds: 30)
        XCTAssertEqual(assistant.offer?.kind, .start)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(assistant.suggestion?.title, "Sync de Produto")
        XCTAssertEqual(assistant.draftTitle, AppState.calendarTitle(for: meeting()))
        XCTAssertEqual(calendarQueries.count, 1)
        XCTAssertTrue(recorder.starts.isEmpty, "detector nunca inicia captura")
    }

    func testStartNowStartsOneAssistedSessionWithTheSuggestedTitleOnly() async {
        calendarResult = meeting()
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        let offer = try! XCTUnwrap(assistant.offer)

        XCTAssertTrue(assistant.perform(.startNow, offerID: offer.id))
        XCTAssertEqual(recorder.starts.count, 1)
        XCTAssertEqual(recorder.starts.first?.origin, .assisted)
        XCTAssertEqual(recorder.starts.first?.title, AppState.calendarTitle(for: meeting()))
        XCTAssertNil(recorder.starts.first?.meeting, "evento inferido não leva participantes")
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.removed.contains(offer.id))

        // Clique repetido ou notificação antiga: nada acontece.
        XCTAssertFalse(assistant.perform(.startNow, offerID: offer.id))
        XCTAssertEqual(recorder.starts.count, 1)
    }

    func testEditedTitleWinsAndDropsTheCalendarEvent() async {
        calendarResult = meeting()
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        assistant.draftTitle = "Conversa com a Ana"
        assistant.perform(.startNow, offerID: assistant.offer?.id)
        XCTAssertEqual(recorder.starts.first?.title, "Conversa com a Ana")
        XCTAssertNil(recorder.starts.first?.meeting)
    }

    func testEmptyTitleFallsBackToDefault() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        XCTAssertEqual(assistant.draftTitle, "")
        assistant.perform(.startNow, offerID: assistant.offer?.id)
        XCTAssertEqual(recorder.starts.count, 1)
        XCTAssertEqual(recorder.starts.first?.title, "", "vazio vira data e hora, nunca o campo manual")
    }

    func testTypingBeforeCalendarAnswersIsNotOverwritten() async {
        calendarResult = meeting()
        await run(false, seconds: 1)
        // Antes do Task do Calendar rodar.
        for _ in 0..<3 { clock += 1; assistant.ingest(active: true, at: clock, wall: wall0) }
        XCTAssertNotNil(assistant.offer)
        assistant.draftTitle = "Meu título"
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(assistant.draftTitle, "Meu título")
    }

    func testStaleOrMismatchedActionsDoNothing() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        XCTAssertFalse(assistant.perform(.startNow, offerID: UUID()))
        XCTAssertFalse(assistant.perform(.startNow, offerID: nil))
        XCTAssertFalse(assistant.perform(.stopAndTranscribe, offerID: assistant.offer?.id), "ação de fim numa oferta de início")
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertTrue(recorder.stops.isEmpty)
        XCTAssertNotNil(assistant.offer)
    }

    func testDeclineNeverRecordsAndIsNotRepeatedForTheSameCall() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        XCTAssertTrue(assistant.perform(.decline, offerID: assistant.offer?.id))
        await run(true, seconds: 120)
        await run(false, seconds: 5)   // lacuna curta: mesma chamada
        await run(true, seconds: 60)
        XCTAssertNil(assistant.offer)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(recorder.starts.isEmpty)
    }

    func testDismissKeepsTheQuestionWithoutNewNotification() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        let offer = assistant.offer
        XCTAssertTrue(assistant.perform(.dismissed, offerID: offer?.id))
        await run(true, seconds: 30)
        XCTAssertEqual(assistant.offer, offer)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue(recorder.starts.isEmpty)
    }

    func testCallEndingWithdrawsAnUnansweredStartOffer() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        let offer = try! XCTUnwrap(assistant.offer)
        await run(false, seconds: 15)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.removed.contains(offer.id))
        XCTAssertFalse(assistant.perform(.startNow, offerID: offer.id))
        XCTAssertTrue(recorder.starts.isEmpty)
    }

    func testManualStartAnswersThePendingOfferAndGetsNoEndQuestion() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        recorder.startRecording(origin: .manual, title: nil, calendarMeeting: nil)
        XCTAssertNil(assistant.offer)
        XCTAssertNil(assistant.assistedSessionID)
        await run(true, seconds: 60)
        await run(false, seconds: 30)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(recorder.stops.isEmpty)
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testManualRecordingNeverGetsStartOrEndQuestions() async {
        recorder.startRecording(origin: .manual, title: nil, calendarMeeting: nil)
        await run(false, seconds: 1)
        await run(true, seconds: 60)
        await run(false, seconds: 30)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.posted.isEmpty)
        XCTAssertTrue(recorder.stops.isEmpty)
    }

    private func startAssistedCall() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        assistant.perform(.startNow, offerID: assistant.offer?.id)
        // Passa a janela de proteção do próprio start.
        await run(true, seconds: 60)
    }

    func testEndQuestionForAssistedSessionAndConfirmedStop() async {
        await startAssistedCall()
        await run(false, seconds: 11)
        XCTAssertNil(assistant.offer, "antes da tolerância de fim")
        await run(false, seconds: 2)
        let offer = try! XCTUnwrap(assistant.offer)
        XCTAssertEqual(offer.kind, .end)
        XCTAssertEqual(offer.sessionID, recorder.activeSessionID)
        XCTAssertTrue(recorder.stops.isEmpty, "detector nunca encerra")

        await run(false, seconds: 600)
        XCTAssertTrue(recorder.stops.isEmpty, "ignorar não encerra nem insiste")
        XCTAssertEqual(notifier.posted.filter { $0.kind == .end }.count, 1)

        XCTAssertTrue(assistant.perform(.stopAndTranscribe, offerID: offer.id))
        XCTAssertEqual(recorder.stops, ["user_confirmed_assisted_end"])
        XCTAssertFalse(assistant.perform(.stopAndTranscribe, offerID: offer.id))
        XCTAssertEqual(recorder.stops.count, 1)
    }

    func testContinueRecordingKeepsAudioAndAsksAgainOnlyAfterTheCallReturnsAndEndsAgain() async {
        await startAssistedCall()
        await run(false, seconds: 13)
        XCTAssertTrue(assistant.perform(.continueRecording, offerID: assistant.offer?.id))
        XCTAssertNil(assistant.offer)
        await run(false, seconds: 300)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(recorder.stops.isEmpty)

        // A chamada volta (reconexão longa) e termina de novo.
        await run(true, seconds: 30)
        XCTAssertNil(assistant.offer, "retorno durante gravação não vira oferta de início")
        await run(false, seconds: 13)
        XCTAssertEqual(assistant.offer?.kind, .end)
        XCTAssertTrue(recorder.stops.isEmpty)
    }

    func testTeamsMicDropRightAfterOurStartIsNotAnEnd() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        assistant.perform(.startNow, offerID: assistant.offer?.id)
        // A troca de entrada padrão derruba o microfone do Teams por 14 s.
        await run(false, seconds: 14)
        XCTAssertNil(assistant.offer)
        await run(true, seconds: 60)
        await run(false, seconds: 13)
        XCTAssertEqual(assistant.offer?.kind, .end, "a próxima queda real pergunta")
    }

    func testDisablingDuringAssistedRecordingKeepsAudioAndDropsTheEndQuestion() async {
        await startAssistedCall()
        assistant.setEnabled(false)
        XCTAssertNotNil(recorder.activeSessionID)
        assistant.setEnabled(true)
        XCTAssertNil(assistant.assistedSessionID, "religar não readota a sessão")
        await run(true, seconds: 10)
        await run(false, seconds: 30)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(recorder.stops.isEmpty)
    }

    func testPauseWithdrawsThePendingQuestionAndIgnoresCallsUntilResumed() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        let offer = try! XCTUnwrap(assistant.offer)
        assistant.setPaused(true)
        XCTAssertTrue(assistant.isPaused)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.removed.contains(offer.id))
        XCTAssertEqual(assistant.availability, .off)
        await run(false, seconds: 15)
        await run(true, seconds: 10)
        XCTAssertNil(assistant.offer)
        XCTAssertEqual(notifier.posted.count, 1)

        assistant.setPaused(false)
        XCTAssertEqual(assistant.availability, .observing)
        await run(false, seconds: 15)
        await run(true, seconds: 3)
        XCTAssertEqual(assistant.offer?.kind, .start)
        XCTAssertTrue(recorder.starts.isEmpty)
    }

    func testPausingDuringAssistedRecordingKeepsAudioAndDropsTheEndQuestion() async {
        await startAssistedCall()
        assistant.setPaused(true)
        XCTAssertNotNil(recorder.activeSessionID)
        XCTAssertNil(assistant.assistedSessionID)
        assistant.setPaused(false)
        await run(true, seconds: 10)
        await run(false, seconds: 30)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(recorder.stops.isEmpty)
    }

    func testPauseNeedsAssistanceOnAndTurningOffClearsIt() {
        assistant.setPaused(true)
        assistant.setEnabled(false)
        XCTAssertFalse(assistant.isPaused)
        assistant.setPaused(true)
        XCTAssertFalse(assistant.isPaused, "desligada não pausa")
        assistant.setEnabled(true)
        XCTAssertFalse(assistant.isPaused)
    }

    func testEndQuestionDisappearsWhenUserStopsManually() async {
        await startAssistedCall()
        await run(false, seconds: 13)
        let offer = try! XCTUnwrap(assistant.offer)
        recorder.stopRecording(reason: "user")
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.removed.contains(offer.id))
        XCTAssertFalse(assistant.perform(.stopAndTranscribe, offerID: offer.id))
        XCTAssertEqual(recorder.stops, ["user"])
    }

    func testOldEndOfferCannotStopALaterSession() async {
        await startAssistedCall()
        await run(false, seconds: 13)
        let oldOffer = try! XCTUnwrap(assistant.offer)
        recorder.stopRecording(reason: "user")
        recorder.startRecording(origin: .manual, title: nil, calendarMeeting: nil)
        XCTAssertFalse(assistant.perform(.stopAndTranscribe, offerID: oldOffer.id))
        XCTAssertEqual(recorder.stops, ["user"])
        XCTAssertNotNil(recorder.activeSessionID)
    }

    func testTeamsReopeningMicRightAfterOurStopDoesNotOffer() async {
        await startAssistedCall()
        recorder.stopRecording(reason: "user")
        await run(false, seconds: 13)
        await run(true, seconds: 5)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(notifier.posted.filter { $0.kind == .start }.count == 1)
    }

    func testCallAlreadyRunningWhenEnabledOffersWithoutCalendarGuess() async {
        calendarResult = meeting()
        await run(true, seconds: 3)
        XCTAssertEqual(assistant.offer?.kind, .start)
        XCTAssertTrue(calendarQueries.isEmpty, "início não observado não casa com o Calendar")
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testNotificationGoesOutBeforeTheCalendarAnswers() async {
        calendarResult = meeting()
        await run(false, seconds: 1)
        for _ in 0..<3 { clock += 1; assistant.ingest(active: true, at: clock, wall: wall0) }
        XCTAssertEqual(notifier.posted.count, 1, "sem esperar o Calendar")
        XCTAssertTrue(assistant.isLookingUpCalendar)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(assistant.isLookingUpCalendar)
    }

    func testRealEndRightAfterOurStartIsAskedOnceTheGuardPasses() async {
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        assistant.perform(.startNow, offerID: assistant.offer?.id)
        // A pessoa sai da chamada 5 s depois de começar a gravar.
        await run(true, seconds: 5)
        await run(false, seconds: 20)
        XCTAssertNil(assistant.offer, "ainda na proteção do start")
        await run(false, seconds: 15)
        XCTAssertEqual(assistant.offer?.kind, .end)
        XCTAssertTrue(recorder.stops.isEmpty)
    }

    func testNextCallRightAfterAnEndedOneIsOffered() async {
        await startAssistedCall()
        await run(false, seconds: 13)
        assistant.perform(.stopAndTranscribe, offerID: assistant.offer?.id)
        // Reunião seguinte em seguida: a anterior já tinha acabado.
        await run(false, seconds: 3)
        await run(true, seconds: 3)
        XCTAssertEqual(assistant.offer?.kind, .start)
    }

    func testUnknownReadsMarkAssistanceUnavailableWithoutTouchingCapture() async {
        await startAssistedCall()
        await run(nil, seconds: 120)
        XCTAssertEqual(assistant.availability, .unavailable)
        XCTAssertNil(assistant.offer)
        XCTAssertTrue(recorder.stops.isEmpty)
        await run(true, seconds: 1)
        XCTAssertEqual(assistant.availability, .observing)
    }

    func testOpenReviewOnlyNavigates() async {
        var opened = 0
        assistant.presentReview = { opened += 1 }
        await run(false, seconds: 1)
        await run(true, seconds: 3)
        XCTAssertTrue(assistant.perform(.openReview, offerID: assistant.offer?.id))
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(recorder.starts.isEmpty)
        XCTAssertNotNil(assistant.offer)
    }
}

final class AssistanceNotificationRoutingTests: XCTestCase {
    func testBodyClickOnlyOpensReviewAndActionsMatchTheirCategory() {
        let start = NotificationManager.startCategory
        let end = NotificationManager.endCategory
        XCTAssertEqual(NotificationManager.assistanceAction(category: start, actionIdentifier: UNNotificationDefaultActionIdentifier), .openReview)
        XCTAssertEqual(NotificationManager.assistanceAction(category: end, actionIdentifier: UNNotificationDefaultActionIdentifier), .openReview)
        XCTAssertEqual(NotificationManager.assistanceAction(category: start, actionIdentifier: UNNotificationDismissActionIdentifier), .dismissed)
        XCTAssertEqual(NotificationManager.assistanceAction(category: start, actionIdentifier: "startNow"), .startNow)
        XCTAssertEqual(NotificationManager.assistanceAction(category: end, actionIdentifier: "stopAndTranscribe"), .stopAndTranscribe)
        XCTAssertNil(NotificationManager.assistanceAction(category: start, actionIdentifier: "stopAndTranscribe"))
        XCTAssertNil(NotificationManager.assistanceAction(category: end, actionIdentifier: "startNow"))
        XCTAssertNil(NotificationManager.assistanceAction(category: "other", actionIdentifier: "startNow"))
    }

    func testCategoriesHaveNoForegroundActionsAndContentIsSilent() {
        for category in NotificationManager.assistanceCategories {
            XCTAssertTrue(category.options.contains(.customDismissAction))
            for action in category.actions {
                XCTAssertFalse(action.options.contains(.foreground), action.identifier)
            }
        }
        let offer = CallAssistant.Offer(id: UUID(), kind: .start, episode: UUID(), sessionID: nil, createdAt: Date())
        let content = NotificationManager.assistanceContent(for: offer)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.categoryIdentifier, NotificationManager.startCategory)
        XCTAssertEqual(content.userInfo["offerID"] as? String, offer.id.uuidString)
        // Genérico: nenhum título de reunião no banner.
        XCTAssertEqual(content.title, "O Teams está usando áudio. Deseja gravar?")
        XCTAssertEqual(content.body, "Clique no aviso para definir um título.")
    }
}

final class AssistanceSessionPersistenceTests: XCTestCase {
    func testStartOriginRoundTripsAndLegacyRecordDecodes() throws {
        let record = SessionRecord.starting(at: Date(timeIntervalSince1970: 0), origin: .assisted)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.startOrigin, "assisted")
        let legacy = try JSONDecoder().decode(SessionRecord.self, from: Data(#"{"asrAttempts":[],"stopReason":"user"}"#.utf8))
        XCTAssertNil(legacy.startOrigin)
    }

    func testRenamingDuringRecordingClearsTheEventInTheManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootDirectory: root)
        let id = UUID()
        let meeting = CalendarMeeting(title: "Sync", startDate: Date(), attendeeNames: ["Ana"])
        _ = try store.prepareRecording(id: id, title: "Sync — 2026", language: "pt", outputDirectory: root, createdAt: Date(), calendarMeeting: meeting)
        try store.updateRecordingTitle(id: id, title: "Outro", calendarMeeting: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            DurableSessionManifest.self,
            from: Data(contentsOf: store.sessionDirectory(for: id).appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.title, "Outro")
        XCTAssertNil(manifest.calendarMeeting)
    }
}

@MainActor
final class AssistedStartAppStateTests: XCTestCase {
    func testRefusedStartReturnsNilWithoutTellingTheAssistant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assisted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(sessionStore: SessionStore(rootDirectory: root))
        var started = 0
        state.onCaptureStarted = { _, _ in started += 1 }
        state.mic = MicRecorder()
        state.status = .error("falha")
        state.meetingTitle = "Campo"

        XCTAssertNil(state.startRecording(origin: .assisted, title: "Oferta"))
        XCTAssertEqual(started, 0)
        XCTAssertNil(state.currentOrigin)
        XCTAssertEqual(state.meetingTitle, "Campo")
        XCTAssertFalse(state.canStartCapture)
    }

    func testRenameKeepsTheEventOnlyWhileTheTitleStillNamesIt() {
        let meeting = CalendarMeeting(title: "Sync", startDate: Date(timeIntervalSince1970: 0), attendeeNames: ["Ana"])
        XCTAssertEqual(AppState.calendarMeeting(meeting, afterRenamingTo: AppState.calendarTitle(for: meeting)), meeting)
        XCTAssertEqual(AppState.calendarMeeting(meeting, afterRenamingTo: "Sync"), meeting)
        XCTAssertNil(AppState.calendarMeeting(meeting, afterRenamingTo: "Outra conversa"))
        XCTAssertNil(AppState.calendarMeeting(nil, afterRenamingTo: "Sync"))
    }
}
