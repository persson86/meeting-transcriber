import Foundation
import SwiftUI

/// O que a assistência precisa da captura. AppState cumpre; os testes usam um
/// fake sem hardware.
@MainActor
protocol RecordingControl: AnyObject {
    var canStartCapture: Bool { get }
    var activeSessionID: UUID? { get }
    var isRecordingNow: Bool { get }
    @discardableResult
    func startRecording(origin: RecordingOrigin, title: String?, calendarMeeting: CalendarMeeting?) -> UUID?
    func stopRecording(reason: String)
}

extension AppState: RecordingControl {
    var canStartCapture: Bool {
        storageIsAvailable && status.canStartRecording && !hasActiveRecorder && !isCalendarSyncing
    }
    var isRecordingNow: Bool { status.isRecording }
}

/// Canal de aviso da assistência: notificação nativa com ações. O aviso é
/// genérico: título de reunião não aparece em banner (compartilhamento de tela).
@MainActor
protocol AssistanceNotifying: AnyObject {
    func postOffer(_ offer: CallAssistant.Offer)
    func removeOffer(id: UUID)
}

/// Assistência Teams (2.0). Observa o microfone do Teams e **oferece** gravar
/// quando uma chamada parece começar, e encerrar quando parece terminar numa
/// gravação que a própria oferta iniciou. Nunca inicia nem para áudio sozinha:
/// só um gesto explícito (botão da notificação, do menu ou da janela) chama os
/// comandos existentes de AppState, e só para a oferta vigente.
@MainActor
final class CallAssistant: ObservableObject {
    enum Kind: String, Equatable { case start, end }

    struct Offer: Equatable, Identifiable {
        let id: UUID
        let kind: Kind
        let episode: UUID
        /// Fim: a gravação assistida a que a pergunta se refere.
        let sessionID: UUID?
        let createdAt: Date
    }

    enum Action: String {
        case startNow, decline, continueRecording, stopAndTranscribe, openReview, dismissed
    }

    enum Availability: Equatable {
        case off
        case observing
        /// macOS sem a API de processos de áudio (anterior ao 14.2).
        case unsupported
        /// Leituras do Core Audio falhando: a gravação não muda, só a assistência.
        case unavailable
    }

    static let enabledDefaultsKey = "assistanceEnabled"
    /// Janela entre o início observado da chamada e o início do evento.
    static let calendarTolerance: TimeInterval = 5 * 60
    /// Logo após o app iniciar ou parar a captura, a troca da entrada padrão
    /// (1.9.0) pode fazer o Teams reabrir o microfone. Um fim nesse intervalo é
    /// reavaliado quando ele acaba; um início logo após o nosso stop no meio de
    /// uma chamada não vira oferta.
    static let ownCaptureGuard: TimeInterval = 20

    static weak var current: CallAssistant?

    @Published private(set) var isEnabled: Bool
    @Published private(set) var availability: Availability = .off
    @Published private(set) var offer: Offer?
    /// Rascunho de título da oferta de início; compartilhado entre menu e janela.
    @Published var draftTitle: String = "" {
        didSet { if !applyingSuggestion, draftTitle != oldValue { draftEditedByUser = true } }
    }
    /// Evento do Calendar casado com o início da chamada (só se único).
    @Published private(set) var suggestion: CalendarMeeting?
    @Published private(set) var isLookingUpCalendar = false
    /// A gravação em curso foi iniciada pela oferta e ainda pode receber a
    /// pergunta de fim.
    @Published private(set) var assistedSessionID: UUID?

    private weak var recorder: RecordingControl?
    private let notifier: AssistanceNotifying
    private let provider: AudioProcessActivityProviding
    private let matcher: CallAppMatcher
    private let calendarMatch: (Date) async -> CalendarMeeting?
    private let defaults: UserDefaults
    private let uptime: () -> TimeInterval
    /// nil desliga a leitura periódica (testes alimentam `ingest` à mão).
    private let pollInterval: TimeInterval?
    private var detector = CallEpisodeDetector()
    private var pollTask: Task<Void, Never>?
    private var consecutiveReadFailures = 0

