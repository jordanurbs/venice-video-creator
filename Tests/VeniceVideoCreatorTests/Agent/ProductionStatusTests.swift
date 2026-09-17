import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Production status", .serialized)
@MainActor
struct ProductionStatusTests {
    @Test func queuedStatusThroughDispatcher() async throws {
        let h = ToolHarness()
        let shots = (1...3).map { Shot(id: "s\($0)", summary: "Shot", prompt: "A car passes.") }
        for shot in shots { h.editor.upsertShot(shot) }
        let o = h.editor.productionOrchestrator
        o.executeUnit = { _, _ in Issue.record("Paused production must not submit") }
        o.produceShots(ids: shots.map(\.id))
        o.pause()
        defer { o.cancel() }
        let json = try #require(try await h.runOK("production_status") as? [String: Any])
        #expect(json["queuedShotIds"] as? [String] == shots.map(\.id))
        #expect(json["queuedCount"] as? Int == 3)
        #expect(json["pendingCount"] as? Int == 3)
        #expect(json["succeededCount"] as? Int == 0)
        #expect(json["lastError"] is NSNull)
    }

    @Test func failedAndCancelledAreNotSuccesses() async throws {
        let h = ToolHarness()
        for id in ["success", "failure"] {
            h.editor.upsertShot(Shot(id: id, summary: "Shot", prompt: "A car passes."))
        }
        let o = h.editor.productionOrchestrator
        o.executeUnit = { unit, _ in
            for id in unit.shotIds { h.editor.setShotStatus(id: id, id == "success" ? .placed : .failed) }
        }
        o.produceShots(ids: ["success", "failure"])
        for _ in 0..<1000 where o.isRunning { await Task.yield() }
        #expect(!o.isRunning)
        let json = try #require(try await h.runOK("production_status") as? [String: Any])
        #expect(json["succeededCount"] as? Int == 1)
        #expect(json["completedCount"] as? Int == 1)
        #expect(json["failedCount"] as? Int == 1)
        #expect(json["settledCount"] as? Int == 2)
        #expect(json["pendingCount"] as? Int == 0)
        o.produceShots(ids: ["failure"])
        o.pause()
        o.cancel()
        let stopped = try #require(try await h.runOK("production_status") as? [String: Any])
        #expect(stopped["cancelledCount"] as? Int == 1)
        #expect(stopped["succeededCount"] as? Int == 0)
        #expect(stopped["pendingCount"] as? Int == 0)
    }

    @Test func invalidCostCannotEncodeAsSuccessfulEmptyStatus() {
        let status = ProductionStatus(
            isRunning: false, isPaused: false, currentShotId: nil,
            succeededCount: 0, failedCount: 0, cancelledCount: 0, totalCount: 0,
            queuedUnits: [], generatingShotIds: [], runningUSD: .infinity, lastError: nil
        )
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(status) }
    }

    @Test func groupedQueueCountsShotsAndUnitsSeparately() throws {
        let status = ProductionStatus(
            isRunning: true, isPaused: false, currentShotId: nil,
            succeededCount: 1, failedCount: 1, cancelledCount: 1, totalCount: 6,
            queuedUnits: [.init(shotIds: ["a", "b"], reason: "group"), .init(shotIds: ["c"], reason: "single")],
            generatingShotIds: [], runningUSD: 0, lastError: nil
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(json["queuedShotIds"] as? [String] == ["a", "b", "c"])
        #expect(json["queuedCount"] as? Int == 3)
        #expect(json["queuedUnitCount"] as? Int == 2)
        #expect(json["settledCount"] as? Int == 3)
    }
}
