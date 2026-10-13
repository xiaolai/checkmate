import CheckmateAssets
import Foundation
public typealias Position=[String:String]
public struct Highlight:Codable,Equatable {public var sq:String;public var kind:String;public init(sq:String,kind:String){self.sq=sq;self.kind=kind}}
public struct PieceMotion:Codable,Equatable {public init(from:String,to:String,t:Double){self.from=from;self.to=to;self.t=t}
public var from:String,to:String,t:Double}
/// `guards` are lesson guard lines: the piece on the first square covers the second, an empty square or a piece of its
/// own side. They are drawn apart from `arrows`, which show moves and attacks.
public struct CourseFrame:Codable,Equatable {
    public var board:Position?,hl:[Highlight],arrows:[[String]],guards:[[String]],big:String
    public var motion:PieceMotion?,counts:[String]?
    public init(board:Position?=nil,hl:[Highlight]=[],arrows:[[String]]=[],guards:[[String]]=[],big:String="",motion:PieceMotion?=nil,counts:[String]?=nil){self.board=board;self.hl=hl;self.arrows=arrows;self.guards=guards;self.big=big;self.motion=motion;self.counts=counts}
    enum CodingKeys:String,CodingKey {case board,hl,arrows,guards,big,motion,counts}
    public init(from d:Decoder) throws {let c=try d.container(keyedBy:CodingKeys.self);board=try c.decodeIfPresent(Position.self,forKey:.board);hl=try c.decode([Highlight].self,forKey:.hl);arrows=try c.decode([[String]].self,forKey:.arrows);guards=try c.decodeIfPresent([[String]].self,forKey:.guards) ?? [];big=try c.decode(String.self,forKey:.big);motion=try c.decodeIfPresent(PieceMotion.self,forKey:.motion);counts=try c.decodeIfPresent([String].self,forKey:.counts)}
}
/// One sentence's share of a staged beat's illustration. Stages accumulate: stage k shows with every stage before it.
public struct CourseStage:Decodable,Equatable {public let hl:[Highlight],arrows:[[String]],guards:[[String]]}
public struct ReferenceFrame:Codable {public let start:CourseFrame,end:CourseFrame}
public struct CourseVoice:Codable {public init(file:String,seconds:Double,duration:Double){self.file=file;self.seconds=seconds;self.duration=duration}
public let file:String,seconds:Double,duration:Double}
public struct CourseBeat:Decodable {
    public let id:String?,say:String,speak:String?,set:Position?,hasSet:Bool,moves:[[String]],remove:[String],arrows:[[String]]?,hl:[Highlight]?,count:[String],big:String?,miniGame:Bool,pause:Double?,moveCues:[Double]?
    /// A beat's own guard lines; absent means none, never the previous beat's.
    public let guards:[[String]]?
    /// A still beat may reveal its overlays sentence by sentence: stage 0 from the start, stage k at `stageCues[k-1]`
    /// of the narration. Its `hl`, `arrows` and `guards` are all its stages together.
    public let stages:[CourseStage]?,stageCues:[Double]?
    enum CodingKeys:String,CodingKey {case id,say,speak,set,moves,remove,arrows,hl,count,big,miniGame,pause,moveCues,guards,stages,stageCues}
    public init(from d:Decoder) throws {let c=try d.container(keyedBy:CodingKeys.self);id=try c.decodeIfPresent(String.self,forKey:.id);say=try c.decode(String.self,forKey:.say);speak=try c.decodeIfPresent(String.self,forKey:.speak);hasSet=c.contains(.set);set=try c.decodeIfPresent(Position.self,forKey:.set);moves=try c.decodeIfPresent([[String]].self,forKey:.moves) ?? [];remove=try c.decodeIfPresent([String].self,forKey:.remove) ?? [];arrows=try c.decodeIfPresent([[String]].self,forKey:.arrows);hl=try c.decodeIfPresent([Highlight].self,forKey:.hl);count=try c.decodeIfPresent([String].self,forKey:.count) ?? [];big=try c.decodeIfPresent(String.self,forKey:.big);miniGame=try c.decodeIfPresent(Bool.self,forKey:.miniGame) ?? false;pause=try c.decodeIfPresent(Double.self,forKey:.pause);moveCues=try c.decodeIfPresent([Double].self,forKey:.moveCues);if let cues=moveCues {guard cues.count==moves.count,cues.allSatisfy({$0.isFinite && (0...1).contains($0)}),zip(cues,cues.dropFirst()).allSatisfy({$0.0 <= $0.1}) else{throw CheckmateError.invalid("Invalid authored movement cues.")}}
        guards=try c.decodeIfPresent([[String]].self,forKey:.guards);stages=try c.decodeIfPresent([CourseStage].self,forKey:.stages);stageCues=try c.decodeIfPresent([Double].self,forKey:.stageCues)
        if let stages {guard stages.count>=2,moves.isEmpty,remove.isEmpty else{throw CheckmateError.invalid("Invalid authored stages.")}}
        if let cues=stageCues {guard let stages,cues.count==stages.count-1,cues.allSatisfy({$0.isFinite && $0>0 && $0<1}),zip(cues,cues.dropFirst()).allSatisfy({$0.0 < $0.1}) else{throw CheckmateError.invalid("Invalid authored stage cues.")}}}
}
/// `practiceFor` names the main lesson a practice activity belongs to. It groups the activity under that lesson and
/// keeps it off the main path; its identity, narration and saved progress are those of any other lesson.
public struct CourseLesson:Decodable {public let id:String,title:String,teaches:[String]?,mascot:String?,practiceFor:String?,practice:LessonPractice?,beats:[CourseBeat]
    public var isPractice:Bool {practiceFor != nil}
}
public struct Exercise:Codable {
    public let kind:String,prompt:String,answers:[String]?,allowNone:Bool?,choices:[String]?,answer:String?,from:String?,to:String?,alternatives:[[String]]?
    public var referenceAnswer:[String] {switch kind {case "choice":return answer.map{[$0]} ?? [];case "squares":return answers ?? [];case "move":return alternatives?.first ?? [from ?? "",to ?? ""];default:return []}}
    public func matches(_ value:[String])->Bool {switch kind {case "choice":return value.count==1 && value.first==answer;case "squares":return value.count==(answers ?? []).count && Set(value).count==value.count && Set(value)==Set(answers ?? []);case "move":return (alternatives ?? [[from ?? "",to ?? ""]]).contains(value);default:return false}}
}
public struct Puzzle:Codable {public let id:String,title:String,topic:String,level:String,exercise:Exercise,board:Position?,highlights:[Highlight],context:String,explanation:String}
public struct Tone:Codable,Equatable {public let at:Double,duration:Double,from:Double,to:Double,gain:Double,wave:String;public init(at:Double,duration:Double,from:Double,to:Double,gain:Double,wave:String){self.at=at;self.duration=duration;self.from=from;self.to=to;self.gain=gain;self.wave=wave}}
public struct CourseTiming:Codable,Equatable {
    public let frameRate:Double,movementStart:Double,movementInterval:Double,pieceDuration:Double,removalDelay:Double,minimumCountSpacing:Double,postNarrationGap:Double
    public static let standard=CourseTiming(frameRate:30,movementStart:0.25,movementInterval:0.95,pieceDuration:0.7,removalDelay:0.75,minimumCountSpacing:0.2,postNarrationGap:0.5)
}
public struct CourseLibrary:Decodable {
    public let schemaVersion:Int,lessons:[CourseLesson],voices:[[CourseVoice]],exercises:[String:Exercise],puzzles:[Puzzle],stepTitles:[[String]],referenceFrames:[[ReferenceFrame]],sounds:[String:[Tone]]
    public let timing:CourseTiming?
    public let retiredExerciseIDs:[String]?
    public var lessonTiming:CourseTiming {timing ?? .standard}
    enum CodingKeys:String,CodingKey {case schemaVersion,lessons,voices,exercises,puzzles,stepTitles,sounds,timing,retiredExerciseIDs;case referenceFrames="frames"}
    public init() throws {self=try JSONDecoder().decode(Self.self,from:Data(contentsOf:NativeResources.url("course.json")))}
    /// Older saves used the original transcript index. Stable recording IDs let
    /// them resume at the same explanation, or after a retired question.
    public func resumeStep(in lesson:CourseLesson,progress:CourseProgress)->Int {
        if let id=progress.segmentID,let step=lesson.beats.firstIndex(where:{$0.id==id}){return step}
        let original=progress.segmentID.flatMap{Int($0.split(separator:":").last ?? "")} ?? max(0,progress.step)
        return lesson.beats.firstIndex{(Int($0.id?.split(separator:":").last ?? "") ?? 0)>=original} ?? lesson.beats.count-1
    }
    /// The practice activities that belong to a main lesson, in course order.
    public func practice(for index:Int)->[Int] {guard lessons.indices.contains(index),!lessons[index].isPractice else{return []};return lessons.indices.filter{lessons[$0].practiceFor==lessons[index].id}}
    /// Where the main path continues: the next main lesson after this lesson, or after the parent of a practice activity.
    public func nextMainLesson(after index:Int)->Int? {guard lessons.indices.contains(index) else{return nil};return lessons.indices.first{$0>index && !lessons[$0].isPractice}}
    /// Where the main path came from: the nearest main lesson before this one. For a practice activity that is its parent.
    public func previousMainLesson(before index:Int)->Int? {guard lessons.indices.contains(index) else{return nil};return lessons.indices.last{$0<index && !lessons[$0].isPractice}}
    public func knownAnswerID(_ id:String)->Bool {exercises[id] != nil || retiredExerciseIDs?.contains(id)==true}
    /// Cue fractions are relative to narration duration, so longer translated clips never race at English speed.
    /// Explicit cues are measured against the bundled recording; recordings without them use paced illustration.
    public func moveTimes(lesson:Int,step:Int,narrationSeconds:Double,pieceDuration:Double,useCues:Bool=true)->[Double] {
        let beat=lessons[lesson].beats[step],n=beat.moves.count
        let fractions=(useCues ? beat.moveCues:nil) ?? (0..<n).map{n==1 ? 0.05:(Double($0)+0.15)/Double(n)}
        var previous = -pieceDuration
        return fractions.map {fraction in
            let at=max(lessonTiming.movementStart,max(fraction*narrationSeconds,previous+pieceDuration))
            previous=at;return at
        }
    }
    public func playbackDuration(lesson:Int,step:Int,narrationSeconds:Double,pieceDuration:Double,useCues:Bool=true)->Double {
        let beat=lessons[lesson].beats[step],t=lessonTiming
        let last=moveTimes(lesson:lesson,step:step,narrationSeconds:narrationSeconds,pieceDuration:pieceDuration,useCues:useCues).last
        let movement=(last.map{$0+pieceDuration} ?? 0)+(beat.remove.isEmpty ? 0:t.removalDelay)
        let count=Double(max(0,beat.count.count-1))*max(t.minimumCountSpacing,narrationSeconds/Double(max(1,beat.count.count)))
        return max(narrationSeconds,max(movement,count))+max(0,beat.pause ?? 0)+t.postNarrationGap
    }
    /// When each stage after the first of a staged beat appears. English narration uses the stage's aligned cues; a
    /// recording without them (a translation) spreads the stages evenly, an approximation of its sentences.
    public func stageTimes(lesson:Int,step:Int,narrationSeconds:Double,useCues:Bool=true)->[Double] {
        let beat=lessons[lesson].beats[step],n=beat.stages?.count ?? 0
        guard n>1 else{return []}
        return ((useCues ? beat.stageCues:nil) ?? (1..<n).map{Double($0)/Double(n)}).map{$0*narrationSeconds}
    }
    /// What the step shows `seconds` into its playback. `staged` paces a staged beat's stages; a step read while paused,
    /// before playback started, passes false and shows all of them, so stepping through never hides an illustration.
    public func frame(lesson:Int,step:Int,seconds:Double,duration:Double=CourseTiming.standard.pieceDuration,narrationSeconds:Double?=nil,useCues:Bool=true,staged:Bool=true) throws -> CourseFrame {
        guard lessons.indices.contains(lesson),lessons[lesson].beats.indices.contains(step) else{throw CheckmateError.invalid("Invalid lesson step.")}
        var state=CourseFrame(),previous=CourseFrame()
        for i in 0...step {
            let b=lessons[lesson].beats[i]
            previous=state
            state=CourseFrame(board:b.hasSet ? b.set:state.board,hl:b.hl ?? (b.hasSet ? []:state.hl),arrows:b.arrows ?? (b.hasSet ? []:state.arrows),guards:b.guards ?? [],big:b.big ?? state.big)
            if i<step {if var board=state.board {try Self.apply(&board,moves:b.moves,remove:b.remove);state.board=board}}
        }
        let beat=lessons[lesson].beats[step],timing=lessonTiming
        let times=moveTimes(lesson:lesson,step:step,narrationSeconds:narrationSeconds ?? voices[lesson][step].seconds,pieceDuration:duration,useCues:useCues)
        let end=times.last.map{$0+duration} ?? 0,start=state.board ?? [:]
        if var board=state.board {
            for (i,m) in beat.moves.enumerated() {
                let elapsed=seconds-times[i],t=duration==0 ? (elapsed>=0 ? 1.0:0.0):max(0,min(1,elapsed/duration))
                if t>=1 {try Self.apply(&board,moves:[m])}else if t>0 {state.motion=PieceMotion(from:m[0],to:m[1],t:t);break}
            }
            if seconds>=end+timing.removalDelay {try Self.apply(&board,moves:[],remove:beat.remove)}
            state.board=board
        }
        // A beat's arrows and highlights describe the position its moves produce, so they appear when the last move
        // lands. Until then only what the previous beat left up stays, with arrows previewing this beat's moves.
        // Tools/import-cedar-recordings.py stages each published start frame by the same rules.
        if !beat.moves.isEmpty,seconds<end {
            let previews=Self.movePreviews(start,moves:beat.moves,arrows:state.arrows)
            state.arrows=state.arrows.filter{previous.arrows.contains($0) || previews.contains($0)}
            state.hl=state.hl.filter{previous.hl.contains($0)}
        }
        // A guard appears on the first of the beat's boards (its start, a landing, after the removals) from which it
        // shows what it shows at the end, so it is never drawn before its pieces arrive or while it is untrue.
        if !beat.moves.isEmpty || !beat.remove.isEmpty,!state.guards.isEmpty {
            var boards=[start],board=start
            for m in beat.moves {try Self.apply(&board,moves:[m]);boards.append(board)}
            if !beat.remove.isEmpty {try Self.apply(&board,moves:[],remove:beat.remove);boards.append(board)}
            let shown=times.map{$0+duration}+(beat.remove.isEmpty ? []:[end+timing.removalDelay])
            state.guards=state.guards.filter{guardLine in Self.guardReveal(boards,guardLine).map{$0==0 || seconds>=shown[$0-1]} ?? false}
        }
        if let stages=beat.stages,staged {
            let reached=1+stageTimes(lesson:lesson,step:step,narrationSeconds:narrationSeconds ?? voices[lesson][step].seconds,useCues:useCues).filter{seconds>=$0}.count
            state.hl=[];state.arrows=[];state.guards=[]
            for stage in stages.prefix(reached) {
                state.hl+=stage.hl.filter{!state.hl.contains($0)};state.arrows+=stage.arrows.filter{!state.arrows.contains($0)};state.guards+=stage.guards.filter{!state.guards.contains($0)}
            }
        }
        let spacing=max(timing.minimumCountSpacing,(narrationSeconds ?? voices[lesson][step].seconds)/Double(max(1,beat.count.count)))
        state.counts=Array(beat.count.prefix(max(0,Int(floor(seconds/spacing))+1)))
        return state
    }
    /// Arrows that show before a beat's moves land: the moves, and another piece of the mover's side that could have made
    /// the same move to an empty square on the starting board. Mirrors `move_previews` in Tools/prepare-lesson-scripts.py.
    public static func movePreviews(_ board:Position,moves:[[String]],arrows:[[String]])->[[String]] {
        var previews=moves.map{Array($0.prefix(2))}
        for arrow in arrows where arrow.count==2 && !previews.contains(arrow) {
            guard let side=board[arrow[0]]?.first,board[arrow[1]]==nil,!moves.contains(where:{$0[0]==arrow[0]}),moves.contains(where:{$0[1]==arrow[1] && board[$0[0]]?.first==side}),attacks(board,from:arrow[0],to:arrow[1]) else{continue}
            previews.append(arrow)
        }
        return previews
    }
    /// Whether a guard line holds on `board`: its piece reaches the square, which is empty or holds a piece of its side.
    public static func guardHolds(_ board:Position,_ guardLine:[String])->Bool {
        guard guardLine.count==2,let piece=board[guardLine[0]],attacks(board,from:guardLine[0],to:guardLine[1]) else{return false}
        return board[guardLine[1]].map{$0.first==piece.first} ?? true
    }
    /// The first of `boards` from which a guard holds with the pieces of the last board on both its squares, on every
    /// later board too; nil if it does not hold at the end. Mirrors `guard_reveal` in Tools/prepare-lesson-scripts.py.
    public static func guardReveal(_ boards:[Position],_ guardLine:[String])->Int? {
        guard let last=boards.last else{return nil}
        var first:Int?
        for index in boards.indices.reversed() {
            let board=boards[index]
            guard guardHolds(board,guardLine),guardLine.allSatisfy({board[$0]==last[$0]}) else{break}
            first=index
        }
        return first
    }
    public static func apply(_ board:inout Position,moves:[[String]],remove:[String]=[]) throws {
        for m in moves {guard m.count>=2,let piece=board.removeValue(forKey:m[0]) else{throw CheckmateError.invalid("Invalid authored move.")};board[m[1]]=m.count>2 ? m[2]:piece}
        for sq in remove {guard board.removeValue(forKey:sq) != nil else{throw CheckmateError.invalid("Invalid authored removal.")}}
    }
    public static func pawnMoves(_ board:Position,from:String)->[String] {
        guard let p=board[from],p.last=="p",let rank=Int(from.suffix(1)),let file=from.utf8.first else{return []}
        let d=p.first=="w" ? 1:-1
        func sq(_ f:Int,_ r:Int)->String? {(97...104).contains(f) && (1...8).contains(r) ? String(UnicodeScalar(f)!)+String(r):nil}
        var moves:[String]=[]
        if let one=sq(Int(file),rank+d),board[one]==nil {moves.append(one);if rank==(d==1 ? 2:7),let two=sq(Int(file),rank+d*2),board[two]==nil{moves.append(two)}}
        for f in [Int(file)-1,Int(file)+1] {if let to=sq(f,rank+d),let target=board[to],target.first != p.first {moves.append(to)}}
        return moves
    }
    public static func pawnWinner(_ board:Position,turn:String)->String? {
        for (sq,p) in board where (p=="wp" && sq.last=="8") || (p=="bp" && sq.last=="1") {return String(p.prefix(1))}
        return board.contains{String($0.value.prefix(1))==turn && !pawnMoves(board,from:$0.key).isEmpty} ? nil:(turn=="w" ? "b":"w")
    }
    public static func attacks(_ board:Position,from:String,to:String)->Bool {
        guard from != to,let p=board[from],ChessNotation.validSquare(from),ChessNotation.validSquare(to) else{return false}
        let f=Int(from.utf8.first!),t=Int(to.utf8.first!),r=Int(from.suffix(1))!,s=Int(to.suffix(1))!,dx=t-f,dy=s-r
        switch p.last {case "p":return abs(dx)==1 && dy==(p.first=="w" ? 1:-1);case "n":return (abs(dx)==1 && abs(dy)==2)||(abs(dx)==2 && abs(dy)==1);case "k":return max(abs(dx),abs(dy))==1;case "b":guard abs(dx)==abs(dy) else{return false};case "r":guard dx==0 || dy==0 else{return false};case "q":guard dx==0 || dy==0 || abs(dx)==abs(dy) else{return false};default:return false}
        let stepX=dx==0 ? 0:dx>0 ? 1:-1,stepY=dy==0 ? 0:dy>0 ? 1:-1
        var x=f+stepX,y=r+stepY
        while x != t || y != s {if board[String(UnicodeScalar(x)!)+String(y)] != nil{return false};x+=stepX;y+=stepY}
        return true
    }
    public static func safeKingStep(_ board:Position,from:String,to:String)->Bool {
        guard board[from]=="wk",board[to]==nil,attacks(board,from:from,to:to) else{return false}
        var next=board;next[from]=nil;next[to]="wk"
        return !next.contains{$0.value.first=="b" && attacks(next,from:$0.key,to:to)}
    }
}
