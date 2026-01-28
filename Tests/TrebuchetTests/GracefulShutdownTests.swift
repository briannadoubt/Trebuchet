import Testing
import Foundation
@testable import Trebuchet

@Suite("Graceful Shutdown Tests")
struct GracefulShutdownTests {
    // MARK: - Inflight Request Tracker Tests

    @Test("InflightRequestTracker: tracks requests correctly")
    func trackerBasicUsage() async {
        let tracker = InflightRequestTracker()

        #expect(await tracker.count() == 0)

        let callID1 = UUID()
        let callID2 = UUID()

        await tracker.begin(callID: callID1, actorID: "actor-1", method: "test")
        #expect(await tracker.count() == 1)

        await tracker.begin(callID: callID2, actorID: "actor-2", method: "other")
        #expect(await tracker.count() == 2)

        await tracker.complete(callID: callID1)
        #expect(await tracker.count() == 1)

        await tracker.complete(callID: callID2)
        #expect(await tracker.count() == 0)
    }

    @Test("InflightRequestTracker: returns pending requests")
    func trackerPendingRequests() async {
        let tracker = InflightRequestTracker()

        let callID = UUID()
        await tracker.begin(callID: callID, actorID: "actor-1", method: "test")

        let pending = await tracker.pendingRequests()
        #expect(pending.count == 1)
        #expect(pending[0].callID == callID)
        #expect(pending[0].actorID == "actor-1")
        #expect(pending[0].method == "test")
    }

    @Test("InflightRequestTracker: cancelAll clears all requests")
    func trackerCancelAll() async {
        let tracker = InflightRequestTracker()

        await tracker.begin(callID: UUID(), actorID: "actor-1", method: "test1")
        await tracker.begin(callID: UUID(), actorID: "actor-2", method: "test2")
        await tracker.begin(callID: UUID(), actorID: "actor-3", method: "test3")

        #expect(await tracker.count() == 3)

        await tracker.cancelAll()

        #expect(await tracker.count() == 0)
    }

    @Test("InflightRequestTracker: tracks background tasks")
    func trackerBackgroundTasks() async {
        let tracker = InflightRequestTracker()

        let taskID = UUID()
        let task: Task<Void, Never> = Task {
            try? await Task.sleep(for: .seconds(10))
        }

        await tracker.trackBackgroundTask(id: taskID, task: task)
        await tracker.completeBackgroundTask(id: taskID)

        // Task should be removed from tracking
        task.cancel()
    }

    @Test("InflightRequestTracker: statistics provide insights")
    func trackerStatistics() async {
        let tracker = InflightRequestTracker()

        await tracker.begin(callID: UUID(), actorID: "actor-1", method: "test")
        await tracker.begin(callID: UUID(), actorID: "actor-1", method: "test")
        await tracker.begin(callID: UUID(), actorID: "actor-2", method: "other")

        let stats = await tracker.statistics()
        #expect(stats.totalRequests == 3)
        #expect(stats.byActor["actor-1"] == 2)
        #expect(stats.byActor["actor-2"] == 1)
    }

    // MARK: - Server State Tests

    @Test("ServerState enum has all expected cases")
    func serverStateEnumCases() {
        let running: ServerState = .running
        let draining: ServerState = .draining
        let stopped: ServerState = .stopped

        #expect(running != draining)
        #expect(draining != stopped)
        #expect(stopped != running)
    }

    // MARK: - Health Status Tests

    @Test("HealthStatus: healthy state")
    func healthStatusHealthy() {
        let status = HealthStatus(
            status: "healthy",
            timestamp: Date(),
            inflightRequests: 5,
            activeStreams: 3,
            uptime: .seconds(120)
        )

        #expect(status.isHealthy)
        #expect(status.status == "healthy")
        #expect(status.inflightRequests == 5)
        #expect(status.activeStreams == 3)
    }

    @Test("HealthStatus: draining state")
    func healthStatusDraining() {
        let status = HealthStatus(
            status: "draining",
            timestamp: Date(),
            inflightRequests: 2,
            activeStreams: 1,
            uptime: .seconds(300)
        )

        #expect(!status.isHealthy)
        #expect(status.status == "draining")
    }

    @Test("HealthStatus: unhealthy state")
    func healthStatusUnhealthy() {
        let status = HealthStatus(
            status: "unhealthy",
            timestamp: Date(),
            inflightRequests: 0,
            activeStreams: 0,
            uptime: .seconds(0)
        )

        #expect(!status.isHealthy)
        #expect(status.status == "unhealthy")
    }

    @Test("HealthStatus: is Codable")
    func healthStatusCodable() throws {
        let original = HealthStatus(
            status: "healthy",
            timestamp: Date(),
            inflightRequests: 10,
            activeStreams: 5,
            uptime: .seconds(500)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(HealthStatus.self, from: data)

        #expect(decoded.status == original.status)
        #expect(decoded.inflightRequests == original.inflightRequests)
        #expect(decoded.activeStreams == original.activeStreams)
    }

    // MARK: - Request Info Tests

    @Test("RequestInfo: tracks request details")
    func requestInfoTracking() {
        let callID = UUID()
        let startTime = ContinuousClock.Instant.now

        let info = RequestInfo(
            callID: callID,
            startTime: startTime,
            actorID: "test-actor",
            method: "testMethod"
        )

        #expect(info.callID == callID)
        #expect(info.actorID == "test-actor")
        #expect(info.method == "testMethod")
    }

    // MARK: - Request Statistics Tests

    @Test("RequestStatistics: provides metrics summary")
    func requestStatisticsMetrics() {
        let stats = RequestStatistics(
            totalRequests: 10,
            averageDuration: .seconds(2),
            maxDuration: .seconds(5),
            byActor: [
                "actor-1": 6,
                "actor-2": 4
            ]
        )

        #expect(stats.totalRequests == 10)
        #expect(stats.averageDuration == .seconds(2))
        #expect(stats.maxDuration == .seconds(5))
        #expect(stats.byActor["actor-1"] == 6)
        #expect(stats.byActor["actor-2"] == 4)
    }
}
