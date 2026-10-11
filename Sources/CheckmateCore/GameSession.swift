import Foundation
import Combine
public struct DemoStepInput:Codable {public var uci:String,explanation:String,arrows:[[String]],highlights:[Highlight];public init(uci:String,explanation:String="",arrows:[[String]]=[],highlights:[Highlight]=[]){self.uci=uci;self.explanation=explanation;self.arrows=arrows;self.highlights=highlights}}
public struct DemoLineInput:Codable {public var label:String,moves:[DemoStepInput];public init(label:String,moves:[DemoStepInput]){self.label=label;self.moves=moves}}
public struct DemoFrame:Codable {public var fen:String,san:String?,uci:String?,explanation:String,arrows:[[String]],highlights:[Highlight],captured:String?,check:Bool,checkmate:Bool}
public struct DemoLine:Codable {public var label:String,frames:[DemoFrame]}
public struct Demonstration:Codable {public var id:String,title:String,introduction:String,lines:[DemoLine],line:Int,ply:Int,playing:Bool}
public struct LineFrame:Codable {public var fen:String,san:String,uci:String}
public struct CandidateEvaluation:Codable {
    public var hypothetical=true
    public var candidate:MoveFacts,recommended:MoveFacts?,exchange:Exchange,rootAnalysis:EngineAnalysis,candidateAnalysis:EngineAnalysis?,candidateScore:AnalysisScore?,lossCp:Int?,comparison:String,candidateFrames:[LineFrame],recommendedFrames:[LineFrame]
}
public struct Exchange:Codable {public var whiteLost:[String]=[],blackLost:[String]=[],moves:[String]=[]}
public struct MoveFacts:Codable {
    public struct Capture:Codable {public let piece:String,square:String}
    public struct RookMove:Codable {public let from:String,to:String}
    public var uci:String,san:String,from:String,to:String,piece:String,color:String,promotion:String?,capture:Capture?,rookMove:RookMove?,before:BoardFacts,after:BoardFacts,fen:String,description:String
}
public struct Threat:Codable {public let from:String,to:String,piece:String,color:String,attacker:String}
public struct BoardFacts:Codable {
    public struct Material:Codable {public var white:Int,black:Int,whiteAdvantage:Int}
    public var turn:String,check:Bool,checkmate:Bool,draw:Bool,material:Material,threats:[Threat],threatSemantics="Geometric attacks; pinned attackers may not have a legal capture."
}
public struct Preview:Codable {public var id:String,basePosition:Int,status:String,candidate:MoveFacts?,evaluation:CandidateEvaluation?,displayFen:String,ply:Int,line:String,error:String?}
public struct Coaching:Codable {public var status="idle",summary="",recommendation:MoveFacts?,analysis:EngineAnalysis?}
public struct LessonProjection:Codable {
    public var mode:String,pieces:Position?,title:String,lessonId:String,step:Int,prompt:String?,choices:[String]?,playing:Bool,narrationActive:Bool,moving:Bool,turn:String?,winner:String?,rules:[String]?
    public var drawReason:String?=nil
}
public func jsonObject<T:Encodable>(_ value:T)->Any {guard let data=try? JSONEncoder().encode(value),let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) else{return NSNull()};return publicJSON(object)}
private func publicJSON(_ raw:Any)->Any {
    if let array=raw as? [Any]{return array.map(publicJSON)}
    guard var object=raw as? [String:Any] else{return raw}
    var nullable:[String]=[]
    if object["before"] != nil,object["after"] != nil,object["description"] != nil{nullable += ["promotion","capture","rookMove"]}
    if object["budgetMs"] != nil,object["lines"] != nil{nullable += ["bestMove"]}
    if object["fen"] != nil,object["explanation"] != nil,object["highlights"] != nil{nullable += ["san","uci","captured"]}
    if object["rootAnalysis"] != nil,object["comparison"] != nil{nullable += ["recommended","candidateAnalysis","candidateScore","lossCp"]}
    if object["basePosition"] != nil,object["displayFen"] != nil{nullable += ["candidate","evaluation","error"]}
    if object["summary"] != nil,object["status"] != nil{nullable += ["recommendation","analysis"]}
    for key in nullable where object[key]==nil{object[key]=NSNull()}
    for (key,value) in object{object[key]=publicJSON(value)}
    return object
}
@MainActor public final class GameSession:ObservableObject {
    public let rules:ChessRules
    public var engine:EngineService?
    @Published public var state:ApplicationState
    @Published public private(set) var mode:NativeMode = .practice
    @Published public private(set) var busy=false
@Published public private(set) var busyReason:String?
@Published public private(set) var message="You play White. Choose a piece to explore."
@Published public private(set) var error:String?
    @Published public private(set) var selected:String?
@Published public private(set) var inspection:PieceInspection?
@Published public private(set) var preview:Preview?
@Published public private(set) var demonstration:Demonstration?
@Published public private(set) var presentationHidden=false
@Published public private(set) var coaching=Coaching()
    @Published public private(set) var highlights:[Highlight]=[]
@Published public private(set) var arrows:[[String]]=[]
@Published public private(set) var voiceFocus:[String]=[]
@Published public private(set) var lesson:LessonProjection?
    public private(set) var sessionId=UUID().uuidString,revision=0,position=0,cursor=0,overlayRevision=0
    public var onPersist:((ApplicationState)->Void)?,onMove:((MoveRecord)->Void)?,onEvent:(()->Void)?,onUndo:(()->Void)?
    public private(set) var companionEnabled=false,companionRole="coach",companionLease:String?,suspended=false,pausedOpponent=false,voiceLease:String?,voiceHold=false
    public weak var reviewController:ReviewController?
    public private(set) var reviewSuspended=false
    private var reviewOwner:(NativeMode,LessonProjection?)?
    public func suspendForReview(){if !reviewSuspended{reviewOwner=(mode,lesson)};reviewSuspended=true;cancelWork();pauseDemo();clearAnnotations();emit(semantic:false)}
    public func returnFromReview(resumeReply:Bool=true){reviewSuspended=false;if let owner=reviewOwner{mode=owner.0;lesson=owner.1};reviewOwner=nil;if resumeReply{explicitResumeRequired=false};emit(semantic:false);if resumeReply && mode == .practice{reply()}}
    /// Plan rule 4: a practice reply suspended by a failed review entry resumes only on an explicit Return to game.
    /// While set, every reply entry point (voice hold/close, connection, settings, presentation, retry, companion
    /// commits) is refused. It is independent of `pausedOpponent` and is cleared only by an explicit return
    /// (`returnFromReview(resumeReply:true)`, `resumePractice`) or a deliberate position/owner change
    /// (new game, restore, import, practice fork, undo, lesson), so no stale pause survives a changed game.
    /// `publicState()` reports it as `controller.paused=true` with `pauseReason="review_restore_failed"`, which takes
    /// priority over the other reasons because only an explicit Return to game can clear it.
    @Published public private(set) var explicitResumeRequired=false
    /// Holds a pending practice reply for an explicit resume; returns whether one was waiting.
    @discardableResult public func requireExplicitResume()->Bool {cancelWork();explicitResumeRequired=mode == .practice && lesson==nil && !reviewSuspended && rules.turn==opponentSide && !rules.over;emit(semantic:false);return explicitResumeRequired}
    private var shuttingDown=false
    public func prepareShutdown(){shuttingDown=true;cancelWork();clearAnnotations();demoTask?.cancel()}
    private var work:Task<Void,Never>?,overlayTask:Task<Void,Never>?,demoTask:Task<Void,Never>?,generation=0
    public init(engine:EngineService?,state:ApplicationState=ApplicationState()) throws {
        self.engine=engine;self.state=state;rules=try ChessRules()
        if !state.practice.pgn.isEmpty {try rules.restore(state.practice.pgn)}
        companionRole=state.settings.companionRole;coaching.summary=turnSummary()
    }
    public var humanSide:String {state.settings.practiceSide}
    public var opponentSide:String {humanSide=="w" ? "b":"w"}
    public static func validatePracticeFork(_ fork:ChessRules,side:String)throws {guard ["w","b"].contains(side),!fork.over else{throw CheckmateError.invalid("Terminal position cannot start practice.")}}
    public func installPracticeFork(_ fork:ChessRules,side:String)throws {try Self.validatePracticeFork(fork,side:side);cancelWork();if holdsGame{state.practice.previousGame=rules.pgn;state.practice.previousSide=humanSide};try rules.restore(fork.pgn);state.settings.practiceSide=side;state.settings.opponentRandomSeed="";state.practice.beginnerSevereStreak=0;reviewSuspended=false;pausedOpponent=false;mode = .practice;lesson=nil;changedPosition();message="You play \(side=="w" ? "White":"Black").";reply()}
    public var positionId:String {sessionId+":"+String(position)}
    public var displayFen:String? {if let review=reviewController,review.active{return review.displayFEN};guard mode == .practice else{return nil};if !presentationHidden,let d=demonstration{return d.lines[d.line].frames[d.ply].fen};if !presentationHidden,let p=preview{return p.displayFen};return rules.fen}
    public var displayIdentity:String {
        if let review=reviewController,review.active{return review.identity}
        let suffix:String
        if mode != .practice {suffix="lesson"}else if !presentationHidden,let d=demonstration{suffix="\(d.id):\(d.line):\(d.ply)"}else if !presentationHidden,let p=preview{suffix="\(p.id):\(p.line):\(p.ply)"}else{suffix="game"}
        return positionId+":"+suffix
    }
    public var displayBoard:Position {if let review=reviewController,review.active{return review.board};if mode != .practice{return lesson?.pieces ?? [:]};if displayFen==rules.fen{return rules.board};return (try? ChessRules(fen:displayFen).board) ?? [:]}
    public var displayView:String {if let review=reviewController,review.active{return review.branch==nil ? "review":"review_preview"};return mode != .practice ? "lesson":!presentationHidden && demonstration != nil ? "demonstration":!presentationHidden && preview != nil ? "preview":"game"}
    public var destinations:[String] {inspection?.destinations ?? []}
    /// Any change to the effective opponent profile (including a preset-only change) cancels a stale pending reply.
    public func updateSettings(_ value:AppSettings,restartOpponent:Bool=true) {let old=state.settings;state.settings=value;companionRole=value.companionRole;if old.skill != value.skill || old.opponentMode != value.opponentMode || old.opponentElo != value.opponentElo || OpponentProfile.settings(old) != OpponentProfile.settings(value) {cancelWork();if restartOpponent{reply()}};if old.coachingMode != value.coachingMode {voiceHold=false};emit(semantic:false,save:true)}
    private var eventWaiters:[UUID:CheckedContinuation<Void,Never>]=[:]
    private var eventTimeouts:[UUID:Task<Void,Never>]=[:]
    private func finishWait(_ id:UUID){eventTimeouts.removeValue(forKey:id)?.cancel();eventWaiters.removeValue(forKey:id)?.resume()}
    public func waitForEvent(until deadline:Date) async {let id=UUID();await withTaskCancellationHandler(operation:{await withCheckedContinuation{continuation in if Task.isCancelled{continuation.resume();return};eventWaiters[id]=continuation;eventTimeouts[id]=Task{try? await Task.sleep(nanoseconds:UInt64(max(0,deadline.timeIntervalSinceNow)*1_000_000_000));finishWait(id)}}},onCancel:{Task{@MainActor in self.finishWait(id)}})}
    public func emit(semantic:Bool=true,save:Bool=false){if semantic{revision+=1;cursor+=1};objectWillChange.send();if save {state.practice.pgn=rules.pgn;state.practice.fen=rules.fen;onPersist?(state)};let ids=Array(eventWaiters.keys);for id in ids{finishWait(id)};onEvent?()}
    public func signalEvent(){cursor+=1;emit(semantic:false)}
    public func cancelWork(){if coaching.status=="thinking"{coaching.status="idle";signalEvent()};generation+=1;work?.cancel();work=nil;busy=false;busyReason=nil}
    private func changedPosition(){cancelWork();explicitResumeRequired=false;position+=1;clearPresentation();clearAnnotations();selected=nil;inspection=nil;error=nil;coaching=Coaching();coaching.summary=turnSummary();emit(save:true)}
    /// `legalNow` is true only when a click on a dot plays: the learner's own piece, on the learner's turn, on the
    /// live board. The opponent's moves, moves while Stockfish thinks and imagined boards show as possibilities.
    private func learnerInspection(_ sq:String,on board:ChessRules,live:Bool)->PieceInspection? {
        guard let i=try? board.inspect(sq) else{return nil}
        let playable=live && i.legalNow && i.color==humanSide && !rules.over
        guard playable != i.legalNow else{return i}
        let note = !live ? "This board shows imagined moves. Dots show where this piece could go there.":i.color != humanSide ? "Dots show the opponent’s possible moves. You play \(humanSide=="w" ? "White":"Black").":i.note
        return PieceInspection(square:i.square,piece:i.piece,color:i.color,attacks:i.attacks,destinations:i.destinations,legalNow:false,note:note)
    }
    public func select(_ sq:String) throws {
        guard mode == .practice else{return};guard ChessRules.validSquare(sq) else{return};if rules.over{try inspectPiece(sq);return}
        if !presentationHidden,(demonstration != nil || preview?.candidate != nil) {let display=try ChessRules(fen:displayFen);selected=sq;inspection=learnerInspection(sq,on:display,live:false);emit(semantic:false);return}
        if let from=selected,inspection?.legalNow==true,destinations.contains(sq) {
            if !presentationHidden,preview != nil {cancelWork();work=Task{try? await self.testMove(from:from,to:sq)}}else{try playWhite(from:from,to:sq)};return
        }
        // A possible move of the learner's own piece waits for the learner's turn instead of selecting another square.
        if selected != nil,rules.turn==opponentSide,let i=inspection,!i.legalNow,i.color==humanSide,destinations.contains(sq) {message="Wait for the opponent’s move, then play this move.";emit(semantic:false);return}
        selected=sq;inspection=learnerInspection(sq,on:rules,live:true);if let i=inspection {message=i.note};emit(semantic:false)
    }
    /// Selects for explanation only; never plays a move or changes a preview.
    public func inspectPiece(_ sq:String) throws {
        guard mode == .practice,ChessRules.validSquare(sq) else{return}
        let display=try ChessRules(fen:displayFen)
        selected=sq;inspection=learnerInspection(sq,on:display,live:displayView=="game");emit(semantic:false)
    }
    public func clearSelection(){selected=nil;inspection=nil;emit(semantic:false)}
    public func playWhite(from:String,to:String,promotion:String="q") throws {
        guard !reviewSuspended,mode == .practice,rules.turn==humanSide,busyReason != "opponent",!rules.over,(presentationHidden || preview==nil && demonstration==nil) else{throw CheckmateError.invalid("ROLE_FORBIDDEN")}
        let move=try rules.move(from,to,promotion);changedPosition();onMove?(move);reply()
    }
    public func commitBlack(_ uci:String) throws -> MoveRecord {guard !reviewSuspended,!explicitResumeRequired,rules.turn==opponentSide else{throw CheckmateError.stale};let kept=selected;let m=try rules.move(uci:uci);changedPosition();if let kept,rules.piece(kept)?.color==humanSide{selected=kept;inspection=learnerInspection(kept,on:rules,live:true)};onMove?(m);message=turnSummary();scheduleGuidance();return m}
    public func reply(){guard !shuttingDown,!reviewSuspended,!explicitResumeRequired,mode == .practice,rules.turn==opponentSide,!rules.over,!busy,!voiceHold,!pausedOpponent,!suspended,(presentationHidden || (preview==nil && demonstration==nil)),(!companionEnabled || companionRole != "opponent"),let engine=engine else{return}
        if state.settings.opponentRandomSeed.isEmpty{state.settings.opponentRandomSeed=String(UInt64.random(in:1...UInt64.max),radix:16);emit(semantic:false,save:true)}
        let seed=UInt64(reviewHash(Data((state.settings.opponentRandomSeed+rules.fen).utf8)).prefix(16),radix:16) ?? 1
        let fen=rules.fen,epoch=generation;busy=true;busyReason="opponent";emit(semantic:false)
        work=Task {[weak self] in guard let self=self else{return};do{let result:EngineAnalysis
            if let native=engine as? NativeEngine {let profile=OpponentProfile.settings(self.state.settings);if profile.mode=="beginner"{result=try await BeginnerOpponent.choose(rules:self.rules,engine:native,seed:seed,severeStreak:self.state.practice.beginnerSevereStreak)}else{let start=self.rules.records.first?.before ?? fen;result=try await native.analyzeHistory(startFEN:start,moves:self.rules.records.map(\.uci),profile:profile,budget:500,multiPv:1)}}else{let profile=OpponentProfile.settings(self.state.settings);result=try await engine.analyze(fen:fen,skill:profile.mode=="skill" ? profile.value:self.state.settings.skill,budget:500,multiPv:1)};try Task.checkCancellation();guard self.generation==epoch,self.rules.fen==fen else{return};self.busy=false;self.busyReason=nil;if let move=result.bestMove {if OpponentProfile.settings(self.state.settings).mode=="beginner"{self.state.practice.beginnerSevereStreak=BeginnerOpponent.nextSevereStreak(result,mover:self.rules.turn,current:self.state.practice.beginnerSevereStreak)}else{self.state.practice.beginnerSevereStreak=0};_ = try self.commitBlack(move)}}catch{if self.generation==epoch {self.busy=false;self.busyReason=nil;self.error="Stockfish could not respond. Retry, undo, or start a new game.";self.emit(semantic:false)}}}
    }
    public func retryEngine(){error=nil;if rules.turn==humanSide{hint()}else{reply()}}
    public func undo(){guard !reviewSuspended,mode == .practice else{return};cancelWork();state.practice.beginnerSevereStreak=0;rules.undo();if rules.turn==opponentSide{rules.undo()};changedPosition();message="Move taken back.";onUndo?();reply()}
    private static let standardStart="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    private var holdsGame:Bool {!rules.history.isEmpty || rules.fen != Self.standardStart}
    public func newGame(){guard !reviewSuspended,mode == .practice else{return};if holdsGame{state.practice.previousGame=rules.pgn;state.practice.previousSide=humanSide};rules.reset();state.settings.practiceSide="w";state.settings.opponentRandomSeed="";state.practice.beginnerSevereStreak=0;pausedOpponent=false;error=nil;changedPosition();message="You play White. Start by making room for your pieces."}
    /// Swaps the current and previous games, each with the side the learner played, so neither is lost.
    public func restorePrevious() throws {
        guard !reviewSuspended,mode == .practice,!state.practice.previousGame.isEmpty else{return}
        let previous=state.practice.previousGame,previousSide=state.practice.previousSide,current=holdsGame ? rules.pgn:"",currentSide=humanSide
        try rules.restore(previous)
        state.practice.previousGame=current;state.practice.previousSide=currentSide;state.settings.practiceSide=previousSide;state.settings.opponentRandomSeed="";state.practice.beginnerSevereStreak=0;pausedOpponent=false
        changedPosition();message="You play \(previousSide=="w" ? "White":"Black").";reply()
    }
    public func continueWithStockfish(){pausedOpponent=false;emit();reply()}
    public func installImportedState(_ imported:ApplicationState)throws {try StateStore.validate(imported);let validated=try ChessRules();if !imported.practice.pgn.isEmpty{try validated.restore(imported.practice.pgn)};cancelWork();try rules.restore(validated.pgn);state=imported;companionRole=imported.settings.companionRole;pausedOpponent=false;mode = .practice;lesson=nil;changedPosition();reply()}
    public func resumePractice(){mode = .practice;lesson=nil;changedPosition();reply()}
    public func setLesson(_ projection:LessonProjection){cancelWork();explicitResumeRequired=false;let changed=mode == .practice || lesson?.lessonId != projection.lessonId || lesson?.step != projection.step || lesson?.pieces != projection.pieces || lesson?.mode != projection.mode || lesson?.moving != projection.moving || lesson?.turn != projection.turn;if let old=lesson,NSDictionary(dictionary:jsonObject(old) as! [String:Any]).isEqual(to:jsonObject(projection) as! [String:Any]),mode != .practice{return};mode=projection.mode=="quick_puzzle" ? .puzzles:.lesson;lesson=projection;if changed{position+=1;clearAnnotations();clearPresentation()};emit(semantic:true)}
    public func setConnection(enabled:Bool,role:String,lease:String?=nil,suspended:Bool=false){let ownershipChanged=companionEnabled != enabled || companionRole != role || self.suspended != suspended; if ownershipChanged {cancelWork();clearAnnotations()};if companionRole=="opponent",companionEnabled,(!enabled || companionLease != nil && lease==nil){pausedOpponent=true};companionEnabled=enabled;companionRole=role;companionLease=lease;if enabled,role=="opponent",lease != nil{pausedOpponent=false};self.suspended=suspended;emit();if !pausedOpponent{reply()}}
    public func openVoice() throws -> String {let reviewing=reviewController?.active==true;guard (!reviewing || ReviewRolloutPolicy.reviewVoiceEnabled),(mode == .practice || reviewing),!companionEnabled else{throw CheckmateError.invalid("SESSION_IN_USE")};voiceLease=UUID().uuidString;return voiceLease!}
    public func closeVoice(){voiceLease=nil;voiceHold=false;voiceFocus=[];emit(semantic:false);reply()}
    public func holdVoice(_ value:Bool){voiceHold=value;emit(semantic:false);if !value{reply()}}
    public func setVoiceFocus(_ sq:[String],identity:String){guard identity==displayIdentity else{return};voiceFocus=sq.filter(ChessRules.validSquare);emit(semantic:false)}
    public func clearAnnotations(){overlayTask?.cancel();overlayTask=nil;highlights=[];arrows=[];voiceFocus=[];overlayRevision+=1}
    public func annotate(arrows:[[String]],highlights:[Highlight],ttl:Int=15000){clearAnnotations();self.arrows=arrows;self.highlights=highlights;emit(semantic:false);let epoch=overlayRevision;overlayTask=Task{try? await Task.sleep(nanoseconds:UInt64(ttl)*1_000_000);guard !Task.isCancelled,self.overlayRevision==epoch else{return};self.clearAnnotations();self.emit(semantic:false)}}
    private func clearPresentation(){demoTask?.cancel();demoTask=nil;if preview != nil || demonstration != nil{selected=nil;inspection=nil};preview=nil;demonstration=nil;presentationHidden=false}
    public func closePresentation(){cancelWork();clearPresentation();clearAnnotations();emit();reply()}
    public func selectPresentation(_ show:Bool){if presentationHidden==show{selected=nil;inspection=nil};presentationHidden = !show;if !show{pauseDemo()};clearAnnotations();emit(semantic:false);if !show{reply()}}
    public func demonstrate(title:String,introduction:String,lines:[DemoLineInput],autoplay:Bool=false) throws {
        guard mode == .practice,preview==nil,demonstration==nil else{throw CheckmateError.invalid("PRESENTATION_ACTIVE")}
        guard !title.isEmpty,title.count<=80,lines.count>0,lines.count<=3,lines.allSatisfy({!$0.label.isEmpty && $0.label.count<=60 && !$0.moves.isEmpty && $0.moves.count<=12}) else{throw CheckmateError.invalid("INVALID_ARGUMENT")}
        let built=try lines.map {line -> DemoLine in let g=try rules.copy();var frames=[DemoFrame(fen:g.fen,san:nil,uci:nil,explanation:introduction,arrows:[],highlights:[],captured:nil,check:g.check,checkmate:g.checkmate)]
            for step in line.moves {guard !g.over else{throw CheckmateError.invalid("INVALID_MOVE")};let m=try g.move(uci:step.uci);frames.append(DemoFrame(fen:g.fen,san:m.san,uci:m.uci,explanation:step.explanation,arrows:step.arrows.isEmpty ? [[m.from,m.to]]:step.arrows,highlights:step.highlights,captured:m.captured,check:g.check,checkmate:g.checkmate))};return DemoLine(label:line.label,frames:frames)}
        cancelWork();clearAnnotations();selected=nil;inspection=nil;presentationHidden=false;demonstration=Demonstration(id:UUID().uuidString,title:title,introduction:introduction,lines:built,line:0,ply:0,playing:false);emit();if autoplay{playDemo()}
    }
    public func seekDemo(line:Int,ply:Int) throws {guard var d=demonstration,d.lines.indices.contains(line),d.lines[line].frames.indices.contains(ply) else{throw CheckmateError.invalid("INVALID_ARGUMENT")};demoTask?.cancel();d.line=line;d.ply=ply;d.playing=false;demonstration=d;clearAnnotations();emit(semantic:false);cursor+=1}
    public func pauseDemo(){demoTask?.cancel();if demonstration != nil {demonstration!.playing=false;emit(semantic:false)}}
    public func playDemo(){guard demonstration != nil,!presentationHidden else{return};if demonstration!.ply==demonstration!.lines[demonstration!.line].frames.count-1{demonstration!.ply=0};demonstration!.playing=true;demoTask?.cancel();demoTask=Task{while !Task.isCancelled,self.demonstration?.playing==true {try? await Task.sleep(nanoseconds:1_500_000_000);guard !Task.isCancelled,var d=self.demonstration else{return};d.ply=min(d.ply+1,d.lines[d.line].frames.count-1);d.playing=d.ply<d.lines[d.line].frames.count-1;self.demonstration=d;self.clearAnnotations();self.cursor+=1;self.emit(semantic:false)}}}
    public func beginPreview() throws {guard mode == .practice,rules.turn==humanSide,!rules.over,demonstration==nil else{throw CheckmateError.invalid("ROLE_FORBIDDEN")};cancelWork();selected=nil;inspection=nil;preview=Preview(id:UUID().uuidString,basePosition:position,status:"choosing",candidate:nil,evaluation:nil,displayFen:rules.fen,ply:0,line:"candidate",error:nil);presentationHidden=false;emit()}
    public func testMove(from:String,to:String,promotion:String="q") async throws {
        guard preview != nil,preview!.basePosition==position else{throw CheckmateError.stale}
        let facts=try moveFacts(rules,uci:from+to+(promotion=="q" && !rules.moves(from).contains(where:{$0.to==to && $0.promotion != nil}) ? "":promotion)),epoch=position
        let staged=UUID().uuidString;preview=Preview(id:staged,basePosition:position,status:"analyzing",candidate:facts,evaluation:nil,displayFen:facts.fen,ply:1,line:"candidate",error:nil);selected=nil;inspection=nil;emit()
        do{let evaluation=try await evaluateCandidate(from:from,to:to,promotion:promotion);guard epoch==position,preview?.id==staged,!Task.isCancelled else{return};preview!.evaluation=evaluation;preview!.status="ready";signalEvent()}catch{guard epoch==position,preview?.id==staged else{return};preview!.status="error";preview!.error="Analysis is unavailable. This legal test move has not been played.";signalEvent()}
    }
    public func previewAt(ply:Int,line:String) throws {guard var p=preview,let e=p.evaluation else{throw CheckmateError.invalid("PREVIEW_NOT_READY")};let frames=line=="candidate" ? e.candidateFrames:e.recommendedFrames;guard frames.indices.contains(ply),["candidate","recommended"].contains(line) else{throw CheckmateError.invalid("INVALID_ARGUMENT")};p.displayFen=frames[ply].fen;p.ply=ply;p.line=line;preview=p;clearAnnotations();cursor+=1;emit(semantic:false)}
    public func playCandidate() throws {guard let candidate=preview?.candidate else{return};closePresentation();try playWhite(from:candidate.from,to:candidate.to,promotion:candidate.promotion ?? "q")}
    public func analyze(budget:Int=350,multiPv:Int=3) async throws -> EngineAnalysis {guard let e=engine else{throw CheckmateError.unavailable("ENGINE_UNAVAILABLE")};let fen=rules.fen,epoch=position;let a=try await e.analyze(fen:fen,skill:20,budget:budget,multiPv:multiPv);guard epoch==position,!Task.isCancelled else{throw CheckmateError.stale};return a}
    public func hint(){guard !busy,mode == .practice,rules.turn==humanSide,!rules.over else{return};cancelWork();let epoch=generation;busy=true;busyReason="analysis";coaching.status="thinking";emit(semantic:false);work=Task{do{let a=try await self.analyze();try Task.checkCancellation();guard self.generation==epoch else{return};self.busy=false;self.busyReason=nil;guard let uci=a.lines.first?.pv.first ?? a.bestMove else{throw CheckmateError.unavailable("No hint returned")};let facts=try self.moveFacts(self.rules,uci:uci);self.coaching.status="ready";self.coaching.recommendation=facts;self.coaching.analysis=a;self.message=facts.description;self.signalEvent();self.annotate(arrows:[[facts.from,facts.to]],highlights:[Highlight(sq:facts.from,kind:"focus")])}catch{guard self.generation==epoch,!Task.isCancelled else{return};self.busy=false;self.busyReason=nil;self.coaching.status="error";self.error="A hint is unavailable. Please try again.";self.signalEvent()}}}
    private func scheduleGuidance(){guard state.settings.coachingMode=="guided",voiceLease==nil,!(companionEnabled && companionRole=="opponent"),rules.turn==humanSide,!rules.over else{return};hint()}
    public func boardFacts(_ r:ChessRules)->BoardFacts {
        let values=["p":1,"n":3,"b":3,"r":5,"q":9,"k":0];var white=0,black=0,threats:[Threat]=[]
        for (sq,p) in r.board {let color=String(p.prefix(1)),kind=String(p.suffix(1));if color=="w"{white+=values[kind] ?? 0}else{black+=values[kind] ?? 0};for from in r.attackers(sq,color=="w" ? "b":"w") {threats.append(Threat(from:from,to:sq,piece:kind,color:color,attacker:r.piece(from)?.type ?? ""))}}
        return BoardFacts(turn:r.turn,check:r.check,checkmate:r.checkmate,draw:r.draw,material:.init(white:white,black:black,whiteAdvantage:white-black),threats:threats.sorted{$0.to<$1.to})
    }
    public func moveFacts(_ r:ChessRules,uci:String) throws -> MoveFacts {
        let g=try r.copy(),m=try g.move(uci:uci),ep=m.flags.contains("e"),castle=m.flags.contains("k")||m.flags.contains("q"),names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
        let captured=m.captured.map{MoveFacts.Capture(piece:$0,square:ep ? String(m.to.prefix(1))+String(m.from.suffix(1)):m.to)}
        let rook=castle ? MoveFacts.RookMove(from:(m.flags.contains("k") ? "h":"a")+String(m.from.suffix(1)),to:(m.flags.contains("k") ? "f":"d")+String(m.from.suffix(1))):nil
        let description=(names[m.piece] ?? "piece").capitalized+" \(m.from) to \(m.to)"+(captured.map{", capturing the \(names[$0.piece] ?? $0.piece) on \($0.square)"} ?? "")+"."+(rook.map{" Castling also moves the rook from \($0.from) to \($0.to)."} ?? "")+(m.promotion.map{" Promotes to a \(names[$0] ?? $0)."} ?? "")+(g.checkmate ? " Checkmate.":g.check ? " Gives check.":"")
        return MoveFacts(uci:m.uci,san:m.san,from:m.from,to:m.to,piece:m.piece,color:m.color,promotion:m.promotion,capture:captured,rookMove:rook,before:boardFacts(r),after:boardFacts(g),fen:g.fen,description:description)
    }
    public func turnSummary()->String {if rules.checkmate{return "Checkmate. The game is over."};if rules.draw{return "The game is drawn."};guard let last=rules.records.last else{return "Choose a piece to explore, or try a move before playing it."};return "\(last.color=="b" ? "Black":"White") played \(last.san)."+(rules.check ? " Your king is in check.":"")}
    public func lineFrames(_ r:ChessRules,moves:[String]) throws -> [LineFrame] {let g=try r.copy();var frames=[LineFrame(fen:g.fen,san:"Current position",uci:"")];for uci in moves.prefix(7){guard let m=try? g.move(uci:uci) else{break};frames.append(LineFrame(fen:g.fen,san:m.san,uci:m.uci))};return frames}
    public func evaluateCandidate(from:String,to:String,promotion:String="q") async throws -> CandidateEvaluation {
        guard rules.turn==humanSide,!rules.over else{throw CheckmateError.invalid("ROLE_FORBIDDEN")}
        let base=try rules.copy(),epoch=position,m=try base.copy().move(from,to,promotion),candidate=try moveFacts(base,uci:m.uci),after=try base.copy();try after.move(uci:m.uci)
        let root=try await analyze(),reply=after.over ? nil:try await engine?.analyze(fen:after.fen,skill:20,budget:350,multiPv:2)
        guard position==epoch,!Task.isCancelled else{throw CheckmateError.stale}
        let best=root.lines.first?.pv.first ?? root.bestMove,recommended=try best.map{try moveFacts(base,uci:$0)},rootScore=root.lines.first?.score
        let score=root.lines.first(where:{$0.pv.first==candidate.uci})?.score ?? reply?.lines.first?.score ?? (after.checkmate ? AnalysisScore(kind:"mate",value:0):after.draw ? AnalysisScore(kind:"cp",value:0):nil)
        let loss=rootScore?.kind=="cp" && score?.kind=="cp" && rootScore?.bound==nil && score?.bound==nil ? max(0,rootScore!.value-score!.value):nil
        var exchange=Exchange();let sample=try base.copy()
        for uci in ([m.uci]+(reply?.lines.first?.pv ?? [])).prefix(3){guard let played=try? sample.move(uci:uci) else{break};exchange.moves.append(played.san);if let p=played.captured {if played.color=="w"{exchange.blackLost.append(p)}else{exchange.whiteLost.append(p)}}}
        let comparison=best==m.uci ? "Your move matches the engine’s first choice.":loss==nil ? "Compare the possible continuations; these short searches do not establish a precise difference.":loss!<=50 ? "Your move is close to the engine’s first choice in this short search.":"The engine prefers \(recommended?.san ?? "another move") by approximately \(String(format:"%.1f",Double(loss!)/100)) pawns in this short search."
        return CandidateEvaluation(candidate:candidate,recommended:recommended,exchange:exchange,rootAnalysis:root,candidateAnalysis:reply,candidateScore:score,lossCp:loss,comparison:comparison,candidateFrames:try lineFrames(base,moves:[m.uci]+(reply?.lines.first?.pv ?? [])),recommendedFrames:try lineFrames(base,moves:root.lines.first?.pv ?? best.map{[$0]} ?? []))
    }
    private func nullableProjection<T:Encodable>(_ value:T,keys:[String])->Any{var object=jsonObject(value) as! [String:Any];for key in keys where object[key]==nil{object[key]=NSNull()};if object["status"] as? String=="thinking"{object["status"]="analyzing"};return object}
    private func projectedLesson()->Any {guard let lesson=lesson else{return NSNull()};var value=jsonObject(lesson) as! [String:Any];if let pieces=lesson.pieces{value["pieces"]=pieces.filter{ChessRules.validSquare($0.key) && $0.value.range(of:"^[wb][pnbrqk]$",options:.regularExpression) != nil}}else{value["pieces"]=NSNull()};if ["pawn_duel","mini_game"].contains(lesson.mode){value["winner"]=lesson.winner as Any? ?? NSNull()};if let prompt=lesson.prompt{value["prompt"]=String(prompt.prefix(1000))};if let choices=lesson.choices{value["choices"]=choices.prefix(12).map{String($0.prefix(300))}};return value}
    public func publicState()->[String:Any] {
        if let review=reviewController,review.active{return ["schemaVersion":1,"sessionId":sessionId,"revision":revision,"positionId":positionId,"cursor":cursor,"mode":"review","capabilities":["game_review","show_annotation","clear_annotations","list_review_games","open_review","get_review","select_review_position","analyze_review","get_review_analysis","cancel_review_analysis","preview_review_line","clear_review_preview","start_practice_from_review"],"display":["activeView":review.branch==nil ? "review":"review_preview","fen":review.displayFEN as Any? ?? NSNull(),"identity":review.identity],"review":review.projection(),"controller":["enabled":companionEnabled,"role":companionRole,"connected":companionLease != nil,"suspended":suspended,"paused":true]]}

        let temporary = !presentationHidden && (preview != nil || demonstration != nil),ownsBlack=companionEnabled && companionRole=="opponent"
        let capabilities:[String]=mode == .practice ? (["get_legal_moves","analyze_position","show_annotation","preview_move","get_turn_brief","inspect_piece"]+(preview==nil && demonstration==nil ? ["demonstrate_line"]:[])+(demonstration != nil ? ["control_demonstration"]:[])+(preview?.evaluation != nil ? ["show_preview"]:[])+(ownsBlack && demonstration==nil ? ["play_move"]:[])):(lesson?.pieces != nil ? ["show_annotation"]:[])
        let practice:[String:Any]=["fen":rules.fen,"turn":rules.turn,"history":Array(rules.history.suffix(160)),"totalPlies":rules.history.count,"historyTruncated":rules.history.count>160,"check":rules.check,"checkmate":rules.checkmate,"draw":rules.draw,"gameOver":rules.over,"difficulty":OpponentProfile.settings(state.settings).mode=="skill" ? OpponentProfile.settings(state.settings).value:state.settings.skill,"opponentProfile":jsonObject(OpponentProfile.settings(state.settings)),"busy":busy,"busyReason":busyReason as Any? ?? NSNull(),"engineAvailable":engine != nil]
        return ["schemaVersion":1,"display":["activeView":displayView,"fen":displayFen as Any? ?? NSNull(),"identity":displayIdentity],"presentationHidden":presentationHidden,"turnEventId":mode == .practice && rules.records.last?.color=="b" ? positionId as Any:NSNull(),"coachingMode":state.settings.coachingMode,"coaching":nullableProjection(coaching,keys:["recommendation","analysis"]),"preview":preview.map{nullableProjection($0,keys:["candidate","evaluation","error"])} ?? NSNull(),"demonstration":demonstration.map{jsonObject($0)} ?? NSNull(),"sessionId":sessionId,"revision":revision,"positionId":positionId,"cursor":cursor,"overlayRevision":overlayRevision,"mode":mode == .practice ? "practice":lesson?.mode ?? "lesson","capabilities":capabilities,"controller":["enabled":companionEnabled,"role":companionRole,"connected":companionLease != nil,"paused":explicitResumeRequired || pausedOpponent || voiceHold || temporary,"pauseReason":explicitResumeRequired ? "review_restore_failed" as Any:voiceHold ? "coach_speaking" as Any:temporary ? "temporary_view" as Any:pausedOpponent ? "companion_disconnected" as Any:NSNull(),"suspended":suspended,"side":ownsBlack ? "b" as Any:NSNull()],"state":mode == .practice ? practice:projectedLesson()]
    }
}