    /// Episódios que já tiveram resposta (recusa, gravação, sessão manual) ou
    /// cuja oferta foi retirada: não são oferecidos de novo.
    private var handledEpisodes: Set<UUID> = []
    private var assistedEpisode: UUID?
    private var pendingAssistedEpisode: UUID?
    private var lastOwnCaptureStart: TimeInterval = -.infinity
    private var lastOwnCaptureEnd: TimeInterval = -.infinity
    /// Havia chamada ativa quando paramos: só então o Teams pode reabrir o
    /// microfone por causa da nossa troca de entrada.
    private var callActiveAtOwnStop = false
    /// Fim caído na janela de proteção do start: reavaliado no prazo.
    private var deferredEnd: (episode: UUID, deadline: TimeInterval)?
    private var draftEditedByUser = false
    private var applyingSuggestion = false

    /// Abre a janela de revisão (clique no corpo da notificação ou no menu).
    var presentReview: () -> Void = {}

    init(
        recorder: RecordingControl?,
        notifier: AssistanceNotifying,
        provider: AudioProcessActivityProviding = CoreAudioProcessActivityProvider(),
        matcher: CallAppMatcher = .configured(),
        calendarMatch: ((Date) async -> CalendarMeeting?)? = nil,
        defaults: UserDefaults = .standard,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pollInterval: TimeInterval? = 1
    ) {
        self.recorder = recorder
        self.notifier = notifier
        self.provider = provider
        self.matcher = matcher
        let lookup = CalendarLookup()
        self.calendarMatch = calendarMatch ?? { date in
            await lookup.meetingStarting(near: date, tolerance: CallAssistant.calendarTolerance)
        }
        self.defaults = defaults
        self.uptime = uptime
        self.pollInterval = pollInterval
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Liga a observação se a preferência estiver ativa. Chamado uma vez pelo app.
    func activate() {
        Self.current = self
        if isEnabled { startObserving() }
    }

    // MARK: - Preferência

    /// Ligar só observa e oferece. Desligar retira ofertas e a pergunta de fim
    /// da gravação corrente, sem tocar no áudio; religar não a readota.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        AppLog.assistance.info("assistance enabled=\(enabled, privacy: .public)")
        if enabled {
            startObserving()
        } else {
            stopObserving()
            withdrawOffer()
            assistedSessionID = nil
            assistedEpisode = nil
            availability = .off
        }
    }

    private func startObserving() {
        detector.reset()
        handledEpisodes.removeAll()
        consecutiveReadFailures = 0
        guard Self.platformSupported else {
            availability = .unsupported
            return
        }
        availability = .observing
        pollTask?.cancel()
        guard let pollInterval else { return }
        let provider = provider
        let matcher = matcher
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) { provider.snapshot() }.value
                guard !Task.isCancelled, let self else { return }
                self.ingest(active: matcher.callActive(in: snapshot), at: self.uptime(), wall: Date())
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    private func stopObserving() {
        pollTask?.cancel()
        pollTask = nil
        detector.reset()
    }

    nonisolated static var platformSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: - Observação

    /// Uma leitura do detector. Interno para os testes com relógio virtual.
    func ingest(active: Bool?, at time: TimeInterval, wall: Date) {
        guard isEnabled else { return }
        if active == nil {
            consecutiveReadFailures += 1
            if consecutiveReadFailures >= 5, availability == .observing {
                availability = .unavailable
                AppLog.assistance.error("core audio reads failing; assistance unavailable")
            }
        } else {
            consecutiveReadFailures = 0
            if availability == .unavailable { availability = .observing }
        }
        if let event = detector.ingest(active: active, at: time, wall: wall) {
            handle(event, at: time)
        }
        resolveDeferredEnd(now: time)
    }

