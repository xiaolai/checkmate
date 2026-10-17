import Foundation
import CheckmateCore
import SaidGuard

/// Explicit, headless live-service acceptance. Never starts microphone capture or speaker output.
@main struct AcceptanceProbe {
    /// This Mac's roles from ~/.config/checkmate/host-role, the marker scripts/test_host.py reads; empty without one.
    static var hostRoles: Set<String> {
        Set(((try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),
                          encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3, ["--live-voice","--live-localization","--prepare-downgrade","--verify-downgrade"].contains(CommandLine.arguments[1]),
              hostRoles.contains("test") else {
            print("Run CheckmateAcceptance --live-voice <report.json> on the test host outside silent UI automation.")
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
                let socket=try await VoiceSocket.open(secret:secret,model:selected,handshakeTimeout:20)
                defer {socket.closeSoon()}
                let watchdog=Task {try? await Task.sleep(for:.seconds(35));guard !Task.isCancelled else{return};await socket.close()}
                defer {watchdog.cancel()}
                func send(_ event:[String:Any])async throws {try await socket.send(event)}
                try await send(VoiceSessionConfiguration.event(instructions:"Response language: English. Read only the supplied verified facts verbatim, without inferred motives.",voice:"cedar",tools:[],effort:effort))
                let scope=UUID().uuidString
                var configured=false,isolated=false,audio=Data(),transcript="",types:Set<String>=[]
                while true {
                    let event=try await socket.receive()
                    guard let type=event["type"] as? String else{continue}
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
                guard saidMatches(transcript,text,language:"en") else{report["mismatchedTranscript"]=transcript;report["requestedScript"]=text;throw CheckmateError.unavailable("Live narration changed the verified script or language")}
                // A Stop is acknowledged only by an error naming its own cancel event (VoiceCoach correlates by event_id):
                // the provider must echo it when nothing is left to cancel.
                if attempt==1 {
                    let cancelID="probe-cancel-"+scope;try await send(["type":"response.cancel","event_id":cancelID]);var echoed=false
                    while true {let event=try await socket.receive()
                        guard event["type"] as? String=="error",let error=event["error"] as? [String:Any] else{continue}
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
            // Review narration through the production coach: the review's verified facts, each segment narrated and verified.
            let narration=try await reviewNarration();report["reviewNarration"]=narration
            guard narration["passed"] as? Bool==true else{throw CheckmateError.unavailable("Live review narration failed")}
            // Assistance plan A10: a coach connected to the learner's network game at hints answers with that game's tools.
            let network=try await networkCoachTurn();report["networkCoachTurn"]=network
            guard network["passed"] as? Bool==true else{throw CheckmateError.unavailable("The live network-game coach turn failed")}
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
    /// Runs `body` with a usage ledger in a temporary directory, then waits for the ledger's last write before removing
    /// the directory, so a write still queued cannot recreate it afterwards. `body` disconnects what it started.
    @MainActor static func withTemporaryLedger(_ body:@MainActor (UsageLedger)async throws -> [String:Any])async throws -> [String:Any] {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),ledger=UsageLedger(directory:directory)
        do{let result=try await body(ledger);try? await ledger.flush();try? FileManager.default.removeItem(at:directory);return result}
        catch{try? await ledger.flush();try? FileManager.default.removeItem(at:directory);throw error}
    }
    /// Every coach response so far has finished (none still running), and at least one exists.
    @MainActor static func responsesFinished(_ ledger:UsageLedger)->Bool {let coach=ledger.records.filter{$0.activity == .voiceCoach};return !coach.isEmpty && !coach.contains{$0.status == .running}}
    /// Every coach response finished as completed: none failed, was cancelled or was left incomplete.
    @MainActor static func responsesCompleted(_ ledger:UsageLedger)->Bool {responsesFinished(ledger) && ledger.records.filter{$0.activity == .voiceCoach}.allSatisfy{$0.status == .completed}}
    /// Every segment marked verified was heard: its response recorded audio. A transcript alone can match its script
    /// while no audio played, which is not a narration.
    @MainActor static func verifiedWithAudio(_ ledger:UsageLedger)->Bool {let verified=ledger.records.filter{$0.activity == .voiceCoach && $0.narration == .verified};return !verified.isEmpty && verified.allSatisfy{($0.durationSeconds ?? 0)>0}}
    @MainActor static func voicePreview(model:String)async throws -> [String:Any] {try await withTemporaryLedger{ledger in
        let preview=VoicePreview();preview.usageLedger=ledger;preview.audio.headless=true
        // A preview past its deadline is stopped before the ledger is flushed and its directory removed, so it cannot
        // go on working and write there afterwards.
        defer{preview.cancel()}
        let started=Date();preview.play(voice:"marin",language:"English",model:model,volume:1)
        let end=Date().addingTimeInterval(30);while preview.playing,Date()<end{try? await Task.sleep(for:.milliseconds(100))}
        let record=ledger.records.first
        let passed = !preview.playing && preview.status.isEmpty && record?.status == .completed && (record?.durationSeconds ?? 0)>0 && record?.voice=="marin"
        return ["passed":passed,"seconds":Date().timeIntervalSince(started),"status":preview.status,"usageStatus":record?.status.rawValue ?? "none","audioSeconds":record?.durationSeconds ?? 0]
    }}
    /// A coach connected in an open review, as in the app (no microphone or speaker), narrates the selected move's
    /// verified facts: every segment is narrated and verified, none unverified.
    @MainActor static func reviewNarration()async throws -> [String:Any] {try await withTemporaryLedger{ledger in
        let session=try GameSession(engine:nil);session.state.settings.coachingMode="quiet";session.state.settings.voiceMicrophone=false;session.state.settings.voiceLanguage="en"
        let review=ReviewController();session.reviewController=review
        let coach=try VoiceCoach(session:session);coach.usageLedger=ledger;coach.audio.headless=true;coach.attachReview(review)
        defer{coach.disconnect()}
        let document=try PGNImporter.parse(Data("1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 *".utf8))[0]
        review.open(document,practice:session);try review.select(document.mainline.last!)
        guard let explanation=review.explanation else{return ["passed":false,"failure":"no verified explanation"]}
        let expected=ReviewVoiceScript.segments(explanation).count
        @MainActor func wait(_ seconds:Double,_ condition:@MainActor ()->Bool)async -> Bool {let end=Date().addingTimeInterval(seconds);while Date()<end{if condition(){return true};try? await Task.sleep(for:.milliseconds(100))};return condition()}
        let started=Date();coach.connect()
        guard await wait(40,{coach.connected}) else{return ["passed":false,"failure":"not connected in review: \(coach.status)"]}
        coach.narrateReview()
        @MainActor func settled()->Int {let c=ledger.narrationCounts();return (c[.verified] ?? 0)+(c[.unverified] ?? 0)+(c[.interrupted] ?? 0)}
        // Every segment settled and every response behind it done: a last transcript marked verified before its
        // response.done is not yet a pass.
        // Settled is the coach's own idle state, so a cancellation still awaiting acknowledgement is not yet settled.
        let finished=await wait(120,{settled()>=expected && responsesFinished(ledger) && coach.turnIdle})
        let counts=ledger.narrationCounts(),completed=responsesCompleted(ledger),failures:Set<String>=[VoiceCoach.turnFailure,VoiceCoach.turnTimeout,VoiceCoach.turnUnfinished]
        let passed=finished && completed && verifiedWithAudio(ledger) && expected>0 && coach.connected && !failures.contains(coach.status) && (counts[.verified] ?? 0)==expected && (counts[.unverified] ?? 0)==0 && (counts[.interrupted] ?? 0)==0 && review.document?.contentHash==document.contentHash
        return ["passed":passed,"seconds":Date().timeIntervalSince(started),"model":coach.selectedModel,"expectedSegments":expected,"verifiedSegments":counts[.verified] ?? 0,"unverifiedSegments":counts[.unverified] ?? 0,"interruptedSegments":counts[.interrupted] ?? 0,"responsesCompleted":completed,"status":coach.status]
    }}
    /// A coach connected as in the app, without microphone or speaker, answers one typed question.
    @MainActor static func coachTurn(language:String,question:String)async throws -> [String:Any] {try await withTemporaryLedger{ledger in
        let session=try GameSession(engine:nil);session.state.settings.coachingMode="quiet";session.state.settings.voiceMicrophone=false;session.state.settings.voiceLanguage=language
        let coach=try VoiceCoach(session:session);coach.usageLedger=ledger;coach.audio.headless=true
        defer{coach.disconnect()}
        @MainActor func wait(_ seconds:Double,_ condition:@MainActor ()->Bool)async -> Bool {let end=Date().addingTimeInterval(seconds);while Date()<end{if condition(){return true};try? await Task.sleep(for:.milliseconds(100))};return condition()}
        let started=Date();coach.connect()
        guard await wait(40,{coach.connected}) else{return ["language":language,"passed":false,"failure":"not connected: \(coach.status)"]}
        coach.ask(question)
        // Settled means every response is done, not only that Stop is unavailable: Stop is also unavailable while a
        // cancellation awaits its acknowledgement, with the ready status shown before the failure arrives.
        let answered=await wait(120,{coach.turnIdle && responsesFinished(ledger) && coach.history.contains{$0.role=="coach"}})
        let counts=ledger.narrationCounts(),coachLines=coach.history.filter{$0.role=="coach"}.map(\.text),completed=responsesCompleted(ledger)
        let failures:Set<String>=[VoiceCoach.turnFailure,VoiceCoach.turnTimeout,VoiceCoach.turnUnfinished]
        let passed=answered && completed && verifiedWithAudio(ledger) && coach.connected && (counts[.verified] ?? 0)>0 && (counts[.unverified] ?? 0)==0 && (counts[.interrupted] ?? 0)==0 && !failures.contains(coach.status)
        return ["language":language,"passed":passed,"seconds":Date().timeIntervalSince(started),"model":coach.selectedModel,"verifiedSegments":counts[.verified] ?? 0,"unverifiedSegments":counts[.unverified] ?? 0,"interruptedSegments":counts[.interrupted] ?? 0,"responsesCompleted":completed,"coachTranscript":coachLines,"status":coach.status]
    }}
    /// Assistance plan A10: a coach connected to the learner's network game at `hints` (an in-memory LAN, the real
    /// engine) answers a typed question on the learner's own move with the network game's tools only, every segment
    /// narrated and verified, and what it said flags that move as assisted (A7). A second move is asked about with no
    /// engine to hint from, so only the coach's speech can flag it.
    @MainActor static func networkCoachTurn()async throws -> [String:Any] {try await withTemporaryLedger{ledger in
        let scheduler=NetworkManualScheduler(),transport=NetworkMemoryTransport(scheduler:scheduler),discovery=NetworkFixedDiscovery(scheduler:scheduler)
        let services={NetworkServices(transport:transport,discovery:discovery,scheduler:scheduler,delivery:.immediate,rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash),appVersion:"probe",listenersReady:{configuration,endpoints in discovery.publish(configuration.roles.compactMap{role in endpoints[role].map{NetworkServiceRecord.published(configuration,role,at:$0)}})})}
        let fairness=FairnessPolicy(),terms=NetworkAssistance(both:.hints)
        let ana=try NetworkGameController(services:services(),participation:fairness.participation,playerName:"Ana"),ben=try NetworkGameController(services:services(),participation:NetworkParticipation(),playerName:"Ben")
        ana.form.assistance=terms;guard ana.host() else{return ["passed":false,"failure":"the game could not be hosted"]};scheduler.run()
        ben.setShown(true);scheduler.run()
        guard let entry=ben.games.first,let code=ana.playCode,ben.join(entry,code:code.grouped,accepting:terms) else{return ["passed":false,"failure":"the game could not be joined"]};scheduler.run()
        guard fairness.networkAssistance == .hints,ana.yourTurn else{return ["passed":false,"failure":"the game did not start at hints"]}
        let session=try GameSession(engine:nil,fairness:fairness);session.state.settings.voiceMicrophone=false;session.state.settings.voiceLanguage="en"
        // Practice stands elsewhere (1. d4, Black to move), so advice drawn from it could not pass for the network game's.
        try session.playWhite(from:"d2",to:"d4");guard session.rules.fen != ana.rules.fen else{return ["passed":false,"failure":"the practice and network boards match"]}
        let coach=try VoiceCoach(session:session),assistant=NetworkAssistant(game:ana,fairness:fairness,engine:NativeEngine())
        coach.usageLedger=ledger;coach.audio.headless=true;coach.network=(ana,assistant)
        defer{coach.disconnect();ana.leave();scheduler.run()}
        @MainActor func wait(_ seconds:Double,_ condition:@MainActor ()->Bool)async -> Bool {let end=Date().addingTimeInterval(seconds);while Date()<end{if condition(){return true};try? await Task.sleep(for:.milliseconds(100))};return condition()}
        // What reached the model, as sent: each response's instructions (with the board data a turn carries) and each tool
        // result. The network game's position must be in them, and Practice's in none of them.
        var instructions:[String]=[],results:[String]=[]
        coach.requestObserver={event in
            if let text=(event["response"] as? [String:Any])?["instructions"] as? String{instructions.append(text)}
            if let item=event["item"] as? [String:Any],item["type"] as? String=="function_call_output",let output=item["output"] as? String{results.append(output)}
        }
        // A FEN as written in JSON, where a serializer may escape its slashes.
        func mentions(_ text:String,_ fen:String)->Bool {text.contains(fen) || text.contains(fen.replacingOccurrences(of:"/",with:"\\/"))}
        let networkFEN=ana.rules.fen,practiceFEN=session.rules.fen
        let started=Date();coach.connect()
        guard await wait(40,{coach.connected}) else{return ["passed":false,"failure":"not connected: \(coach.status)"]}
        let failures:Set<String>=[VoiceCoach.turnFailure,VoiceCoach.turnTimeout,VoiceCoach.turnUnfinished]
        // One question, settled only once the coach is idle (no cancellation awaiting acknowledgement) and every
        // response behind it is done.
        @MainActor func turn(_ question:String)async -> Bool {
            let before=coach.history.filter{$0.role=="coach"}.count;coach.ask(question)
            return await wait(120,{coach.turnIdle && responsesFinished(ledger) && coach.history.filter{$0.role=="coach"}.count>before})
        }
        let answered=await turn("Use the agreed hint: which move does it suggest here, and why?")
        // The hint is a move for the network game's side to move (White) and impossible on the practice board, where
        // Black moves: it can only have come from a search of the network game's position.
        let hint=assistant.hint,hinted=hint.map{hint in ana.rules.moves().contains{$0.uci==hint.uci} && !session.rules.moves().contains{$0.uci==hint.uci}} ?? false
        let hintAssisted=ana.assistedThisTurn,firstHealthy=coach.connected && !failures.contains(coach.status)
        let boardSent=instructions.contains{mentions($0,networkFEN)},hintReturned=hint.map{hint in results.contains{$0.contains("\"uci\":\"\(hint.uci)\"")}} ?? false
        // Ana plays the hinted move and Ben replies, so Ana's next move begins; that move has no engine to hint from.
        var speechAssisted=false,speechOnly=false
        if let hint,answered {
            ana.play(from:hint.from,to:hint.to);scheduler.run()
            if let reply=ben.rules.moves().first{ben.play(from:reply.from,to:reply.to);scheduler.run()}
            assistant.engine=nil
            if ana.yourTurn,!ana.assistedThisTurn,await turn("Without an engine hint, what is one idea for my move here?") {speechOnly=assistant.hint==nil;speechAssisted=ana.assistedThisTurn}
        }
        let counts=ledger.narrationCounts(),coachLines=coach.history.filter{$0.role=="coach"}.map(\.text),completed=responsesCompleted(ledger)
        let practiceAbsent = !(instructions+results).contains{mentions($0,practiceFEN)}
        let passed=answered && firstHealthy && completed && verifiedWithAudio(ledger) && coach.connected && coach.networkSession && (counts[.verified] ?? 0)>0 && (counts[.unverified] ?? 0)==0 && (counts[.interrupted] ?? 0)==0 && !failures.contains(coach.status) && hintAssisted && hinted && speechOnly && speechAssisted && boardSent && hintReturned && practiceAbsent
        return ["passed":passed,"hintOnlyOnNetworkBoard":hinted,"networkBoardSent":boardSent,"hintResultSent":hintReturned,"practiceBoardAbsent":practiceAbsent,"seconds":Date().timeIntervalSince(started),"model":coach.selectedModel,"networkSession":coach.networkSession,"assistedFlagged":hintAssisted,"speechOnlyTurn":speechOnly,"speechFlaggedAssisted":speechAssisted,"hintShown":hint?.uci ?? NSNull(),"verifiedSegments":counts[.verified] ?? 0,"unverifiedSegments":counts[.unverified] ?? 0,"interruptedSegments":counts[.interrupted] ?? 0,"responsesCompleted":completed,"coachTranscript":coachLines,"status":coach.status]
    }}
    /// What the downgrade fixture records before the downgrade, to compare with what the older app leaves behind. A
    /// malformed manifest fails to decode, which reports the fixture as failed instead of trapping.
    struct DowngradeManifest:Codable {let reviewID:UUID,originalHash:String,practicePGN:String,skill:Int,elo:Int,answered:[String],branchRoot:Int,branchMoves:[String],exportedMoves:[[String]]}
    /// A document's main line as UCI moves, for comparing what was exported with what is read back.
    static func mainlineMoves(_ document:GameDocument)->[String] {document.mainline.compactMap{document.nodes[$0].uci}}
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
            let exported=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("exported-original-and-ideas.pgn"))).map(mainlineMoves)
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(DowngradeManifest(reviewID:document.id,originalHash:document.contentHash,practicePGN:state.practice.pgn,skill:17,elo:1800,answered:state.course.answered,branchRoot:idea.root,branchMoves:idea.moves,exportedMoves:exported)).write(to:manifest,options:.atomic)
        } else {
            let expected=try JSONDecoder().decode(DowngradeManifest.self,from:Data(contentsOf:manifest)),state=try store.load(),review=try reviews.load(expected.reviewID)
            guard state.settings.skill==expected.skill,state.settings.opponentElo==expected.elo,state.practice.pgn==expected.practicePGN,state.course.completed==["intro","board"],state.course.answered==expected.answered,review.document.contentHash==expected.originalHash,review.cursor==2,review.branches.count==1,review.branches[0].root==expected.branchRoot,review.branches[0].moves==expected.branchMoves else{throw CheckmateError.invalid("Downgrade fixture lost data")}
            let exported=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent("exported-original-and-ideas.pgn"))).map(mainlineMoves)
            guard exported.count==2,exported==expected.exportedMoves else{throw CheckmateError.invalid("Export lost an imagined line")}
        }
    }

}
