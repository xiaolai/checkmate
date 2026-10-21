import CheckmateDomain
import CheckmateSupport
import Foundation
import RealtimeConnection

/// Known stable models with the coach's reasoning and tool contract. No guessed IDs.
/// The chosen model is kept for `cacheLifetime` in `storage` (V-22), so a launch connects without probing again; any
/// failure forgets it and the next connect probes afresh.
@MainActor public final class VoiceModelSelection {
    public static let candidates = ["gpt-realtime-2.1", "gpt-realtime-2"]
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    private struct Choice: Codable { let model: String; let effort: String; let date: Date }
    private var cached: Choice?
    /// Where the choice is saved between launches; nil keeps it in memory only.
    public var storage: URL? { didSet { cached = storage.flatMap(Self.load) } }
    public init(storage: URL? = nil) { self.storage = storage; cached = storage.flatMap(Self.load) }
    public func resolve(effort: String, refresh: Bool = false, now: Date = Date(),
                        probe: (String) async throws -> Bool) async throws -> String {
        if !refresh, let cached, cached.effort == effort,
           now.timeIntervalSince(cached.date) >= 0,
           now.timeIntervalSince(cached.date) < Self.cacheLifetime { return cached.model }
        for model in Self.candidates {
            try Task.checkCancellation()
            let compatible = try await probe(model)
            try Task.checkCancellation()
            if compatible { save(Choice(model: model, effort: effort, date: now)); return model }
        }
        invalidate()
        throw Self.noModel(effort: effort)
    }
    public func invalidate() {
        cached = nil
        guard let storage, FileManager.default.fileExists(atPath: storage.path) else { return }
        do { try FileManager.default.removeItem(at: storage) } catch { NativeLog.voice.error("Could not forget the voice model: \(error.localizedDescription, privacy: .public)") }
    }
    private func save(_ choice: Choice) {
        cached = choice
        guard let storage else { return }
        do { try JSONEncoder().encode(choice).write(to: storage, options: .atomic) } catch { NativeLog.voice.error("Could not keep the voice model: \(error.localizedDescription, privacy: .public)") }
    }
    /// A saved choice is trusted only if it decodes and names a known model; anything else is removed and probed again.
    private static func load(_ storage: URL) -> Choice? {
        guard FileManager.default.fileExists(atPath: storage.path) else { return nil }
        do {
            let choice = try JSONDecoder().decode(Choice.self, from: Data(contentsOf: storage))
            if candidates.contains(choice.model) { return choice }
            NativeLog.voice.error("Ignoring a saved voice model that is no longer offered: \(choice.model, privacy: .public)")
        } catch { NativeLog.voice.error("Ignoring a damaged saved voice model: \(error.localizedDescription, privacy: .public)") }
        do { try FileManager.default.removeItem(at: storage) } catch { NativeLog.voice.error("Could not remove the saved voice model: \(error.localizedDescription, privacy: .public)") }
        return nil
    }
    /// No candidate accepted the effort: above Minimal, the effort is the likelier cause, so it is named.
    nonisolated public static func noModel(effort: String) -> VoiceFailure { effort == "minimal" ? .noModel : .thinkingUnsupported }
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
