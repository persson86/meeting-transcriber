import XCTest
@testable import MeetingTranscriber

@MainActor
final class VisibleTranscriptionJobsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testKeepsRunningJobVisibleBehindManyFinishedJobs() {
        let running = job(title: "Em andamento", minutesAgo: 90, status: .running)
        let jobs = (1...8).map { index in
            job(title: "Concluída \(index)", minutesAgo: 80 - index, status: .succeeded(url), completedMinutesAgo: 70 - index)
        }

        let visible = AppState.visibleJobs(from: [running] + jobs, finishedLimit: 4)

        XCTAssertEqual(visible.first, running)
        XCTAssertEqual(visible.count, 5)
    }

    func testOrdersActiveJobsByQueuePositionThenFinishedByRecency() {
        let running = job(title: "Rodando", minutesAgo: 30, status: .running)
        let queued = job(title: "Na fila", minutesAgo: 10, status: .queued)
        let older = job(title: "Antiga", minutesAgo: 60, status: .succeeded(url), completedMinutesAgo: 50)
        let newer = job(title: "Recente", minutesAgo: 55, status: .failed("erro"), completedMinutesAgo: 40)

        let visible = AppState.visibleJobs(from: [older, newer, running, queued], finishedLimit: 4)

        XCTAssertEqual(visible.map(\.title), ["Rodando", "Na fila", "Recente", "Antiga"])
    }

    func testDropsFinishedJobsBeyondTheLimit() {
        let jobs = (1...5).map { index in
            job(title: "Concluída \(index)", minutesAgo: 60, status: .succeeded(url), completedMinutesAgo: 60 - index)
        }

        let visible = AppState.visibleJobs(from: jobs, finishedLimit: 3)

        XCTAssertEqual(visible.map(\.title), ["Concluída 5", "Concluída 4", "Concluída 3"])
    }

    private let url = URL(fileURLWithPath: "/tmp/transcricao.md")

    private func job(
        title: String,
        minutesAgo: Int,
        status: TranscriptionJobStatus,
        completedMinutesAgo: Int? = nil
    ) -> TranscriptionJob {
        TranscriptionJob(
            id: UUID(),
            title: title,
            language: "pt",
            micURL: nil,
            systemURL: nil,
            outputDir: URL(fileURLWithPath: "/tmp"),
            sysOffsetMs: 0,
            createdAt: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            startedAt: nil,
            completedAt: completedMinutesAgo.map { now.addingTimeInterval(TimeInterval(-$0 * 60)) },
            status: status
        )
    }
}
