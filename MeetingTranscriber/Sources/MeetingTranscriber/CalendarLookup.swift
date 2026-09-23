import EventKit
import Foundation

struct CalendarMeeting: Equatable, Sendable, Codable {
    let title: String
    let startDate: Date
    /// Campos opcionais (v1.4): identidade e convidados do evento escolhido.
    /// Convidado não prova presença nem autoria de fala.
    var endDate: Date? = nil
    var eventIdentifier: String? = nil
    var organizerName: String? = nil
    var attendeeNames: [String]? = nil
}

enum CalendarParticipation: Equatable, Sendable {
    case acceptedAttendee
    case currentUserOrganizerWithParticipants
    case ineligible
}

struct CalendarMeetingCandidate: Equatable, Sendable {
    let title: String?
    let startDate: Date
    let isAllDay: Bool
    let isCancelled: Bool
    let participation: CalendarParticipation
    let calendarIdentifier: String
    let eventIdentifier: String
    var endDate: Date? = nil
    /// Mesmo evento em dois calendários (ex.: Exchange + Google) tem o mesmo id externo.
    var externalIdentifier: String? = nil
    var organizerName: String? = nil
    var attendeeNames: [String] = []
}

enum CalendarMeetingSelector {
    /// Eventos mais longos que isso (blocos de foco, dia inteiro disfarçado) não são reunião.
    static let maxMeetingDuration: TimeInterval = 8 * 60 * 60
    static let maxAttendeeNames = 20

    /// Evento para o botão do Calendar: o em andamento ou o próximo, pelo início
    /// mais próximo de agora. Clicar alguns minutos depois do início pega a
    /// reunião atual, não a seguinte; reunião que estourou perde para a que
    /// está começando.
    static func forRecording(
        from candidates: [CalendarMeetingCandidate],
        now: Date,
        horizon: TimeInterval = 24 * 60 * 60
    ) -> CalendarMeeting? {
        var seenExternal = Set<String>()
        let eligible = candidates
            .filter { candidate in
                guard !candidate.isAllDay, !candidate.isCancelled,
                      candidate.participation != .ineligible else { return false }
                let end = candidate.endDate ?? candidate.startDate
                if end.timeIntervalSince(candidate.startDate) > maxMeetingDuration { return false }
                let inProgress = candidate.startDate <= now && end > now
                let upcoming = candidate.startDate >= now && candidate.startDate < now.addingTimeInterval(horizon)
                return inProgress || upcoming
            }
            .sorted { lhs, rhs in
                let lhsDistance = abs(lhs.startDate.timeIntervalSince(now))
                let rhsDistance = abs(rhs.startDate.timeIntervalSince(now))
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return isOrderedBefore(lhs, rhs)
            }
            .filter { candidate in
                guard let external = candidate.externalIdentifier, !external.isEmpty else { return true }
                return seenExternal.insert(external).inserted
            }

        return eligible.first.map { candidate in
            CalendarMeeting(
                title: normalizedTitle(candidate.title),
                startDate: candidate.startDate,
                endDate: candidate.endDate,
                eventIdentifier: candidate.eventIdentifier.isEmpty ? nil : candidate.eventIdentifier,
                organizerName: candidate.organizerName,
                attendeeNames: Array(candidate.attendeeNames.prefix(maxAttendeeNames))
            )
        }
    }

    /// Nomes de exibição limpos: sem e-mail, sem duplicata, sem vazio.
    static func displayNames(_ names: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, !name.contains("@") else { continue }
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    static func next(
        from candidates: [CalendarMeetingCandidate],
        now: Date,
        endDate: Date
    ) -> CalendarMeeting? {
        candidates
            .filter {
                !$0.isAllDay
                    && !$0.isCancelled
                    && $0.participation != .ineligible
                    && $0.startDate >= now
                    && $0.startDate < endDate
            }
            .sorted(by: isOrderedBefore)
            .first
            .map {
                CalendarMeeting(
                    title: normalizedTitle($0.title),
                    startDate: $0.startDate
                )
            }
    }

    private static func isOrderedBefore(
        _ lhs: CalendarMeetingCandidate,
        _ rhs: CalendarMeetingCandidate
    ) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }

