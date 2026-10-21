import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import CheckmateContent
import CheckmateSupport
import Foundation
/// A quick-puzzle status filter; the raw value is saved and the view supplies the title (D-12).
public enum PuzzleStatusFilter:String,CaseIterable,Sendable {case all,unsolved,review,due
    /// Older saves stored the shown title.
    public init(stored:String?){self=stored.flatMap(Self.init(rawValue:)) ?? ["Unsolved":.unsolved,"To review":.review][stored ?? ""] ?? .all}
    /// `due`: on its review schedule at `now` (L-11).
    public func admits(_ progress:PuzzleProgress?,at now:Date)->Bool {switch self{case .all:return true;case .unsolved:return progress?.countsAsSolved != true;case .review:return progress?.review==true;case .due:return progress?.isDue(at:now)==true}}
}
import Combine
@MainActor public final class LearningPlayer:ObservableObject {
    public let library:CourseLibrary
    public let session:GameSession
    public weak var audio:NarrationService?
    public var packs:LessonPackStore? {didSet{reloadLocalizedPacks()}}
    private var localizedPacks:[Int:LessonPack]=[:],localizedURLs:[String:URL]=[:]
    private var loadedSelection=""
    @Published public private(set) var localizationLoading=false
    public var fallbackMessage:String? {guard session.state.settings.lessonLanguage != "en" else{return nil};if localizationLoading{return String(localized:"Checking this lesson’s offline recordings…",bundle:.checkmate)};return localizedPacks[lessonIndex]==nil ? String(localized:"This lesson is playing in English because its selected language recording is incomplete or unavailable.",bundle:.checkmate):nil}
    public var subtitle:String {localizedPacks[lessonIndex]?.translation.beats[step].say ?? beat.say}
    public var teaches:[String] {localizedPacks[lessonIndex]?.translation.teaches ?? current.teaches ?? []}
    public func localizedTitle(index:Int)->String {localizedPacks[index]?.translation.title ?? library.lessons[index].title}
    public func localizedStepTitle(index:Int,step:Int)->String {localizedPacks[index]?.translation.beats[step].stepTitle ?? library.stepTitles[index][step]}
    private var packReloadTask:Task<Void,Never>?,packGeneration=UUID()
    private var authoredLessonActive:Bool {session.mode == .lesson && !mini && activePuzzle==nil && session.lesson?.mode=="lesson"}
    private func playbackIdentity(_ pack:LessonPack?)->String {guard let pack else{return String(localized:"English",bundle:.checkmate)};return pack.sourceFingerprint+"|"+pack.locale+"|"+pack.voice+"|"+pack.clips.sorted{$0.beatID<$1.beatID}.map{$0.beatID+":"+$0.audioHash}.joined(separator:"|")}
    public func reloadLocalizedPacks(){let settings=session.state.settings,selection=settings.lessonLanguage+"|"+settings.lessonVoice,selectionChanged=selection != loadedSelection;let active=authoredLessonActive;if selectionChanged && active{rewind()};packReloadTask?.cancel();packGeneration=UUID();let generation=packGeneration;if selectionChanged{localizedPacks=[:];localizedURLs=[:]}else{dropPacksWithMissingRecordings(active:active)};loadedSelection=selection;guard settings.lessonLanguage != "en",let packs else{localizationLoading=false;if selectionChanged && active{rebuild()};return};let library=self.library
        // A rescan for the same selection (a job ended, a recording was removed) must not end a pending selection
        // change's loading early: only the scan that completes clears it.
        localizationLoading=selectionChanged || localizationLoading;if selectionChanged && active{rebuild()};packReloadTask=Task{[weak self] in
        let worker=Task.detached{()->([Int:LessonPack],[String:URL]) in var found:[Int:LessonPack]=[:],urls:[String:URL]=[:];for index in library.lessons.indices {if Task.isCancelled{break};let source=LessonTranslation.source(library:library,index:index);if let (pack,files)=try? packs.validatedPack(source:source,locale:settings.lessonLanguage,voice:settings.lessonVoice){found[index]=pack;urls.merge(files){_,new in new}}};return (found,urls)}
        let result=await withTaskCancellationHandler(operation:{await worker.value},onCancel:{worker.cancel()})
        guard let self,!Task.isCancelled,self.packGeneration==generation else{return};let currentChanged=self.playbackIdentity(self.localizedPacks[self.lessonIndex]) != self.playbackIdentity(result.0[self.lessonIndex]);if currentChanged && self.authoredLessonActive{self.rewind()};self.objectWillChange.send();self.localizedPacks=result.0;self.localizedURLs=result.1;self.localizationLoading=false;if currentChanged && self.authoredLessonActive{self.rebuild()}
    }}
    /// Remove, Discard or a removed clip deletes recordings before the background rescan finishes. A lesson whose loaded
    /// pack lost a file falls back to English at once, so Play never reaches a deleted recording.
    private func dropPacksWithMissingRecordings(active:Bool){
        let missing=Set(localizedURLs.filter{!FileManager.default.fileExists(atPath:$0.value.path)}.keys);guard !missing.isEmpty else{return}
        let stale=localizedPacks.filter{entry in entry.value.clips.contains{missing.contains($0.beatID)}}.map{$0.key},current=stale.contains(lessonIndex)
        if current && active{rewind()};objectWillChange.send()
        for index in stale{for clip in localizedPacks.removeValue(forKey:index)?.clips ?? []{localizedURLs[clip.beatID]=nil}}
        if current && active{rebuild()}
    }
    private var narrationSeconds:Double {localizedPacks[lessonIndex]?.clips.first(where:{$0.beatID==key})?.seconds ?? library.voices[lessonIndex][step].seconds}
    /// The narration settings the playing clip was started with; only a change that needs a restart restarts it.
    private var narrationApplied=(on:false,volume:0.0)
    private func playNarration(){let settings=session.state.settings;narrationApplied=(settings.narration,settings.volume);if let url=localizedURLs[key],localizedPacks[lessonIndex] != nil{audio?.play(localURL:url,seconds:seconds,settings:settings)}else{audio?.play(file:library.voices[lessonIndex][step].file,seconds:seconds,settings:settings)};showPlaybackNotice(audio?.narrationFailure)}
    /// The playback notice shown in `feedback` (a narration failure, or recordings still being checked); it is cleared
    /// when playback next starts cleanly, unless other feedback has replaced it since.
    private var playbackNotice:String?
    private func showPlaybackNotice(_ notice:String?){if let shown=playbackNotice,feedback==shown{feedback=""};playbackNotice=notice;if let notice{feedback=notice}}
    public var onLessonOpened:(()->Void)?
    public var onMiniReset:(()->Void)?
    public var onMiniMove:((MoveRecord)->Void)?
    @Published public private(set) var miniGame:MiniGameState?
    @Published public private(set) var miniThinking=false
    /// The post-game review of the mini-game shown (WI-018). It starts when a game finishes, never during play, and ends
    /// on restart, undo, a change of opponent or leaving the game.
    public let miniReview=MiniGameReviewer()
    private var miniTask:Task<Void,Never>?,miniGeneration=UUID()
    public var miniKind:MiniGameKind {miniGame?.kind ?? .pawnDuel}
    public var miniStatus:String {if let reason=miniGame?.drawReason{return Sentences.join(String(localized:"Draw.",bundle:.checkmate),reason)};if let winner=winner{return miniKind.solo ? String(localized:"Route complete!",bundle:.checkmate):miniGame?.computer==true ? (winner==miniLearnerSide ? String(localized:"You win!",bundle:.checkmate):String(localized:"Computer wins. Try again!",bundle:.checkmate)):(winner=="w" ? String(localized:"White wins!",bundle:.checkmate):String(localized:"Black wins!",bundle:.checkmate))};if miniKind.solo{return String(localized:"Next corner: \(MiniGameRules.corners[miniGame?.snapshot.cornerIndex ?? 0])",bundle:.checkmate)};return miniGame?.computer==true ? (miniTurn==miniLearnerSide ? (miniTurn=="w" ? String(localized:"Your turn · White",bundle:.checkmate):String(localized:"Your turn · Black",bundle:.checkmate)):(miniTurn=="w" ? String(localized:"Computer’s turn · White",bundle:.checkmate):String(localized:"Computer’s turn · Black",bundle:.checkmate))):(miniTurn=="w" ? String(localized:"White to move",bundle:.checkmate):String(localized:"Black to move",bundle:.checkmate))}
    /// The record of the game shown against the computer and the side of its run (L-23, L-24), once one is saved.
    public var miniRecord:MiniGameRecord? {session.state.miniGameRecords?[miniKind.rawValue]}
    /// The side the learner plays in the game shown: its run's side, else White.
    public var miniLearnerSide:String {miniGame.flatMap{miniRecord?.side(of:$0)} ?? "w"}
    /// The side the picker shows: the learner's preference for the game shown.
    public var miniPreferredSide:String {session.state.settings.miniLearnerSides?[miniKind.rawValue] ?? "w"}
    /// Whether the game shown lets the learner choose a side: against the computer, in a game equal from both sides.
    public var miniSideOffered:Bool {mini && miniGame?.computer==true && MiniGameSides.offersChoice(miniKind)}
    /// Whether the learner has moved in the game shown; the computer's opening move as White is not the learner's.
    private var miniLearnerMoved:Bool {(miniGame?.history.count ?? 0)>(miniLearnerSide=="b" ? 1:0)}
    /// Whether the picker names another side than the unfinished game in progress is played from. That game keeps its
    /// side, and the drawer offers a new game from the chosen one.
    public var miniNewSideOffered:Bool {guard miniSideOffered,miniGame?.isFinished==false else{return false};return miniLearnerMoved && miniLearnerSide != miniPreferredSide}
    /// Chooses the side of this game's next runs. A game the learner has not moved in restarts from it, losing nothing.
    public func setMiniSide(_ side:String){
        guard miniSideOffered,["w","b"].contains(side) else{return}
        var settings=session.state.settings;settings.miniLearnerSides=(settings.miniLearnerSides ?? [:]).merging([miniKind.rawValue:side]){_,chosen in chosen};session.updateSettings(settings)
        if !miniLearnerMoved,miniLearnerSide != side{restartMini()}
    }
    /// The learner's results at the level of the game shown, against the computer.
    public var miniRecordText:String? {guard miniGame?.computer==true,let level=miniLevel,let tally=miniRecord?.levels[level] else{return nil};return String(localized:"At \(MiniGameOffering.title(level)): \(tally.wins) won, \(tally.draws) drawn, \(tally.losses) lost",bundle:.checkmate)}
    /// The step the latest results suggest for the next game, shown once the game shown has finished (L-24).
    public var miniAdvice:MiniGameLevelAdvice? {guard let game=miniGame,game.computer,game.isFinished else{return nil};return miniRecord?.advice(level:miniPreferredLevel,offered:MiniGameOffering.levels(for:miniKind))}
    /// Takes the suggested step: the level becomes this game's preference and a new game starts at it.
    public func takeMiniAdvice(){
        guard let advice=miniAdvice else{return}
        switch advice {case .stepUp(let level),.stepDown(let level):setMiniLevel(level);if miniLevel != level{restartMini()}}
    }
    /// Counts a finish against the computer in the game's record, once per run.
    private func countMini(_ game:MiniGameState){var record=miniRecord ?? MiniGameRecord();if record.count(game){session.state.miniGameRecords=(session.state.miniGameRecords ?? [:]).merging([game.kind.rawValue:record]){_,counted in counted}}}
    public var onIllustration:((String,Bool)->Void)?
    private var soundedMoves=Set<Int>()
    /// The exercise of the lesson's invitation step ("Now try it yourself"), played on that step's own board.
    public private(set) var attempt:LessonAttemptController!
    /// A move of the exercise landed (sound, animation, VoiceOver).
    public var onAttemptMove:((MoveRecord)->Void)?
    /// The exercise's moves were taken back or replaced (undo, restart, leaving it).
    public var onAttemptReset:(()->Void)?
    /// The board the exercise shows, kept so narration ticks never replay the attempt.
    private var attemptFrame=CourseFrame()
    /// The step of the current lesson whose board is its exercise, if it has one.
    public var invitationStep:Int? {guard let practice=current.practice,practice.playable,let beat=practice.beat else{return nil};return current.beats.firstIndex{$0.id==beat}}
    /// The invitation step is shown: the board is the learner's to play.
    public var attemptStep:Bool {session.mode == .lesson && !mini && activePuzzle==nil && invitationStep==step}
    /// The current lesson's exercise has saved moves.
    public var attemptInProgress:Bool {session.state.lessonAttempts?[current.id]?.moves.isEmpty == false}
    /// The exercise's state for the centered title, or nil off the invitation step.
    public var attemptStatus:String? {
        guard attemptStep,let phase=attempt.phase else{return nil}
        if attempt.waitingToResume{return String(localized:"Paused",bundle:.checkmate)};if attempt.thinking{return String(localized:"Computer’s turn",bundle:.checkmate)}
        switch phase {case .yourTurn:return String(localized:"Your turn",bundle:.checkmate);case .computerTurn:return String(localized:"Computer’s turn",bundle:.checkmate);case .offTrack,.failed:return String(localized:"Try again",bundle:.checkmate);case .achieved:return String(localized:"Well done",bundle:.checkmate);case .playingOn:return attempt.rules.turn=="w" ? String(localized:"Play on · Your turn",bundle:.checkmate):String(localized:"Play on · Computer’s turn",bundle:.checkmate);case .finished:return String(localized:"Game finished",bundle:.checkmate)}
    }
    private func syncAttempt(){if attemptStep,let practice=current.practice{attempt.open(lessonID:current.id,practice:practice)}else if attempt.active{attempt.close()};attemptFrame=attempt.frame}
    private func attemptChanged(){attemptFrame=attempt.frame;guard attemptStep else{return};picked=attempt.selected.map{[$0]} ?? [];objectWillChange.send();frame=attemptFrame;publish()}
    /// Goes to the lesson's exercise step, where its saved attempt is waiting. The practice game is not touched.
    public func goToAttempt(){guard let step=invitationStep else{return};seek(step:step)}
    /// After saved progress is replaced (an import): the exercise shown is read again from it.
    public func reloadAttempt(){attempt.close();syncAttempt();rebuild()}
    /// What the saved progress shows of lesson `index`: explored, practised or mastered (`LessonStatus`).
    public func status(index:Int)->LessonStatus {LessonStatus.of(library.lessons[index],in:library,course:session.state.course,puzzles:session.state.puzzles)}
    public var practiceAvailable:Bool {!MiniGameKind.available(lessonID:current.id).isEmpty || current.practice != nil || !library.practice(for:lessonIndex).isEmpty}
    /// The lesson shown, or the last one shown while elsewhere (the sidebar and Settings follow it).
    public var lessonIndex:Int {session.activity.place.lessonIndex ?? lastLessonIndex}
    private var lastLessonIndex=0
    @Published public private(set) var step=0
    @Published public private(set) var seconds=0.0
    @Published public private(set) var playing=false
    /// Whether this step's illustration is being played rather than read. Play starts a staged beat at its first stage
    /// and reveals the rest with the narration; pausing freezes what is shown, even at the very start. Going to a step
    /// (or back to its start) reads it again, with every stage shown.
    private var illustrationPlayed=false
    @Published public private(set) var frame=CourseFrame()
    @Published public private(set) var picked:[String]=[]
    @Published public private(set) var feedback=""
    @Published public private(set) var passed=false
    /// The puzzle and the mini-game shown are part of the session's activity, not separate flags (B8.2).
    public var activePuzzle:Puzzle? {if case .puzzle(let id)=session.activity.place{return puzzles[id]};return nil}
    public var mini:Bool {if case .miniGame=session.activity.place{return true};return false}
    private let puzzles:[String:Puzzle]
    private var activityObservation:AnyCancellable?
    /// Moves the learning surface to `place`. Under an open review the review keeps the board and returns there.
    private func go(_ place:Place){if let index=place.lessonIndex{lastLessonIndex=index};if var visit=session.activity.review{visit.returnTo=place;session.enter(.reviewing(visit))}else{session.enter(.at(place))}}
    @Published public private(set) var miniTurn="w"
    @Published public var query="" {didSet{saveFilters()}}
    /// `nil` shows every topic or level; a value is a course topic or level, never a shown "All" title (D-12).
    @Published public var topic:String? {didSet{saveFilters()}}
    @Published public var level:String? {didSet{saveFilters()}}
    @Published public var filter=PuzzleStatusFilter.all {didSet{saveFilters()}}
    private var timer:Timer?,lastTick:Date?,mistake=false
    /// Hints taken on the puzzle shown in this visit, and their words; a new visit starts without any.
    @Published public private(set) var puzzleHints=0
    @Published public private(set) var hintTexts:[String]=[]
    /// Shown in the puzzle library once the learner moves past the last puzzle of a set, instead of starting it again.
    @Published public private(set) var setSummary:PuzzleSetSummary?
    /// `course` replaces the packaged course; tests use it to bind an exercise to a step other than the last.
    public init(session:GameSession,course:CourseLibrary?=nil) throws {self.session=session;library=try course ?? CourseLibrary();puzzles=Dictionary(library.puzzles.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
        // A saved lesson this course no longer has opens the first lesson at its start, never at a step derived from the
        // unknown lesson's transcript position.
        if let index=library.lessons.firstIndex(where:{$0.id==session.state.course.lessonID}){lastLessonIndex=index;step=library.resumeStep(in:library.lessons[index],progress:session.state.course)}else{lastLessonIndex=0;step=0};if let filters=session.state.puzzleFilters {(query,topic,level,filter)=Self.restored(filters,topics:library.puzzles.map(\.topic),levels:library.levels)}
        activityObservation=session.$activity.removeDuplicates().sink{[weak self] activity in
            // Navigating anywhere but this game (a review over it keeps its place) ends its post-game review.
            switch activity.place{case .miniGame:break;default:self?.miniReview.cancel()}
            self?.objectWillChange.send()}
        miniReview.current={[weak self] in self?.mini==true ? self?.miniGame:nil}
        session.finishedMiniGameReview={[weak self] in guard let self,let scope=miniReview.voiceScope(at:self.session.activity),let review=miniReview.review else{return nil};return (scope,review)}
        attempt=try LessonAttemptController(session:session)
        attempt.onChange={[weak self] in self?.attemptChanged()}
        attempt.onLearnerMove={[weak self] in self?.pauseNarration()}
        attempt.onMove={[weak self] move in self?.onAttemptMove?(move)}
        attempt.onReset={[weak self] in self?.onAttemptReset?()}
        attempt.replyDelay={[weak self] in MiniGameOpponent.replyDelay+Duration.milliseconds(Int64(self?.session.state.settings.pieceDuration ?? 0))}}
    /// Restoring filters from the saved state (an import) writes nothing back: only the learner's own edits save.
    private var restoringFilters=false
    public func reloadFilters(){restoringFilters=true;defer{restoringFilters=false};(query,topic,level,filter)=Self.restored(session.state.puzzleFilters ?? [:],topics:library.puzzles.map(\.topic),levels:library.levels)}
    /// A topic or level this course no longer offers (an older topic name, or a save from before stable identifiers that
    /// stored "All topics") shows every puzzle instead of none; an older shown status ("To review") still restores.
    static func restored(_ f:[String:String],topics:[String],levels:[String])->(String,String?,String?,PuzzleStatusFilter){(f["query"] ?? "",f["topic"].flatMap{topics.contains($0) ? $0:nil},f["level"].flatMap{levels.contains($0) ? $0:nil},PuzzleStatusFilter(stored:f["status"]))}
    public var filtersActive:Bool {!query.isEmpty || topic != nil || level != nil || filter != .all}
    public func clearFilters(){query="";topic=nil;level=nil;filter = .all}
    /// The topic picker's groups (course sections, in course order) and the levels the course uses.
    public var topicGroups:[(title:String,topics:[String])] {library.topicGroups}
    public var levels:[String] {library.levels}
    /// How far the course has come, where Continue Learning goes, and whether every main lesson is explored.
    public var courseProgress:CourseStanding {library.standing(session.state.course)}
    public var continueIndex:Int? {library.continueIndex(session.state.course)}
    public var courseComplete:Bool {library.complete(session.state.course)}
    private func saveFilters(){guard !restoringFilters else{return};session.state.puzzleFilters=["query":query,"topic":topic,"level":level,"status":filter.rawValue].compactMapValues{$0};session.emit(semantic:false,save:true)}
    public var current:CourseLesson {library.lessons[lessonIndex]}
    public var beat:CourseBeat {current.beats[step]}
    public var key:String {beat.id ?? current.id+":"+String(step)}
    public var exercise:Exercise? {activePuzzle?.exercise}
    public var duration:Double {library.playbackDuration(lesson:lessonIndex,step:step,narrationSeconds:narrationSeconds,pieceDuration:Double(session.state.settings.pieceDuration)/1000,useCues:localizedPacks[lessonIndex]==nil)}
    public var winner:String? {mini ? miniGame?.winner:nil}
    public var destinations:[String] {if attemptStep{return attempt.destinations};return mini && !miniThinking ? picked.first.map{miniGame?.destinations(from:$0) ?? []} ?? []:[]}
    public var filteredPuzzles:[Puzzle] {let clock=now();return library.puzzles.filter {p in (topic==nil || topic==p.topic)&&(level==nil || level==p.level)&&filter.admits(session.state.puzzles[p.id],at:clock)&&(query.isEmpty || (p.title+" "+p.exercise.prompt).localizedCaseInsensitiveContains(query))}}
    /// `fromTraining`: a training lesson link; reading it keeps the course bookmark (see `seek`), so it reopens at its
    /// own reading position, and the course lesson at its bookmark.
    public func openLesson(index:Int,resume:Bool=true,fromTraining:Bool=false) {guard library.lessons.indices.contains(index) else{return};pause();go(.lesson(index:index,fromTraining:fromTraining));let lesson=current,bookmark=lesson.id==session.state.course.lessonID ? library.resumeStep(in:lesson,progress:session.state.course):nil,reading=session.state.course.positions?[lesson.id].flatMap{id in lesson.beats.firstIndex{$0.id==id}};step=(fromTraining ? reading ?? bookmark:bookmark ?? reading) ?? 0;seek(step:resume ? step:0);onLessonOpened?()}
    /// A lesson opened from a training link: its own reading position is kept, but the course bookmark (where the
    /// course continues) stays on the learner's own lesson.
    public var readingFromTraining:Bool {if case .lesson(_,true)=session.activity.place{return true};return false}
    public func seek(step:Int) {NativeLog.course.debug("Seeking authored transcript");guard current.beats.indices.contains(step) else{return};pause();if mini{go(miniLesson)};self.step=step;seconds=0;illustrationPlayed=false;soundedMoves=[];picked=[];feedback="";passed=false;if !readingFromTraining{session.state.course.lessonID=current.id;session.state.course.step=step;session.state.course.segmentID=key};session.state.course.positions=(session.state.course.positions ?? [:]).merging([current.id:key]){_,new in new};syncAttempt();rebuild();session.emit(semantic:false,save:true)}
    public func play() {guard !mini,activePuzzle==nil else{return};guard !localizationLoading else{showPlaybackNotice(String(localized:"Checking offline lesson recordings. Try Play again shortly.",bundle:.checkmate));return};if seconds>=duration{seconds=0;soundedMoves=[]};playing=true;illustrationPlayed=true;lastTick=Date();playNarration();timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.04,repeats:true){[weak self] _ in Task{@MainActor in guard let self=self,let last=self.lastTick else{return};let now=Date();self.lastTick=now;self.tick(wallDelta:now.timeIntervalSince(last))}};rebuild()}
    public func pause(){if mini{onMiniReset?()};cancelMiniOpponent();attempt?.suspend();pauseNarration()}
    /// Stops lesson narration only. A mini-game's pending computer reply is not narration and keeps coming (LE-5).
    public func pauseNarration(){timer?.invalidate();timer=nil;lastTick=nil;playing=false;audio?.pause();if session.mode != .practice{publish()}}
    /// Stops playback at the start of the step; every move's illustration sound plays again from there.
    private func rewind(){pause();seconds=0;illustrationPlayed=false;soundedMoves=[]}
    /// Plays the step again from its start. On the invitation step that is the instruction only: the board stays.
    public func replay(){if attemptStep{pauseNarration();seconds=0;soundedMoves=[];play();return};rewind();play()}
    public func tick(wallDelta:Double){if let time=audio?.playbackTime,session.state.settings.narration{advance(by:max(0,time-seconds))}else{advance(by:wallDelta)}}
    public func advance(by delta:Double) {guard playing else{return};seconds=min(duration,seconds+max(0,delta));rebuild();if seconds>=duration {if attemptStep{pauseNarration();if step==current.beats.count-1{complete()}else{feedback=String(localized:"Your turn: make your move on the board.",bundle:.checkmate)};publish();return};pause();if step<current.beats.count-1 {if session.state.settings.autoAdvance {seek(step:step+1);play()}}else{complete(continuePlayback:session.state.settings.autoAdvance)};publish()}}
    /// On a puzzle: the next one in the filtered set. Past the last one the set ends with its summary in the library
    /// rather than starting over.
    public func next(){guard !mini else{return};if let id=activePuzzle?.id {
            if let queue=mixQueue,let index=queue.firstIndex(of:id) {
                if index+1<queue.count{openPuzzle(id:queue[index+1]);return}
                mixQueue=nil;showPuzzleLibrary();setSummary=PuzzleSetSummary(queue.compactMap{id in library.puzzles.first{$0.id==id}},progress:session.state.puzzles);mixFinished=true;return
            }
            let order=library.puzzles.map(\.id),current=order.firstIndex(of:id) ?? -1
            if let following=filteredPuzzles.first(where:{(order.firstIndex(of:$0.id) ?? -1)>current}){openPuzzle(id:following.id);return}
            showPuzzleLibrary();setSummary=PuzzleSetSummary(puzzleSet,progress:session.state.puzzles);return
        };if step<current.beats.count-1{seek(step:step+1)}else{complete()}}
    /// The set a summary describes: the chosen topic, level and search, whatever their status now.
    private var puzzleSet:[Puzzle] {library.puzzles.filter{p in (topic==nil || topic==p.topic)&&(level==nil || level==p.level)&&(query.isEmpty || (p.title+" "+p.exercise.prompt).localizedCaseInsensitiveContains(query))}}
    /// Moves on without answering: nothing is recorded, so the puzzle stays not tried and is not marked for review.
    public func skip(){guard activePuzzle != nil,!passed else{return};next()}
    /// After a set's summary: the puzzles to review, from the first.
    public func reviewMistakes(){mixQueue=nil;filter = .review;setSummary=nil;if let first=filteredPuzzles.first{openPuzzle(id:first.id)}}
    /// The puzzles due for review now, whatever the library's other filters say (L-11).
    public var dueCount:Int {let clock=now();return library.puzzles.filter{session.state.puzzles[$0.id]?.isDue(at:clock)==true}.count}
    /// The due puzzles, from the first; the other filters are cleared so none of them is hidden.
    public func reviewDue(){mixQueue=nil;topic=nil;level=nil;query="";filter = .due;setSummary=nil;if let first=filteredPuzzles.first{openPuzzle(id:first.id)}}
    /// Today's Mix as it would start now (L-29); composed from the saved records, never saved itself.
    public var todayMix:[String] {TodayMix.compose(library.puzzles,progress:session.state.puzzles,explored:Set(session.state.course.completed),at:now())}
    /// The mix being played, in order: `next` follows it rather than the library's filters. Opening any puzzle outside
    /// it ends the mix.
    private var mixQueue:[String]?
    /// The set summary on show is the end of a mix.
    @Published public private(set) var mixFinished=false
    public func startTodayMix(){let mix=todayMix;guard let first=mix.first else{return};mixQueue=mix;openPuzzle(id:first)}
    /// The lesson's own puzzles (linked by its id), for its Check Yourself button; nil when it has none.
    public func checkYourselfTitle(index:Int)->String? {guard library.lessons.indices.contains(index) else{return nil};let count=library.puzzles(for:library.lessons[index].id).count;return count==0 ? nil:String(localized:"Check Yourself: \(count) Puzzles",bundle:.checkmate,comment:"A lesson’s quiz title, shown in the sidebar")}
    /// Opens the lesson's first puzzle, with the library showing just that lesson's puzzles.
    public func checkYourself(index:Int){guard library.lessons.indices.contains(index),let first=library.puzzles(for:library.lessons[index].id).first else{return};mixQueue=nil;topic=first.topic;level=nil;filter = .all;query="";openPuzzle(id:first.id)}
    public func complete(continuePlayback:Bool=false){
        // Narration ending over the exercise stops only the narration: a reply the computer is choosing still comes.
        if attemptStep{pauseNarration()}else{pause()}
        if !session.state.course.completed.contains(current.id){session.state.course.completed.append(current.id)}
        feedback=String(localized:"Lesson explored! You can replay it whenever you like.",bundle:.checkmate)
        session.emit(semantic:false,save:true)
        // Only uninterrupted playback crosses a lesson boundary. Manual navigation
        // remains paused, and the final lesson never loops back to the beginning.
        // It follows the main path: a practice activity is offered, never played into.
        // The exercise step is an interaction boundary: its narration ending never leaves it, whatever auto-advance says.
        if attemptStep{feedback=String(localized:"Your turn: make your move on the board, or continue to the next lesson.",bundle:.checkmate);publish();return}
        if continuePlayback,let next=library.nextMainLesson(after:lessonIndex) {
            if session.state.settings.pauseForPractice,practiceAvailable{feedback=library.practice(for:lessonIndex).first.map{String(localized:"Try \(localizedTitle(index:$0)), or continue to the next lesson.",bundle:.checkmate)} ?? MiniGameKind.available(lessonID:current.id).first.map{String(localized:"Play \($0.title), or continue to the next lesson.",bundle:.checkmate)} ?? String(localized:"Continue to the next lesson when you are ready.",bundle:.checkmate);publish();return}
            openLesson(index:next,resume:false,fromTraining:readingFromTraining)
            play()
        }
    }
    public func openPuzzle(id:String) {guard let puzzle=library.puzzles.first(where:{$0.id==id}) else{return};if mixQueue?.contains(id) != true{mixQueue=nil};pause();go(.puzzle(id:puzzle.id));picked=[];feedback="";passed=false;mistake=false;puzzleHints=0;hintTexts=[];setSummary=nil;mixFinished=false;frame=CourseFrame(board:puzzle.board,hl:puzzle.highlights);publish()}
    /// Whether the puzzle shown has another rung on its hint ladder; after the last one only Reveal is left.
    public var canHint:Bool {activePuzzle.map{!passed && puzzleHints<$0.hints.count} ?? false}
    /// The next rung: its words, and a hint highlight on the piece it points at (a path puzzle's king where it stands now).
    public func hint(){guard canHint,let p=activePuzzle else{return};let rung=p.hints[puzzleHints];puzzleHints+=1;hintTexts.append(rung.text)
        let square=p.exercise.kind=="path" ? frame.board?.first(where:{$0.value=="wk"})?.key ?? rung.square:rung.square;if let square{frame.hl.append(Highlight(sq:square,kind:"hint"))};publish()}
    public func showPuzzleLibrary(){pause();go(.puzzleLibrary);picked=[];feedback="";frame=CourseFrame();publish()}
    public func checkAnswer(){guard let e=exercise else{return};answer(e.matches(picked))}
    public func choose(_ choice:String){guard activePuzzle != nil,!passed else{return};pause();answer(exercise?.matches([choice])==true)}
    public func clearSelection(){if attemptStep{attempt.clearSelection();return};picked=[];publish()}
    public func noSquares(){guard activePuzzle != nil,!passed else{return};picked=[];pause();answer(exercise?.matches([])==true)}
    public func restartPath(){guard let p=activePuzzle,!passed else{return};picked=[];feedback="";frame.board=p.board;publish()}
    public func click(_ sq:String){guard ChessRules.validSquare(sq) else{return}
        if mini {clickMini(sq);return};if attemptStep{attempt.click(sq);return};guard activePuzzle != nil else{return};pause()
        guard let e=exercise,!passed else{return}
        switch e.kind {case "squares":
            if e.answers?.count==1 {picked=[sq];answer(e.matches(picked))}
            else if let i=picked.firstIndex(of:sq){picked.remove(at:i)}else{picked.append(sq)}
        case "move":let mover=e.from.flatMap{frame.board?[$0]?.first};if let from=picked.first {if from==sq{picked=[];return};if let mover,frame.board?[sq]?.first==mover{picked=[sq];break};let correct=e.matches([from,sq]);if correct,activePuzzle != nil,var board=frame.board{try? CourseLibrary.apply(&board,moves:[[from,sq]]);frame.board=board};picked=[];answer(correct)}else if let piece=frame.board?[sq],mover.map({piece.first==$0}) ?? true {picked=[sq]}
        // A square that is not a king step is a misclick, not a mistake; an unsafe neighbour is a mistake whose own
        // guidance stays visible instead of the generic "Not quite".
        case "path":if var board=frame.board,let from=board.first(where:{$0.value=="wk"})?.key {if from==sq{return};if CourseLibrary.safeKingStep(board,from:from,to:sq){try? CourseLibrary.apply(&board,moves:[[from,sq]]);frame.board=board;if sq==e.to{answer(true)}else{feedback=String(localized:"Safe step. Keep going!",bundle:.checkmate)}}else if !CourseLibrary.attacks(board,from:from,to:sq){feedback=String(localized:"Choose a square next to the king.",bundle:.checkmate)}else{answer(false,hint:String(localized:"That square is not a safe neighboring square. Try another step.",bundle:.checkmate))}}
        default:break};publish()
    }
    /// A correct answer after a mistake in this visit is a later solve, and one after a hint is solved with help: each
    /// says so, counts as solved but not as solved alone, and stays queued for review.
    private func answer(_ correct:Bool,revealed:Bool=false,hint:String?=nil){guard let p=activePuzzle,!passed else{return};pause()
        let later=correct && !revealed && mistake,helped=correct && !revealed && puzzleHints>0
        var record=session.state.puzzles[p.id] ?? PuzzleProgress();record.record(correct:correct,revealed:revealed,afterMistake:mistake,hints:puzzleHints,at:now(),calendar:calendar);session.state.puzzles[p.id]=record;if !correct{mistake=true};passed=correct || revealed;feedback=passed ? Sentences.join(revealed ? solution(p.exercise):helped ? String(localized:"Correct, with help from a hint. It counts as solved with help and comes back for review.",bundle:.checkmate):later ? String(localized:"Correct, on a later try. It counts as solved and comes back for review.",bundle:.checkmate):String(localized:"Correct.",bundle:.checkmate),p.explanation):hint ?? String(localized:"Not quite. Look again and try another answer.",bundle:.checkmate);session.emit(semantic:false,save:true);publish()
    }
    public func reveal(){guard activePuzzle != nil else{return};answer(false,revealed:true)}
    private func solution(_ e:Exercise)->String {switch e.kind {case "choice":return e.answer ?? "";case "squares":return (e.answers ?? []).isEmpty ? String(localized:"No squares",bundle:.checkmate):(e.answers ?? []).joined(separator:", ");case "move":return "\(e.from ?? "") → \(e.to ?? "")";default:return String(localized:"Walk safely from \(e.from ?? "") to \(e.to ?? "").",bundle:.checkmate)}}
    public func startPawnDuel(computer:Bool=true){startMini(.pawnDuel,restart:true,computer:computer)}
    /// Opens a mini-game from its lesson, or with `fromLibrary` from the training library. Either way it is the one
    /// saved board for that kind (plan rule 8): resuming by default, replaced only by an explicit restart. Opening from
    /// the library never moves the course bookmark or starts narration. A new run, fresh or restarted, freezes the
    /// level the learner prefers for this game now; a resumed run keeps its own (`MiniGameState.settleLevel`).
    public func startMini(_ kind:MiniGameKind,restart:Bool=false,computer:Bool=true,fromLibrary:Bool=false){
        pause();miniReview.cancel();var game = !restart ? session.state.miniGames?[kind.rawValue] ?? MiniGameState(kind:kind,computer:computer):MiniGameState(kind:kind,computer:computer)
        game.settleLevel(adopting:MiniGameOffering.level(for:kind,settings:session.state.settings));miniGame=game
        // Only a game against the computer that offers the choice records a side; every other run is played from White.
        if game.computer,MiniGameSides.offersChoice(kind) {var record=miniRecord ?? MiniGameRecord();record.settleSide(of:game,preferred:miniPreferredSide);session.state.miniGameRecords=(session.state.miniGameRecords ?? [:]).merging([kind.rawValue:record]){_,settled in settled}}
        go(.miniGame(lessonIndex:fromLibrary ? nil:lessonIndex,kind:kind,fromTraining:!fromLibrary && lessonFromTraining));picked=[];feedback=""
        syncMini();scheduleMiniOpponent()
    }
    /// Whether the mini-game shown was opened from the training library rather than a lesson.
    public var miniFromLibrary:Bool {if case .miniGame(nil,_,_)=session.activity.place{return true};return false}
    /// Whether the lesson shown, or the one the mini-game shown was opened from, is a training link. Read from the
    /// activity alone, so a restart, a review over the game and the way back all keep it without a copy here.
    private var lessonFromTraining:Bool {switch session.activity.place{case .lesson(_,let linked),.miniGame(_,_,let linked):return linked;default:return false}}
    /// The lesson a lesson-launched mini-game returns to, still a training link when it was opened as one, so reading
    /// it after the game keeps the course bookmark.
    private var miniLesson:Place {.lesson(index:lessonIndex,fromTraining:lessonFromTraining)}
    /// After a review closes: delivers the activity state held back while the review owned the board, and re-queues the
    /// computer's mini-game reply that leaving for the review cancelled.
    public func resumeMiniOpponent(){if publishDeferred,!session.reviewSuspended,session.mode != .practice{publish()};scheduleMiniOpponent()}
    public func restartMini(){startMini(miniKind,restart:true,computer:miniGame?.computer ?? true,fromLibrary:miniFromLibrary)}
    /// The level the picker shows for the game shown: the learner's preference for it, as offered.
    public var miniPreferredLevel:String {MiniGameOffering.level(for:miniKind,settings:session.state.settings)}
    /// The level the game shown plays at, frozen when its run started; nil for a solo game.
    public var miniLevel:String? {miniGame?.runLevel?.profile}
    /// Whether the picker names another level than the unfinished game in progress plays at. That game keeps its
    /// level, and the drawer offers a new game at the chosen one.
    /// A game at a withdrawn level offers a new game at the preferred one even before its first move.
    public var miniNewLevelOffered:Bool {guard let game=miniGame,!game.isFinished,let level=miniLevel else{return false};return level != miniPreferredLevel && (!game.history.isEmpty || miniLevelWithdrawn)}
    /// Whether the game shown plays the computer at a level its game no longer offers (calibration withdrew it after the
    /// run started). The run finishes at that level, labelled; new runs take an offered one.
    public var miniLevelWithdrawn:Bool {guard let game=miniGame,game.computer,let level=miniLevel else{return false};return !MiniGameOffering.levels(for:game.kind).contains(level)}
    /// Chooses the level of this game's next runs. A game with no move yet restarts at it, losing nothing; a game in
    /// progress keeps its level (`miniNewLevelOffered`).
    public func setMiniLevel(_ level:String){
        guard mini,MiniGameOffering.levels(for:miniKind).contains(level) else{return}
        var settings=session.state.settings;settings.miniOpponentProfiles[miniKind.rawValue]=level;session.updateSettings(settings)
        if miniGame?.history.isEmpty != false,miniLevel != level{restartMini()}
    }
    public func setMiniComputer(_ enabled:Bool){cancelMiniOpponent();miniReview.cancel();miniGame?.computer=enabled && !miniKind.solo;picked=[];syncMini();scheduleMiniOpponent()}
    public func undoMini(){onMiniReset?();cancelMiniOpponent();miniReview.cancel();if var game=miniGame{MiniGameSides.undo(&game,learner:miniLearnerSide);miniGame=game};picked=[];feedback="";syncMini();scheduleMiniOpponent()}
    /// Back to where the game was opened: its lesson, or the training library.
    public func leaveMini(){onMiniReset?();cancelMiniOpponent();miniReview.cancel();picked=[];feedback="";if miniFromLibrary{go(.trainingLibrary);session.setTraining(.library);return};go(miniLesson);rebuild()}
    private func clickMini(_ square:String){
        guard let game=miniGame,!game.isFinished,!miniThinking,!(game.computer && game.turn != miniLearnerSide) else{return}
        if let from=picked.first,game.destinations(from:from).contains(square){applyMini(MiniGameMove(from:from,to:square));scheduleMiniOpponent();return}
        picked=game.board[square]?.hasPrefix(game.turn)==true && game.kind.canMove(game.board[square]!) ? (picked==[square] ? []:[square]):[]
        feedback=picked.isEmpty ? String(localized:"Select one of your movable pieces.",bundle:.checkmate):"";publish()
    }
    /// The clock and calendar completion events are stamped with; tests inject fixed ones.
    public var now:()->Date={Date()}
    public var calendar=Calendar.current
    private func applyMini(_ move:MiniGameMove){
        guard var game=miniGame,let piece=game.board[move.from] else{return}
        let captured=game.board[move.to],color=game.turn,wasFinished=game.isFinished
        guard game.play(move) else{return};miniGame=game;picked=[];feedback=""
        // Emit-only: an observed unfinished-to-finished transition adds a completion event to the same state save as
        // the board (syncMini). It never changes the game or its result; a loaded finished board adds nothing.
        if !wasFinished,game.isFinished{TrainingStore.recordLegacyCompletion(game,learner:miniLearnerSide,origin:miniFromLibrary ? "library":"lesson",in:&session.state,now:now(),calendar:calendar);countMini(game)}
        syncMini()
        if !wasFinished,game.isFinished{miniReview.start(game,learner:miniLearnerSide)}
        onMiniMove?(MoveRecord(color:color,from:move.from,to:move.to,piece:String(piece.suffix(1)),flags:captured==nil ? "n":"c",san:move.from+"–"+move.to,before:"",after:"",captured:captured.map{String($0.suffix(1))},promotion:nil))
    }
    /// Every save of the board rewrites its level's witness, so a later mismatch can only come from another build.
    private func syncMini(){
        guard var game=miniGame else{return};game.stampWitness();if game != miniGame{miniGame=game};miniTurn=game.turn
        let highlights=game.snapshot.lastMove.map{[Highlight(sq:$0.from,kind:"last"),Highlight(sq:$0.to,kind:"last")]} ?? []
        frame=CourseFrame(board:game.board,hl:highlights,counts:game.kind.solo ? Array(MiniGameRules.corners.dropFirst(game.snapshot.cornerIndex)):nil)
        if session.state.miniGames==nil{session.state.miniGames=[:]};session.state.miniGames?[game.kind.rawValue]=game
        publish();session.emit(semantic:false,save:true)
    }
    private func cancelMiniOpponent(){miniGeneration=UUID();miniTask?.cancel();miniTask=nil;miniThinking=false}
    /// The opponent profile the pending reply is searching with.
    /// The level the latest computer reply was searched at, so tests can observe it without re-running a search
    /// whose time limit makes its move depend on machine load.
    private(set) var miniProfile=""
    /// How many computer replies have been requested, so tests can tell a request left alone from a replaced one.
    private(set) var miniReplyRequests=0
    /// A review keeps the place (and mode) of the game but owns the board: no computer reply is queued or played behind it.
    /// A game opened from the library is in training mode with the same rules and opponent. The reply searches at the
    /// run's level, never at the current setting.
    private func scheduleMiniOpponent(){
        guard mini,!session.reviewSuspended,let game=miniGame,game.computer,game.turn != miniLearnerSide,!game.isFinished else{return}
        cancelMiniOpponent();miniThinking=true;picked=[];let generation=miniGeneration;miniReplyRequests+=1
        let delay=MiniGameOpponent.replyDelay+Duration.milliseconds(Int64(session.state.settings.pieceDuration))
        // `startMini` settles every competitive run's level, so the fallback is never reached in practice.
        let profile=game.runLevel?.profile ?? MiniGameOffering.fallbackLevel;miniProfile=profile
        let worker=Task.detached(priority:.userInitiated){MiniGameOpponent.choose(in:game,profile:profile,seed:(UInt64(game.opponentSeed ?? "1",radix:16) ?? 1) &+ UInt64(game.history.count+1))}
        miniTask=Task{[weak self] in
            await withTaskCancellationHandler(operation:{
                let started=ContinuousClock.now,move=await worker.value
                do{try await Task.sleep(for:max(.zero,delay-started.duration(to:.now)))}catch{return}
                guard let self=self,!Task.isCancelled,self.miniGeneration==generation else{return}
                // The current reply is over either way; one that can no longer apply (a review opened) is re-queued on return.
                self.miniTask=nil;self.miniThinking=false
                guard self.mini,!self.session.reviewSuspended,self.miniGame==game,let move=move else{return}
                self.applyMini(move)
            },onCancel:{worker.cancel()})
        }
    }
    /// A language or voice change reloads narration packs, but a mini-game's pending computer reply must still be
    /// rescheduled: the reload must never swallow it.
    /// Other settings (a volume drag sends dozens, a level change too) leave a reply in flight alone: it searches at the
    /// run's level, which no setting changes, and restarts only when a pause cancelled it. Likewise narration restarts
    /// only when switched on or off or (un)muted; a volume change adjusts the playing clip.
    public func settingsChanged(){let settings=session.state.settings,selectionChanged=loadedSelection != settings.lessonLanguage+"|"+settings.lessonVoice;if selectionChanged{reloadLocalizedPacks()};if mini{if !session.reviewSuspended,!miniThinking || miniProfile != miniGame?.runLevel?.profile{cancelMiniOpponent();scheduleMiniOpponent()};return};guard !selectionChanged,session.mode == .lesson,activePuzzle==nil,!mini else{return}
        if playing{if settings.narration != narrationApplied.on || (settings.volume>0) != (narrationApplied.volume>0){playNarration()}else if settings.volume != narrationApplied.volume{narrationApplied.volume=settings.volume;audio?.setNarrationVolume(settings.volume)}};rebuild()}
    private func rebuild(){
        if attemptStep{frame=attemptFrame;picked=attempt.selected.map{[$0]} ?? [];publish();return}
        do{frame=try library.frame(lesson:lessonIndex,step:step,seconds:seconds,duration:Double(session.state.settings.pieceDuration)/1000,narrationSeconds:narrationSeconds,useCues:localizedPacks[lessonIndex]==nil,staged:illustrationPlayed)}catch{feedback=String(localized:"The lesson illustration could not load.",bundle:.checkmate)}
        if playing {
            var board=library.referenceFrames[lessonIndex][step].start.board ?? [:]
            let times=library.moveTimes(lesson:lessonIndex,step:step,narrationSeconds:narrationSeconds,pieceDuration:Double(session.state.settings.pieceDuration)/1000,useCues:localizedPacks[lessonIndex]==nil)
            for (i,move) in beat.moves.enumerated(){
                if seconds>=times[i],!soundedMoves.contains(i),let piece=board[move[0]] {
                    soundedMoves.insert(i);onIllustration?(String(piece.suffix(1)),board[move[1]] != nil)
                }
                try? CourseLibrary.apply(&board,moves:[move])
            }
        }
        publish()
    }

