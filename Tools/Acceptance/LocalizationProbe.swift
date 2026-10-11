import Foundation
import CheckmateCore

private final class LocalizationCleanupEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var result = false
    func record(_ value: Bool) { lock.withLock { result = value } }
    var passed: Bool { lock.withLock { result } }
}

extension AcceptanceProbe {
    /// Explicit opt-in, headless and build-host-only. Translate one lesson and record
    /// one clip; never opens the microphone, speaker or released app's data.
    @MainActor static func localizationProbe(_ destination: URL) async {
        guard !NativePolicy.silent else { print("Live localization is disabled during automation."); exit(2) }
        let root = destination.deletingLastPathComponent(), dataDirectory = root.appendingPathComponent("isolated-data")
        var report: [String: Any] = ["passed": false, "microphoneUsed": false, "speakerUsed": false,
                                   "locale": "zh-Hans", "voice": "cedar", "humanLanguageAcceptance": false]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let initialAuthHash = LessonTranslation.hash(try Data(contentsOf: VoiceGateway.credentialURL))
            let library = try CourseLibrary(), source = LessonTranslation.source(library: library, index: 0)
            let usage = UsageLedger(directory: dataDirectory.appendingPathComponent("Usage"))
            let operation = usage.begin(activity: .translation, provider: "codex", sessionID: UUID().uuidString, locale: "zh-Hans", lessonID: source.lessonID)
            let translated: TranslationResult
            do {
                let cleanup = LocalizationCleanupEvidence()
                translated = try await CodexSubscriptionClient(cleanupObserver: { cleanup.record($0) }).translate(source: source, locale: "zh-Hans", onUsage: { turn, model, tokens in
                    Task { @MainActor in usage.record(operationID: operation, providerID: turn, tokens: tokens, status: .running, cumulative: true, model: model) }
                })
                report["privateAuthRemovedAndChildReaped"] = cleanup.passed
                usage.record(operationID: operation, providerID: translated.turnID, tokens: translated.tokens, status: .completed, cumulative: true,
                             estimatedCredits: translated.estimatedCredits, estimatedUSD: translated.estimatedUSD, model: translated.model)
            } catch { usage.finish(operationID: operation, status: .failed); throw error }
            try translated.text.validate(against: source)
            let packs = try LessonPackStore(directory: dataDirectory)
            try packs.saveTranslation(translated.text, source: source, locale: "zh-Hans")
            report["translationValidated"] = true
            report["isolatedConfigAndNoMCPVerified"] = true
            report["globalAuthUnchanged"] = initialAuthHash == LessonTranslation.hash(try Data(contentsOf: VoiceGateway.credentialURL))
            report["translatedBeats"] = translated.text.beats.count
            report["translationModel"] = translated.model
            report["translationTokens"] = translated.tokens?.total as Any? ?? NSNull()
            report["providerEstimatedCredits"] = translated.estimatedCredits as Any? ?? NSNull()
            guard let beat = translated.text.beats.first else { throw CheckmateError.invalid("No translated beat") }
            let audioOperation = usage.begin(activity: .lessonRecording, provider: "realtime", sessionID: UUID().uuidString,
                                             model: "gpt-realtime", locale: "zh-Hans", voice: "cedar", lessonID: source.lessonID)
            let recording: LessonRecordingResult
            do {
                recording = try await RealtimeLessonRecorder().record(script: beat.speak, locale: "zh-Hans", voice: "cedar", onUsage: { response, tokens in
                    Task { @MainActor in usage.record(operationID: audioOperation, providerID: response, tokens: tokens, status: .running) }
                })
                usage.record(operationID: audioOperation, providerID: recording.responseID, tokens: recording.tokens, status: .running,
                             durationSeconds: Double(recording.pcm.count) / 48_000, model: recording.model)
                _ = try packs.saveClip(pcm: recording.pcm, transcript: recording.transcript, beatID: beat.id, source: source,
                                       locale: "zh-Hans", voice: "cedar", model: recording.model)
                usage.finish(operationID: audioOperation, status: .completed)
            } catch { usage.finish(operationID: audioOperation, status: .failed); throw error }
            report["recordingValidated"] = true
            report["recordingModel"] = recording.model
            report["recordingSeconds"] = Double(recording.pcm.count) / 48_000
            report["recordingTokens"] = recording.tokens?.total as Any? ?? NSNull()
            let reloaded = try LessonPackStore(directory: dataDirectory)
            report["textReloadsOffline"] = try reloaded.translation(source: source, locale: "zh-Hans") == translated.text
            let partial = try reloaded.partialPack(source: source, locale: "zh-Hans", voice: "cedar")
            report["clipReloadsOffline"] = try partial.map { try reloaded.clipURL(pack: $0, beatID: beat.id) != nil } ?? false
            report["partialLessonDoesNotActivate"] = try reloaded.completePack(source: source, locale: "zh-Hans", voice: "cedar") == nil
            try await usage.flush()
            try usage.exportJSON().write(to: root.appendingPathComponent("usage.json"), options: .atomic)
            report["passed"] = report["textReloadsOffline"] as? Bool == true && report["clipReloadsOffline"] as? Bool == true
                && report["partialLessonDoesNotActivate"] as? Bool == true && report["globalAuthUnchanged"] as? Bool == true && report["privateAuthRemovedAndChildReaped"] as? Bool == true
        } catch {
            // All provider failures use bounded user-facing messages; no raw events/auth.
            report["error"] = userFacingMessage(error, fallback: "The live localization check failed.")
        }
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic) }
        catch { print("Could not save localization acceptance report."); exit(3) }
        print("Live localization: \(report["passed"] as? Bool == true ? "PASS" : "FAIL"); microphone and speaker were not used.")
        if report["passed"] as? Bool != true { exit(1) }
    }
}
