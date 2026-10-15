import Foundation
import CheckmateCore

/// Explicit, headless live-service acceptance. Never starts microphone capture or speaker output.
@main struct AcceptanceProbe {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3, ["--live-voice","--live-localization","--prepare-downgrade","--verify-downgrade"].contains(CommandLine.arguments[1]),
              ProcessInfo.processInfo.hostName.lowercased().contains("test-host") else {
            print("Run CheckmateAcceptance --live-voice <report.json> on test-host outside silent UI automation.")
            exit(2)
        }
        if CommandLine.arguments[1] == "--live-localization" {
            await localizationProbe(URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        if CommandLine.arguments[1] != "--live-voice" {
            do {try downgradeFixture(URL(fileURLWithPath:CommandLine.arguments[2]),prepare:CommandLine.arguments[1]=="--prepare-downgrade");print("Downgrade fixture: PASS")}catch{print("Downgrade fixture: FAIL");exit(1)}
            return
        }
        guard !NativePolicy.silent else{print("Live voice is disabled during automation.");exit(2)}
        let destination=URL(fileURLWithPath:CommandLine.arguments[2])
        try? FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        var report:[String:Any]=["microphoneUsed":false,"speakerUsed":false,"model":VoiceSessionConfiguration.model,"voice":"cedar","language":"English","humanAcceptance":false]
        do {
            let review=ReviewController(),session=try GameSession(engine:nil)
            let document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *".utf8))[0]
            review.open(document,practice:session);try review.select(document.mainline.last!)
            guard let explanation=review.explanation else {throw CheckmateError.invalid("Missing verified explanation")}
            let segments=try JSONDecoder().decode([SpeechSegment].self,from:JSONSerialization.data(withJSONObject:ReviewVoiceScript.segments(explanation)))
            try ReviewVoiceScript.validate(segments,explanation:explanation)
            let text=segments.prefix(2).map(\.text).joined(separator:" ")
            let gateway=VoiceGateway(),selector=VoiceModelSelection()
            let coachTools=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("voice-tools.json"))) as! [[String:Any]]
            var samples:[[String:Any]]=[]
            // Two independent sessions demonstrate reconnect without sharing stale server state.
            for attempt in 1...2 {
                let effort=attempt==1 ? "minimal":"high"
                let selected=try await selector.resolve(effort:effort){model in try await gateway.supportsCoach(model:model,effort:effort,voice:"cedar",tools:coachTools)}
                report["selectedModel"]=selected;report["automaticSelectionPassed"]=true
                let secret=try await gateway.authorize(model:selected)
                var request=URLRequest(url:VoiceSessionConfiguration.socketURL(model:selected))
                request.setValue("Bearer \(secret)",forHTTPHeaderField:"Authorization")
                let transport=URLSession(configuration:.ephemeral,delegate:gateway,delegateQueue:nil)
                let socket=transport.webSocketTask(with:request);socket.maximumMessageSize=2*1024*1024;socket.resume()
                defer {socket.cancel(with:.normalClosure,reason:nil);transport.invalidateAndCancel()}
                let watchdog=Task {try? await Task.sleep(for:.seconds(35));guard !Task.isCancelled else{return};socket.cancel(with:.goingAway,reason:nil)}
                defer {watchdog.cancel()}
                func send(_ event:[String:Any])async throws {try await socket.send(.string(String(decoding:try JSONSerialization.data(withJSONObject:event),as:UTF8.self)))}
                try await send(VoiceSessionConfiguration.event(instructions:"Response language: English. Read only the supplied verified facts verbatim, without inferred motives.",voice:"cedar",tools:[],effort:effort))
                let scope=UUID().uuidString
                var configured=false,isolated=false,audio=Data(),transcript="",types:Set<String>=[]
                while true {
                    let message=try await socket.receive(),data:Data
                    switch message {case .data(let value):data=value;case .string(let value):data=Data(value.utf8);@unknown default:throw CheckmateError.invalid("Unknown voice message")}
                    guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],let type=event["type"] as? String else{continue}
                    types.insert(type)
                    if type=="error" {throw CheckmateError.unavailable("Live service rejected an event: \((event["error"] as? [String:Any])?["code"] as? String ?? "unknown")")}
                    if type=="session.updated",!configured {
                        guard let returnedSession=event["session"] as? [String:Any],(returnedSession["reasoning"] as? [String:Any])?["effort"] as? String==effort,
                              let resolvedModel=returnedSession["model"] as? String,resolvedModel==selected || resolvedModel.hasPrefix(selected+"-") else{throw CheckmateError.invalid("The provider did not apply the requested coach model and effort")}
                        configured=true
                        try await send(VoiceScriptRequest.event(text:text,language:"English",metadata:["checkmate_probe":scope]))
                    }
                    if type=="response.created" {
                        let response=event["response"] as? [String:Any] ?? [:]
                        guard (response["metadata"] as? [String:String])?["checkmate_probe"]==scope,response["conversation_id"] is NSNull else{throw CheckmateError.invalid("Live voice response lost isolation or scope")}
                        isolated=true
                    }
                    if type=="response.output_audio.delta",let encoded=event["delta"] as? String,let chunk=Data(base64Encoded:encoded){audio.append(chunk)}
                    if type=="response.output_audio_transcript.delta" {transcript += event["delta"] as? String ?? ""}
                    if type=="response.done" {
                        guard (event["response"] as? [String:Any])?["status"] as? String=="completed",configured,isolated,!audio.isEmpty,!transcript.isEmpty else{throw CheckmateError.unavailable("Live voice did not complete with audio and transcript")}
                        break
                    }
                }
                guard VoiceScriptRequest.matches(transcript,script:text) else{report["mismatchedTranscript"]=transcript;report["requestedScript"]=text;throw CheckmateError.unavailable("Live narration changed the verified script or language")}
                // A Stop is acknowledged only by an error naming its own cancel event (VoiceCoach correlates by event_id):
                // the provider must echo it when nothing is left to cancel.
                if attempt==1 {
                    let cancelID="probe-cancel-"+scope;try await send(["type":"response.cancel","event_id":cancelID]);var echoed=false
                    while true {let message=try await socket.receive(),data:Data;switch message{case .data(let value):data=value;case .string(let value):data=Data(value.utf8);@unknown default:continue}
                        guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],event["type"] as? String=="error",let error=event["error"] as? [String:Any] else{continue}
                        echoed=error["code"] as? String=="response_cancel_not_active" && error["event_id"] as? String==cancelID;break}
                    report["cancelErrorEchoesEventID"]=echoed;guard echoed else{throw CheckmateError.unavailable("The provider did not name the cancel event in its error")}
                }
                try audio.write(to:destination.deletingLastPathComponent().appendingPathComponent("live-voice-\(attempt).pcm"),options:.atomic)
                samples.append(["effort":effort,"attempt":attempt,"configured":configured,"isolatedAndScoped":isolated,"audioBytes":audio.count,"transcript":transcript,"requestedVerifiedText":text,"eventTypes":types.sorted()])
            }
            report["samples"]=samples;report["originalHashPreserved"]=review.document?.contentHash==document.contentHash
            // D10: one typed learner turn per language through the production coach (headless audio): required tool
            // calls, a validated speak_explanation, and each segment narrated and verified in that language.
            var turns:[[String:Any]]=[]
            for (language,question) in [("en","Where can my knight on g1 move?"),("zh","我在g1的马可以走到哪里？"),("es","¿A dónde puede ir mi caballo de g1?")] {
                let turn=try await coachTurn(language:language,question:question);turns.append(turn)
                guard turn["passed"] as? Bool==true else{report["coachTurns"]=turns;throw CheckmateError.unavailable("The live coach turn failed in \(language)")}
            }
            report["coachTurns"]=turns
            // D6: the Settings preview in another voice, through its own session, ends by itself and records its usage.
            let preview=try await voicePreview(model:report["selectedModel"] as? String ?? VoiceSessionConfiguration.model);report["preview"]=preview
            guard preview["passed"] as? Bool==true else{throw CheckmateError.unavailable("The voice preview failed")}
            report["passed"]=true
        } catch {
            report["passed"]=false
            // Never serialize request headers, credentials, provider response bodies or raw errors.
            report["failure"]=(error as? CheckmateError)?.description ?? "Live transport failed (\(String(describing:type(of:error))))"
        }
        do {try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.atomic)
        } catch {print("Could not write live acceptance report.");exit(3)}
        print("Live voice acceptance: \(report["passed"] as? Bool==true ? "PASS":"FAIL"); microphone and speaker were not used.")
        if report["passed"] as? Bool != true{exit(1)}
    }
    @MainActor static func voicePreview(model:String)async throws -> [String:Any] {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let preview=VoicePreview(),ledger=UsageLedger(directory:directory);preview.usageLedger=ledger;preview.audio.headless=true
        let started=Date();preview.play(voice:"marin",language:"English",model:model,volume:1)
        let end=Date().addingTimeInterval(30);while preview.playing,Date()<end{try? await Task.sleep(for:.milliseconds(100))}
        let record=ledger.records.first
        let passed = !preview.playing && preview.status.isEmpty && record?.status == .completed && (record?.durationSeconds ?? 0)>0 && record?.voice=="marin"
        return ["passed":passed,"seconds":Date().timeIntervalSince(started),"status":preview.status,"usageStatus":record?.status.rawValue ?? "none","audioSeconds":record?.durationSeconds ?? 0]
    }
    /// A coach connected as in the app, without microphone or speaker, answers one typed question.
    @MainActor static func coachTurn(language:String,question:String)async throws -> [String:Any] {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let session=try GameSession(engine:nil);session.state.settings.coachingMode="quiet";session.state.settings.voiceMicrophone=false;session.state.settings.voiceLanguage=language
        let coach=try VoiceCoach(session:session),ledger=UsageLedger(directory:directory);coach.usageLedger=ledger;coach.audio.headless=true
        defer{coach.disconnect()}
        func wait(_ seconds:Double,_ condition:()->Bool)async -> Bool {let end=Date().addingTimeInterval(seconds);while Date()<end{if condition(){return true};try? await Task.sleep(for:.milliseconds(100))};return condition()}
        let started=Date();coach.connect()
        guard await wait(40,{coach.connected}) else{return ["language":language,"passed":false,"failure":"not connected: \(coach.status)"]}
        coach.ask(question)
        let answered=await wait(120,{!coach.canStopTurn && coach.history.contains{$0.role=="coach"} && !coach.status.hasPrefix("Coach is thinking")})
        let counts=ledger.narrationCounts(),coachLines=coach.history.filter{$0.role=="coach"}.map(\.text)
        let failures:Set<String>=[VoiceCoach.turnFailure,VoiceCoach.turnTimeout,VoiceCoach.turnUnfinished]
        let passed=answered && coach.connected && (counts[.verified] ?? 0)>0 && (counts[.unverified] ?? 0)==0 && !failures.contains(coach.status)
        return ["language":language,"passed":passed,"seconds":Date().timeIntervalSince(started),"model":coach.selectedModel,"verifiedSegments":counts[.verified] ?? 0,"unverifiedSegments":counts[.unverified] ?? 0,"interruptedSegments":counts[.interrupted] ?? 0,"coachTranscript":coachLines,"status":coach.status]
    }
    @MainActor static func downgradeFixture(_ root:URL,prepare:Bool)throws {
        let store=StateStore(directory:root.appendingPathComponent("Data")),reviews=ReviewStore(directory:store.directory.appendingPathComponent("Reviews"))
        let manifest=root.appendingPathComponent("downgrade-fixture.json")
        if prepare {
            var state=ApplicationState();state.settings=AppSettings(raw:["skill":17,"opponentMode":"elo","opponentElo":1800,"coachingMode":"quiet","voiceAutoConnect":false,"voiceMicrophone":false,"narration":false,"moveSounds":false])
            state.course.completed=["intro","board"];state.course.answered=["intro-quiz"]
            let rules=try ChessRules();try rules.move(uci:"e2e4");try rules.move(uci:"e7e5");state.practice.pgn=rules.pgn;state.practice.fen=rules.fen
            try store.save(state)
            let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];var idea=ReviewBranch(root:1);idea.moves=["c7c5"]
            try reviews.save(document,cursor:2,branches:[idea])
            try PGNExporter.withIdeas(document,branches:[idea]).write(to:root.appendingPathComponent("exported-original-and-ideas.pgn"),options:.atomic)
            try FileManager.default.copyItem(at:store.directory,to:root.appendingPathComponent("BeforeDowngrade"))
            try JSONSerialization.data(withJSONObject:["reviewID":document.id.uuidString,"originalHash":document.contentHash,"practicePGN":state.practice.pgn,"skill":17,"elo":1800],options:[.prettyPrinted,.sortedKeys]).write(to:manifest,options:.atomic)
        } else {
            let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any],state=try store.load(),review=try reviews.load(UUID(uuidString:expected["reviewID"] as! String)!)
            guard state.settings.skill==17,state.settings.opponentElo==1800,state.practice.pgn==expected["practicePGN"] as? String,state.course.completed==["intro","board"],review.document.contentHash==expected["originalHash"] as? String,review.cursor==2,review.branches.count==1 else{throw CheckmateError.invalid("Downgrade fixture lost data")}
            guard try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("exported-original-and-ideas.pgn"))).count==2 else{throw CheckmateError.invalid("Export lost an imagined line")}
        }
    }

}