    /// Whether narration is actually sounding, read from the narration service rather than from intent: its
    /// `playbackTime` exists only while a player is playing, so a muted, failed, stopped, finished or absent player
    /// (and the silent automation policy, which never starts one) all report false.
    private var narrationAudible:Bool {audio?.playbackTime != nil}
    /// Set when a publish was held back because a review owns the board; `resumeMiniOpponent` delivers it on return.
    private var publishDeferred=false
    private func publish(){guard session.mode != .practice else{return};guard !session.reviewSuspended else{publishDeferred=true;return};publishDeferred=false
        // Training shows only a library-opened mini-game from here; its library and exercises have their own controller.
        if session.mode == .training{if mini{publishTrainingMini()};return}
        // The library has no board or lesson of its own: whatever paused, it stays the library.
        if session.activity.place == .puzzleLibrary{session.setLesson(LessonProjection(mode:"quick_puzzle",pieces:nil,title:String(localized:"Quick puzzles",bundle:.checkmate),lessonId:"puzzle-library",step:0,prompt:nil,choices:nil,playing:false,narrationActive:false,moving:false,turn:nil,winner:nil,rules:nil));return};let e=mini ? nil:exercise;session.setLesson(LessonProjection(mode:mini ? (miniKind == .pawnDuel ? "pawn_duel":"mini_game"):activePuzzle != nil ? "quick_puzzle":"lesson",pieces:frame.board,title:mini ? miniKind.title:activePuzzle?.title ?? current.title,lessonId:activePuzzle?.id ?? current.id,step:activePuzzle != nil ? 0:step,prompt:e?.prompt,choices:e?.kind=="choice" ? e?.choices:nil,playing:playing,narrationActive:narrationAudible,moving:frame.motion != nil,turn:mini ? miniTurn:attemptStep ? attempt.rules.turn:nil,winner:winner,rules:mini ? miniRules:nil,drawReason:mini ? miniGame?.drawReason:nil,attempt:attemptStep && !mini && e==nil ? attempt.projection:nil))}
    /// The shown mini-game's rules, the same from its lesson and from the training library.
    private var miniRules:[String] {miniKind == .pawnDuel ? [String(localized:"Reach the far rank with a pawn, capture every opposing pawn, or leave the opponent without a move.",bundle:.checkmate),String(localized:"Pawns move forward and capture diagonally. A pawn on its starting rank may advance two empty squares.",bundle:.checkmate),Sentences.join(String(localized:"No en passant. Pawns stay pawns at the far rank.",bundle:.checkmate),MiniGameState.drawRules)]:[miniKind.rules]}
    /// The truthful training projection of a library-opened mini-game: the same board, rules and outcome as from its lesson.
    private func publishTrainingMini(){
        let finished=miniGame?.isFinished==true
        session.setTraining(TrainingProjection(view:"legacy_game",entryId:miniKind.rawValue,title:miniKind.title,objective:TrainingObjectiveKind.legacyGame.rawValue,ruleMode:TrainingRuleMode.simplifiedVariant.rawValue,rules:miniRules,pieces:frame.board,turn:miniTurn,learnerSide:miniLearnerSide,status:finished ? "finished":"active",winner:winner,drawReason:miniGame?.drawReason))
    }
    public func shutdown(){packReloadTask?.cancel();packGeneration=UUID();pause();miniReview.cancel();attempt.close();audio?.stop()}
}
