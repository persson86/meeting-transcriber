import EventKit
import Foundation

struct CalendarMeeting: Equatable, Sendable {
    let title: String
    let startDate: Date
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
}

enum CalendarMeetingSelector {
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

        let endDate = now.addingTimeInterval(24 * 60 * 60)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )
        let candidates = eventStore.events(matching: predicate).compactMap(candidate)
        return CalendarMeetingSelector.next(
            from: candidates,
            now: now,
            endDate: endDate
        )
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

        return CalendarMeetingCandidate(
            title: event.title,
            startDate: startDate,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            participation: participation,
            calendarIdentifier: event.calendar.calendarIdentifier,
            eventIdentifier: event.eventIdentifier ?? ""
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