    /// Passada a proteção do start, o microfone do Teams continua parado e nada
    /// religou a gravação a outro episódio: era fim de verdade, pergunta agora.
    private func resolveDeferredEnd(now: TimeInterval) {
        guard let pending = deferredEnd, now >= pending.deadline else { return }
        deferredEnd = nil
        guard detector.activeEpisode == nil, assistedEpisode == nil else { return }
        postEndOffer(episode: pending.episode)
    }

    private func handle(_ event: CallEpisodeDetector.Event, at time: TimeInterval) {
        switch event {
        case .started(let episode, let startedAt, let observed):
            AppLog.assistance.info("call started episode=\(episode.uuidString, privacy: .public) observed=\(observed, privacy: .public)")
            callStarted(episode: episode, at: startedAt, observed: observed, now: time)
        case .ended(let episode, _):
            AppLog.assistance.info("call ended episode=\(episode.uuidString, privacy: .public)")
            callEnded(episode: episode, now: time)
        }
    }

    private func callStarted(episode: UUID, at startedAt: Date, observed: Bool, now: TimeInterval) {
        if let recorder, recorder.activeSessionID != nil {
            // Gravando: atividade nova é a mesma chamada voltando (reconexão,
            // troca de fone) ou outra chamada; nunca vira oferta de início.
            if assistedSessionID != nil {
                assistedEpisode = episode
                deferredEnd = nil
                if offer?.kind == .end { withdrawOffer() }
            }
            handledEpisodes.insert(episode)
            return
        }
        if callActiveAtOwnStop, now - lastOwnCaptureEnd < Self.ownCaptureGuard {
            // Teams reabrindo o microfone logo depois do nosso stop no meio da
            // chamada. Chamada nova depois de uma que já tinha acabado é oferecida.
            handledEpisodes.insert(episode)
            return
        }
        guard !handledEpisodes.contains(episode), recorder?.canStartCapture == true else { return }

        let newOffer = Offer(id: UUID(), kind: .start, episode: episode, sessionID: nil, createdAt: Date())
        offer = newOffer
        suggestion = nil
        applyingSuggestion = true
        draftTitle = ""
        applyingSuggestion = false
        draftEditedByUser = false

        // O aviso sai já; o Calendar só preenche o rascunho visto no menu/janela.
        notifier.postOffer(newOffer)
        // Início real desconhecido (app aberto no meio da chamada): sem
        // casamento com o Calendar.
        guard observed else { return }
        isLookingUpCalendar = true
        Task { [weak self] in
            guard let self else { return }
            let meeting = await self.calendarMatch(startedAt)
            guard self.offer?.id == newOffer.id else { return }
            self.isLookingUpCalendar = false
            if let meeting, !self.draftEditedByUser {
                self.suggestion = meeting
                self.applyingSuggestion = true
                self.draftTitle = AppState.calendarTitle(for: meeting)
                self.applyingSuggestion = false
            }
        }
    }

    private func callEnded(episode: UUID, now: TimeInterval) {
        handledEpisodes.remove(episode)
        if let current = offer, current.kind == .start, current.episode == episode {
            // A chamada acabou sem resposta: a oferta deixa de valer.
            withdrawOffer()
            return
        }
        guard let recorder, let sessionID = assistedSessionID, assistedEpisode == episode,
              recorder.isRecordingNow, recorder.activeSessionID == sessionID else { return }
        // O evento chega `endStability` depois de o microfone cair.
        let guardEnd = lastOwnCaptureStart + Self.ownCaptureGuard + detector.parameters.endStability
        if now < guardEnd {
            // O microfone do Teams caiu logo depois do nosso start: pode ser a
            // troca de entrada. Se voltar, religa; se não, pergunta no prazo.
            assistedEpisode = nil
            deferredEnd = (episode, guardEnd)
            return
        }
        postEndOffer(episode: episode)
    }

