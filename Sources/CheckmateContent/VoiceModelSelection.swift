import CheckmateDomain
import CheckmateSupport
import Foundation
import RealtimeConnection

/// Known stable models with the coach's reasoning and tool contract. No guessed IDs.
@MainActor public final class VoiceModelSelection {
    public static let candidates = ["gpt-realtime-2.1", "gpt-realtime-2"]
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    private var cached: (model: String, effort: String, date: Date)?
    public init() {}
    public func resolve(effort: String, refresh: Bool = false, now: Date = Date(),
                        probe: (String) async throws -> Bool) async throws -> String {
        if !refresh, let cached, cached.effort == effort,
           now.timeIntervalSince(cached.date) >= 0,
           now.timeIntervalSince(cached.date) < Self.cacheLifetime { return cached.model }
        for model in Self.candidates {
            try Task.checkCancellation()
            let compatible = try await probe(model)
            try Task.checkCancellation()
            if compatible { cached = (model, effort, now); return model }
        }
        cached = nil
        throw Self.noModel(effort: effort)
    }
    public func invalidate() { cached = nil }
    /// No candidate accepted the effort: above Minimal, the effort is the likelier cause, so it is named.
    nonisolated public static func noModel(effort: String) -> CheckmateError {
        guard effort != "minimal" else { return .unavailable("No supported voice model is available for this account.") }
        let name = effort == "xhigh" ? "Extra high" : effort.capitalized
        return .unavailable("No voice model available to this account supports \(name) reasoning. Choose a lower reasoning effort in Settings → Voice Coach.")
    }
}

extension VoiceGateway {
    /// Silent compatibility probe: no response generation, microphone or speaker.
    public func supportsCoach(model: String, effort: String, voice: String,
                              tools: [[String: Any]]) async throws -> Bool {
        let secret: ClientSecret
        // Only a model the account cannot open is incompatible; an expired sign-in, a missing entitlement or the
        // network is the same for every model, so it stops selection with its own reason.
        do { secret = try await authorize(model: model) }
        catch is ModelUnsupported { try Task.checkCancellation(); return false }
        let socket: VoiceSocket
        do { socket = try await VoiceSocket.open(secret: secret, model: model, handshakeTimeout: 15) }
        catch { try Task.checkCancellation(); return false }
        let deadline = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { await socket.close() } }
        defer { deadline.cancel(); socket.closeSoon() }
        do {
            let event = VoiceSessionConfiguration.event(instructions: "Compatibility check only. Do not generate a response.", voice: voice, tools: tools, effort: effort)
            try await socket.send(event)
            for _ in 0..<16 {
                try Task.checkCancellation()
                let event = try await socket.receive()
                if event["type"] as? String == "error" { return false }
                if event["type"] as? String == "session.updated" {
                    return Self.coachSessionMatches(event, model: model, effort: effort, toolNames: tools.compactMap { $0["name"] as? String })
                }
            }
            return false
        } catch { try Task.checkCancellation(); return false }
    }
    public static func coachSessionMatches(_ event: [String: Any], model: String, effort: String, toolNames: [String]) -> Bool {
        guard let session = event["session"] as? [String: Any],
              let actual = session["model"] as? String,
              actual == model || actual.hasPrefix(model + "-"),
              (session["reasoning"] as? [String: Any])?["effort"] as? String == effort,
              let tools = session["tools"] as? [[String: Any]],
              Set(tools.compactMap { $0["name"] as? String }) == Set(toolNames) else { return false }
        return true
    }
}
