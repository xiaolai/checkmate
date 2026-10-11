import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform


final class VoiceModelSelectionTests: XCTestCase {
    @MainActor func testNewestCacheRefreshEffortAndExpiry() async throws {
        let selection = VoiceModelSelection(), date = Date(timeIntervalSince1970: 1000)
        var probes: [String] = []
        let first = try await selection.resolve(effort: "minimal", now: date) { probes.append($0); return true }
        XCTAssertEqual(first, "gpt-realtime-2.1")
        let cached = try await selection.resolve(effort: "minimal", now: date.addingTimeInterval(10)) { _ in XCTFail("Cache missed"); return false }
        XCTAssertEqual(cached, first)
        let fallback = try await selection.resolve(effort: "minimal", refresh: true, now: date) { probes.append($0); return $0 == "gpt-realtime-2" }
        XCTAssertEqual(fallback, "gpt-realtime-2")
        _ = try await selection.resolve(effort: "high", now: date) { probes.append($0); return true }
        _ = try await selection.resolve(effort: "high", now: date.addingTimeInterval(VoiceModelSelection.cacheLifetime)) { probes.append($0); return true }
        XCTAssertEqual(probes, ["gpt-realtime-2.1", "gpt-realtime-2.1", "gpt-realtime-2", "gpt-realtime-2.1", "gpt-realtime-2.1"])
        selection.invalidate()
        _ = try await selection.resolve(effort: "high", now: date) { probes.append($0); return true }
        XCTAssertEqual(probes.count, 6)
    }
    @MainActor func testFailuresAndCancellationDoNotCache() async throws {
        let selection = VoiceModelSelection()
        do { _ = try await selection.resolve(effort: "minimal") { _ in false }; XCTFail("Accepted unsupported models") } catch {}
        do { _ = try await selection.resolve(effort: "minimal") { _ in throw CancellationError() }; XCTFail("Swallowed cancellation") } catch is CancellationError {} catch { XCTFail("Wrong error") }
        var probes = 0
        _ = try await selection.resolve(effort: "minimal") { _ in probes += 1; return true }
        XCTAssertEqual(probes, 1)
    }
    func testCompatibilityRequiresModelEffortAndTools() {
        func event(_ model: String = "gpt-realtime-2.1", _ effort: String = "minimal", _ tools: [String] = ["look"]) -> [String: Any] {
            ["session": ["model": model, "reasoning": ["effort": effort], "tools": tools.map { ["name": $0] }]]
        }
        XCTAssertTrue(VoiceGateway.coachSessionMatches(event(), model: "gpt-realtime-2.1", effort: "minimal", toolNames: ["look"]))
        XCTAssertTrue(VoiceGateway.coachSessionMatches(event("gpt-realtime-2.1-2026-10-01"), model: "gpt-realtime-2.1", effort: "minimal", toolNames: ["look"]))
        for invalid in [event("gpt-realtime-2"), event("gpt-realtime-2.10"), event("gpt-realtime-2.1", "low"), event("gpt-realtime-2.1", "minimal", [])] {
            XCTAssertFalse(VoiceGateway.coachSessionMatches(invalid, model: "gpt-realtime-2.1", effort: "minimal", toolNames: ["look"]))
        }
    }
}