    private func postEndOffer(episode: UUID) {
        guard let recorder, let sessionID = assistedSessionID,
              recorder.isRecordingNow, recorder.activeSessionID == sessionID else { return }
        let newOffer = Offer(id: UUID(), kind: .end, episode: episode, sessionID: sessionID, createdAt: Date())
        withdrawOffer()
        offer = newOffer
        notifier.postOffer(newOffer)
    }

    // MARK: - Captura (avisos de AppState)

    func captureStarted(sessionID: UUID, origin: RecordingOrigin) {
        lastOwnCaptureStart = uptime()
        deferredEnd = nil
        switch origin {
        case .assisted:
            assistedSessionID = isEnabled ? sessionID : nil
            assistedEpisode = pendingAssistedEpisode
        case .manual:
            // Iniciar manualmente responde à oferta pendente: some, sem pergunta
            // de fim para esta sessão.
            if let current = offer, current.kind == .start { handledEpisodes.insert(current.episode) }
            withdrawOffer()
            assistedSessionID = nil
            assistedEpisode = nil
        }
        pendingAssistedEpisode = nil
    }

    func captureEnded(sessionID: UUID) {
        lastOwnCaptureEnd = uptime()
        callActiveAtOwnStop = detector.activeEpisode != nil
        deferredEnd = nil
        if assistedSessionID == sessionID {
            assistedSessionID = nil
            assistedEpisode = nil
        }
        if let current = offer, current.kind == .end { withdrawOffer() }
    }

    // MARK: - Respostas

    /// Única entrada para gestos explícitos. `offerID` precisa ser o da oferta
    /// vigente: notificação antiga não opera outra chamada nem outra gravação.
    @discardableResult
    func perform(_ action: Action, offerID: UUID?) -> Bool {
        if action == .openReview {
            presentReview()
            return true
        }
        guard let current = offer, current.id == offerID else {
            AppLog.assistance.info("stale action \(action.rawValue, privacy: .public) ignored")
            if let offerID { notifier.removeOffer(id: offerID) }
            return false
        }
        switch (action, current.kind) {
        case (.startNow, .start):
            guard let recorder, recorder.canStartCapture else { return false }
            // Só o texto vai: evento inferido não leva participantes para a
            // sessão (associação de evento exige escolha explícita no Calendar).
            // Vazio continua vazio: data e hora, nunca o campo manual do menu.
            let typed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            handledEpisodes.insert(current.episode)
            withdrawOffer()
            pendingAssistedEpisode = current.episode
            guard recorder.startRecording(origin: .assisted, title: typed, calendarMeeting: nil) != nil else {
                pendingAssistedEpisode = nil
                return false
            }
            AppLog.assistance.info("start confirmed episode=\(current.episode.uuidString, privacy: .public)")
            return true
        case (.decline, .start):
            handledEpisodes.insert(current.episode)
            withdrawOffer()
            AppLog.assistance.info("start declined episode=\(current.episode.uuidString, privacy: .public)")
            return true
        case (.continueRecording, .end):
            withdrawOffer()
            AppLog.assistance.info("end declined; recording continues")
            return true
        case (.stopAndTranscribe, .end):
            guard let recorder, recorder.isRecordingNow,
                  let sessionID = current.sessionID, recorder.activeSessionID == sessionID else {
                withdrawOffer()
                return false
            }
            withdrawOffer()
            recorder.stopRecording(reason: "user_confirmed_assisted_end")
            AppLog.assistance.info("end confirmed")
            return true
        case (.dismissed, _):
            // Fechar o aviso não decide nada: a pergunta continua no menu e
            // nenhum novo aviso é enviado para a mesma condição.
            return true
        default:
            return false
        }
    }

    private func withdrawOffer() {
        guard let current = offer else { return }
        offer = nil
        notifier.removeOffer(id: current.id)
        if current.kind == .start {
            suggestion = nil
            isLookingUpCalendar = false
        }
    }
}
