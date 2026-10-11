import Foundation

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
        throw CheckmateError.unavailable("No supported voice model is available for this account.")
    }
    public func invalidate() { cached = nil }
}

extension VoiceGateway {
    /// Silent compatibility probe: no response generation, microphone or speaker.
    public func supportsCoach(model: String, effort: String, voice: String,
                              tools: [[String: Any]]) async throws -> Bool {
        let secret: String
        do { secret = try await authorize(model: model) }
        catch { try Task.checkCancellation(); return false }
        var request = URLRequest(url: VoiceSessionConfiguration.socketURL(model: model))
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let transport = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let socket = transport.webSocketTask(with: request)
        socket.maximumMessageSize = 2 * 1024 * 1024
        socket.resume()
        let deadline = Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil); transport.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                let event = VoiceSessionConfiguration.event(instructions: "Compatibility check only. Do not generate a response.", voice: voice, tools: tools, effort: effort)
                let payload = try JSONSerialization.data(withJSONObject: event)
                try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
                for _ in 0..<16 {
                    try Task.checkCancellation()
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: return false }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                    if event["type"] as? String == "error" { return false }
                    if event["type"] as? String == "session.updated" {
                        return Self.coachSessionMatches(event, model: model, effort: effort, toolNames: tools.compactMap { $0["name"] as? String })
                    }
                }
                return false
            } catch { try Task.checkCancellation(); return false }
        }, onCancel: { socket.cancel(with: .goingAway, reason: nil) })
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
