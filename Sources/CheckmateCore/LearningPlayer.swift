import Foundation
import Combine
@MainActor public protocol NarrationService:AnyObject {func play(file:String,seconds:Double,settings:AppSettings);func pause();func stop();var playbackTime:Double? {get}}
public extension NarrationService {var playbackTime:Double? {nil}}
public enum LessonTiming {public static let correctAnswerFeedback:Duration = .milliseconds(600)}
@MainActor public final class LearningPlayer:ObservableObject {
    public let library:CourseLibrary
    public let session:GameSession
    public weak var audio:NarrationService?
    public var onLessonOpened:(()->Void)?
    public var onMiniReset:(()->Void)?
    public var onMiniMove:((MoveRecord)->Void)?
    @Published public private(set) var miniGame:MiniGameState?
    @Published public private(set) var miniThinking=false
    private var miniTask:Task<Void,Never>?,miniGeneration=UUID()
    public var miniKind:MiniGameKind {miniGame?.kind ?? .pawnDuel}
    public var miniStatus:String {if let winner=winner{return miniKind.solo ? "Route complete!":miniGame?.computer==true ? (winner=="w" ? "You win!":"Computer wins. Try again!"):(winner=="w" ? "White wins!":"Black wins!")};if miniKind.solo{return "Next corner: \(MiniGameRules.corners[miniGame?.snapshot.cornerIndex ?? 0])"};return miniGame?.computer==true ? (miniTurn=="w" ? "Your turn · White":"Computer’s turn · Black"):(miniTurn=="w" ? "White to move":"Black to move")}
    public var onIllustration:((String,Bool)->Void)?
    private var lastMotionKey=""
    private let answerFeedbackDelay:Duration
    @Published public private(set) var lessonIndex=0
    @Published public private(set) var step=0
    @Published public private(set) var seconds=0.0
    @Published public private(set) var playing=false
    @Published public private(set) var frame=CourseFrame()
    @Published public private(set) var picked:[String]=[]
    @Published public private(set) var feedback=""
    @Published public private(set) var passed=false
    @Published public private(set) var activePuzzle:Puzzle?
    @Published public private(set) var mini=false
    @Published public private(set) var miniTurn="w"
    @Published public var query="" {didSet{saveFilters()}}
@Published public var topic="All topics" {didSet{saveFilters()}}
@Published public var level="All levels" {didSet{saveFilters()}}
@Published public var filter="All" {didSet{saveFilters()}}
    private var timer:Timer?,lastTick:Date?,path:[String]=[],mistake=false,answerTask:Task<Void,Never>?
    public init(session:GameSession,answerFeedbackDelay:Duration=LessonTiming.correctAnswerFeedback) throws {self.answerFeedbackDelay=answerFeedbackDelay;self.session=session;library=try CourseLibrary();lessonIndex=library.lessons.firstIndex{$0.id==session.state.course.lessonID} ?? 0;step=min(max(0,session.state.course.step),library.lessons[lessonIndex].beats.count-1);if let filters=session.state.puzzleFilters {query=filters["query"] ?? "";topic=filters["topic"] ?? "All topics";level=filters["level"] ?? "All levels";filter=filters["status"] ?? "All"}}
    public func reloadFilters(){let filters=session.state.puzzleFilters ?? [:];query=filters["query"] ?? "";topic=filters["topic"] ?? "All topics";level=filters["level"] ?? "All levels";filter=filters["status"] ?? "All"}
    private func saveFilters(){session.state.puzzleFilters=["query":query,"topic":topic,"level":level,"status":filter];session.emit(semantic:false,save:true)}
    public var current:CourseLesson {library.lessons[lessonIndex]}
    public var beat:CourseBeat {current.beats[step]}
    public var key:String {current.id+":"+String(step)}
    public var exercise:Exercise? {activePuzzle?.exercise ?? library.exercises[key]}
    public var duration:Double {library.voices[lessonIndex][step].duration}
    public var winner:String? {mini ? miniGame?.winner:nil}
    public var destinations:[String] {mini && !miniThinking ? picked.first.map{miniGame?.destinations(from:$0) ?? []} ?? []:[]}
    public var filteredPuzzles:[Puzzle] {library.puzzles.filter {p in (topic=="All topics" || topic==p.topic)&&(level=="All levels" || level==p.level)&&(filter=="All" || (filter=="To review" ? session.state.puzzles[p.id]?.review==true:session.state.puzzles[p.id]?.solved != true))&&(query.isEmpty || (p.title+" "+p.exercise.prompt).localizedCaseInsensitiveContains(query))}}
    public func openLesson(index:Int) {guard library.lessons.indices.contains(index) else{return};pause();activePuzzle=nil;lessonIndex=index;step=current.id==session.state.course.lessonID ? min(max(0,session.state.course.step),current.beats.count-1):0;seek(step:step);onLessonOpened?()}
    public func seek(step:Int) {NativeLog.course.debug("Seeking authored transcript");guard current.beats.indices.contains(step) else{return};pause();answerTask?.cancel();self.step=step;seconds=0;lastMotionKey="";picked=[];path=[];feedback="";mini=false;passed=session.state.course.answered.contains(key);session.state.course.lessonID=current.id;session.state.course.step=step;rebuild();session.emit(semantic:false,save:true)}
    public func play() {guard !mini,activePuzzle==nil else{return};if seconds>=duration{seconds=0};playing=true;lastTick=Date();audio?.play(file:library.voices[lessonIndex][step].file,seconds:seconds,settings:session.state.settings);timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.04,repeats:true){[weak self] _ in Task{@MainActor in guard let self=self,let last=self.lastTick else{return};let now=Date();self.lastTick=now;self.tick(wallDelta:now.timeIntervalSince(last))}};rebuild()}
    public func pause(){if mini{onMiniReset?()};cancelMiniOpponent();answerTask?.cancel();answerTask=nil;timer?.invalidate();timer=nil;lastTick=nil;playing=false;audio?.pause();if session.mode != .practice{publish()}}
    public func replay(){pause();seconds=0;play()}
    public func tick(wallDelta:Double){if let time=audio?.playbackTime,session.state.settings.narration{advance(by:max(0,time-seconds))}else{advance(by:wallDelta)}}
    public func advance(by delta:Double) {guard playing else{return};seconds=min(duration,seconds+max(0,delta));rebuild();if seconds>=duration {pause();if exercise==nil || passed {if step<current.beats.count-1 {if session.state.settings.autoAdvance {seek(step:step+1);play()}}else{complete(continuePlayback:session.state.settings.autoAdvance)}};publish()}}
    public func next(){guard !mini else{return};if activePuzzle != nil {let filtered=filteredPuzzles;if let id=activePuzzle?.id,let i=filtered.firstIndex(where:{$0.id==id}),!filtered.isEmpty {openPuzzle(id:filtered[(i+1)%filtered.count].id)};return};guard exercise==nil || passed else{return};if step<current.beats.count-1{seek(step:step+1)}else{complete()}}
    public func complete(continuePlayback:Bool=false){
        pause()
        if !session.state.course.completed.contains(current.id){session.state.course.completed.append(current.id)}
        feedback="Lesson explored! You can replay it whenever you like."
        session.emit(semantic:false,save:true)
        // Only uninterrupted playback crosses a lesson boundary. Manual navigation
        // remains paused, and the final lesson never loops back to the beginning.
        if continuePlayback,lessonIndex+1<library.lessons.count {
            openLesson(index:lessonIndex+1)
            play()
        }
    }
    public func openPuzzle(id:String) {guard let puzzle=library.puzzles.first(where:{$0.id==id}) else{return};pause();answerTask?.cancel();activePuzzle=puzzle;mini=false;picked=[];path=[];feedback="";passed=false;mistake=false;frame=CourseFrame(board:puzzle.board,hl:puzzle.highlights);publish()}
    public func showPuzzleLibrary(){pause();activePuzzle=nil;frame=CourseFrame();session.setLesson(LessonProjection(mode:"quick_puzzle",pieces:nil,title:"Quick puzzles",lessonId:"puzzle-library",step:0,prompt:nil,choices:nil,playing:false,narrationActive:false,moving:false,turn:nil,winner:nil,rules:nil))}
    public func checkAnswer(){guard let e=exercise else{return};answer(e.matches(picked))}
    public func choose(_ choice:String){guard !passed else{return};pause();answer(exercise?.matches([choice])==true)}
    public func clearSelection(){picked=[];publish()}
    public func noSquares(){guard !passed else{return};picked=[];pause();answer(exercise?.matches([])==true)}
    public func restartPath(){guard !passed else{return};path=[];picked=[];feedback="";if let p=activePuzzle {frame.board=p.board}else{rebuild()};publish()}
    public func click(_ sq:String){guard ChessRules.validSquare(sq) else{return}
        // A restored completion unlocks playback, but the narrated click prompt
        // must still respond when a learner revisits this question.
        if !mini,passed {
            guard answerTask==nil,activePuzzle==nil,let e=exercise,e.kind=="squares",e.answers?.count==1,e.matches([sq]) else{return}
            pause();picked=[sq];feedback="Correct. Well done.";publish();continueAfterAnswer();return
        }
        if mini {clickMini(sq);return};pause()
        guard let e=exercise,!passed else{return}
        switch e.kind {case "squares":
            if e.answers?.count==1 {picked=[sq];answer(e.matches(picked))}
            else if let i=picked.firstIndex(of:sq){picked.remove(at:i)}else{picked.append(sq)}
        case "move":if let from=picked.first {if from==sq{picked=[];return};let correct=e.matches([from,sq]);if correct,activePuzzle != nil,var board=frame.board{try? CourseLibrary.apply(&board,moves:[[from,sq]]);frame.board=board};picked=[];answer(correct)}else if frame.board?[sq] != nil {picked=[sq]}
        case "path":if var board=frame.board,let from=board.first(where:{$0.value=="wk"})?.key {if from==sq{return};if CourseLibrary.safeKingStep(board,from:from,to:sq){try? CourseLibrary.apply(&board,moves:[[from,sq]]);frame.board=board;path.append(sq);if sq==e.to{answer(true)}else{feedback="Safe step. Keep going!"}}else{feedback="That square is not a safe neighboring square. Try another step.";if activePuzzle != nil{answer(false)}}}
        default:break};publish()
    }
    private func answer(_ correct:Bool,revealed:Bool=false){guard exercise != nil,!passed else{return};pause()
        if let p=activePuzzle {var record=session.state.puzzles[p.id] ?? PuzzleProgress();record.record(correct:correct,revealed:revealed || mistake);session.state.puzzles[p.id]=record;if !correct{mistake=true};passed=correct || revealed;feedback=passed ? (revealed ? solution(p.exercise)+" ":"Correct. ")+p.explanation:"Not quite. Look again and try another answer.";session.emit(semantic:false,save:true)}
        else {passed=correct;feedback=correct ? "Correct. Well done.":"Take another look. You can try again.";if correct,!session.state.course.answered.contains(key){session.state.course.answered.append(key);session.emit(semantic:false,save:true)}}
        publish()
        if correct,activePuzzle==nil {continueAfterAnswer()}
    }
    private func continueAfterAnswer(){
        let answeredKey=key,delay=answerFeedbackDelay
        answerTask=Task{[weak self] in
            do{try await Task.sleep(for:delay)}catch{return}
            guard let self=self,!Task.isCancelled,self.key==answeredKey,self.passed,self.activePuzzle==nil,!self.mini,self.session.mode == .lesson else{return}
            self.answerTask=nil
            if self.step<self.current.beats.count-1 {self.seek(step:self.step+1);self.play()}else{self.complete(continuePlayback:self.session.state.settings.autoAdvance)}
        }
    }
    public func reveal(){if let p=activePuzzle{feedback=solution(p.exercise);answer(false,revealed:true)}else{pause();feedback="Let’s look at the explanation together.";if step<current.beats.count-1{seek(step:step+1)}else{complete()}}}
    private func solution(_ e:Exercise)->String {switch e.kind {case "choice":return e.answer ?? "";case "squares":return (e.answers ?? []).isEmpty ? "No squares":(e.answers ?? []).joined(separator:", ");case "move":return "\(e.from ?? "") → \(e.to ?? "")";default:return "Walk safely from \(e.from ?? "") to \(e.to ?? "")."}}
    public func startPawnDuel(computer:Bool=true){startMini(.pawnDuel,restart:true,computer:computer)}
    public func startMini(_ kind:MiniGameKind,restart:Bool=false,computer:Bool=true){
        pause();activePuzzle=nil;mini=true;picked=[];feedback=""
        miniGame = !restart ? session.state.miniGames?[kind.rawValue] ?? MiniGameState(kind:kind,computer:computer):MiniGameState(kind:kind,computer:computer)
        syncMini();scheduleMiniOpponent()
    }
    public func restartMini(){startMini(miniKind,restart:true,computer:miniGame?.computer ?? true)}
    public func setMiniComputer(_ enabled:Bool){cancelMiniOpponent();miniGame?.computer=enabled && !miniKind.solo;picked=[];syncMini();scheduleMiniOpponent()}
    public func undoMini(){onMiniReset?();cancelMiniOpponent();miniGame?.undo();picked=[];feedback="";syncMini();scheduleMiniOpponent()}
    public func leaveMini(){onMiniReset?();cancelMiniOpponent();mini=false;picked=[];feedback="";rebuild()}
    private func clickMini(_ square:String){
        guard let game=miniGame,game.winner==nil,!miniThinking,!(game.computer && game.turn=="b") else{return}
        if let from=picked.first,game.destinations(from:from).contains(square){applyMini(MiniGameMove(from:from,to:square));scheduleMiniOpponent();return}
        picked=game.board[square]?.hasPrefix(game.turn)==true && game.kind.canMove(game.board[square]!) ? (picked==[square] ? []:[square]):[]
        feedback=picked.isEmpty ? "Select one of your movable pieces.":"";publish()
    }
    private func applyMini(_ move:MiniGameMove){
        guard var game=miniGame,let piece=game.board[move.from] else{return}
        let captured=game.board[move.to],color=game.turn
        guard game.play(move) else{return};miniGame=game;picked=[];feedback="";syncMini()
        onMiniMove?(MoveRecord(color:color,from:move.from,to:move.to,piece:String(piece.suffix(1)),flags:captured==nil ? "n":"c",san:move.from+"–"+move.to,before:"",after:"",captured:captured.map{String($0.suffix(1))},promotion:nil))
    }
    private func syncMini(){
        guard let game=miniGame else{return};miniTurn=game.turn
        let highlights=game.snapshot.lastMove.map{[Highlight(sq:$0.from,kind:"last"),Highlight(sq:$0.to,kind:"last")]} ?? []
        frame=CourseFrame(board:game.board,hl:highlights,counts:game.kind.solo ? Array(MiniGameRules.corners.dropFirst(game.snapshot.cornerIndex)):nil)
        if session.state.miniGames==nil{session.state.miniGames=[:]};session.state.miniGames?[game.kind.rawValue]=game
        publish();session.emit(semantic:false,save:true)
    }
    private func cancelMiniOpponent(){miniGeneration=UUID();miniTask?.cancel();miniTask=nil;miniThinking=false}
    private func scheduleMiniOpponent(){
        guard mini,session.mode == .lesson,let game=miniGame,game.computer,game.turn=="b",game.winner==nil else{return}
        cancelMiniOpponent();miniThinking=true;picked=[];let generation=miniGeneration
        let delay=MiniGameOpponent.replyDelay+Duration.milliseconds(Int64(session.state.settings.pieceDuration))
        let profile=session.state.settings.miniOpponentProfile
        let worker=Task.detached(priority:.userInitiated){MiniGameOpponent.choose(in:game,profile:profile,seed:(UInt64(game.opponentSeed ?? "1",radix:16) ?? 1) &+ UInt64(game.history.count+1))}
        miniTask=Task{[weak self] in
            await withTaskCancellationHandler(operation:{
                let started=ContinuousClock.now,move=await worker.value
                do{try await Task.sleep(for:max(.zero,delay-started.duration(to:.now)))}catch{return}
                guard let self=self,!Task.isCancelled,self.miniGeneration==generation,self.mini,self.session.mode == .lesson,self.miniGame==game,let move=move else{return}
                self.miniTask=nil;self.miniThinking=false;self.applyMini(move)
            },onCancel:{worker.cancel()})
        }
    }
    public func settingsChanged(){if mini,session.mode == .lesson{cancelMiniOpponent();scheduleMiniOpponent();return};guard session.mode == .lesson,activePuzzle==nil,!mini else{return};if playing{audio?.play(file:library.voices[lessonIndex][step].file,seconds:seconds,settings:session.state.settings)};rebuild()}
    private func rebuild(){do{frame=try library.frame(lesson:lessonIndex,step:step,seconds:seconds,duration:Double(session.state.settings.pieceDuration)/1000)}catch{feedback="The lesson illustration could not load."};if playing,let motion=frame.motion,let piece=frame.board?[motion.from]{let key=current.id+":"+String(step)+":"+motion.from+motion.to;if key != lastMotionKey{lastMotionKey=key;onIllustration?(String(piece.suffix(1)),frame.board?[motion.to] != nil)}};publish()}
    private func publish(){let e=mini ? nil:exercise;session.setLesson(LessonProjection(mode:mini ? (miniKind == .pawnDuel ? "pawn_duel":"mini_game"):activePuzzle != nil ? "quick_puzzle":e != nil ? "quiz":"lesson",pieces:frame.board,title:mini ? miniKind.title:activePuzzle?.title ?? current.title,lessonId:activePuzzle?.id ?? current.id,step:activePuzzle != nil ? 0:step,prompt:e?.prompt,choices:e?.kind=="choice" ? e?.choices:nil,playing:playing,narrationActive:playing && session.state.settings.narration && seconds<library.voices[lessonIndex][step].seconds && !NativePolicy.silent,moving:frame.motion != nil,turn:mini ? miniTurn:nil,winner:winner,rules:mini && miniKind != .pawnDuel ? [miniKind.rules]:mini ? ["Reach the far rank with a pawn, capture every opposing pawn, or leave the opponent without a move.","Pawns move forward and capture diagonally. A pawn on its starting rank may advance two empty squares.","No en passant. Pawns stay pawns at the far rank."]:nil))}
    public func shutdown(){pause();answerTask?.cancel();audio?.stop()}
}