        let lhsTitle = normalizedTitle(lhs.title)
        let rhsTitle = normalizedTitle(rhs.title)
        let titleOrder = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        if lhsTitle != rhsTitle {
            return lhsTitle < rhsTitle
        }
        if lhs.calendarIdentifier != rhs.calendarIdentifier {
            return lhs.calendarIdentifier < rhs.calendarIdentifier
        }
        return lhs.eventIdentifier < rhs.eventIdentifier
    }

    private static func normalizedTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Reunião" : trimmed
    }
}

enum CalendarLookupError: LocalizedError {
    case accessDenied
    case accessRestricted

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Acesso ao Calendar não autorizado. Ative o Meeting Transcriber em Configurações do Sistema → Privacidade e Segurança → Calendários."
        case .accessRestricted:
            return "O acesso ao Calendar está restrito neste Mac."
        }
    }
}

actor CalendarLookup {
    private let eventStore = EKEventStore()

    func nextConfirmedMeeting(now: Date = Date()) async throws -> CalendarMeeting? {
        try await ensureCalendarAccess()

        // Inclui eventos já em andamento (começaram até 8 h antes) além das próximas 24 h.
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-CalendarMeetingSelector.maxMeetingDuration),
            end: now.addingTimeInterval(24 * 60 * 60),
            calendars: nil
        )
        let candidates = eventStore.events(matching: predicate).compactMap(candidate)
        return CalendarMeetingSelector.forRecording(from: candidates, now: now)
    }

    private func candidate(from event: EKEvent) -> CalendarMeetingCandidate? {
        guard let startDate = event.startDate else { return nil }

        let attendees = event.attendees ?? []
        let currentUserAccepted = attendees.first(where: \.isCurrentUser)?
            .participantStatus == .accepted
        let organizedByCurrentUserWithParticipants =
            event.organizer?.isCurrentUser == true
                && attendees.contains(where: { !$0.isCurrentUser })

        let participation: CalendarParticipation
        if currentUserAccepted {
            participation = .acceptedAttendee
        } else if organizedByCurrentUserWithParticipants {
            participation = .currentUserOrganizerWithParticipants
        } else {
            participation = .ineligible
        }

        let organizerName = event.organizer?.isCurrentUser == true ? nil : event.organizer?.name
        return CalendarMeetingCandidate(
            title: event.title,
            startDate: startDate,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            participation: participation,
            calendarIdentifier: event.calendar.calendarIdentifier,
            eventIdentifier: event.eventIdentifier ?? "",
            endDate: event.endDate,
            externalIdentifier: event.calendarItemExternalIdentifier,
            organizerName: CalendarMeetingSelector.displayNames([organizerName]).first,
            attendeeNames: CalendarMeetingSelector.displayNames(
                attendees.filter { !$0.isCurrentUser }.map(\.name)
            )
        )
    }

    private func ensureCalendarAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)

        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess:
                return
            case .notDetermined:
                guard try await eventStore.requestFullAccessToEvents() else {
                    throw CalendarLookupError.accessDenied
                }
            case .restricted:
                throw CalendarLookupError.accessRestricted
            case .denied, .writeOnly:
                throw CalendarLookupError.accessDenied
            @unknown default:
                throw CalendarLookupError.accessDenied
            }
        } else {
            switch status {
            case .authorized:
                return
            case .notDetermined:
                guard try await requestLegacyCalendarAccess() else {
                    throw CalendarLookupError.accessDenied
                }
            case .restricted:
                throw CalendarLookupError.accessRestricted
            case .denied:
                throw CalendarLookupError.accessDenied
            default:
                throw CalendarLookupError.accessDenied
            }
        }
    }

    @available(macOS, introduced: 10.0, deprecated: 14.0)
    private func requestLegacyCalendarAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
