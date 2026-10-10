import Foundation
public typealias Position=[String:String]
public struct Highlight:Codable,Equatable {public var sq:String;public var kind:String;public init(sq:String,kind:String){self.sq=sq;self.kind=kind}}
public struct PieceMotion:Codable,Equatable {public var from:String,to:String,t:Double}
public struct CourseFrame:Codable,Equatable {
    public var board:Position?,hl:[Highlight],arrows:[[String]],big:String
    public var motion:PieceMotion?,counts:[String]?
    public init(board:Position?=nil,hl:[Highlight]=[],arrows:[[String]]=[],big:String="",motion:PieceMotion?=nil,counts:[String]?=nil){self.board=board;self.hl=hl;self.arrows=arrows;self.big=big;self.motion=motion;self.counts=counts}
}
public struct ReferenceFrame:Codable {public let start:CourseFrame,end:CourseFrame}
public struct CourseVoice:Codable {public let file:String,seconds:Double,duration:Double}
public struct CourseBeat:Decodable {
    public let say:String,speak:String?,set:Position?,hasSet:Bool,moves:[[String]],remove:[String],arrows:[[String]]?,hl:[Highlight]?,count:[String],big:String?,miniGame:Bool,pause:Double?,hasQuiz:Bool
    enum CodingKeys:String,CodingKey {case say,speak,set,moves,remove,arrows,hl,count,big,miniGame,pause,quiz}
    public init(from d:Decoder) throws {let c=try d.container(keyedBy:CodingKeys.self);say=try c.decode(String.self,forKey:.say);speak=try c.decodeIfPresent(String.self,forKey:.speak);hasSet=c.contains(.set);set=try c.decodeIfPresent(Position.self,forKey:.set);moves=try c.decodeIfPresent([[String]].self,forKey:.moves) ?? [];remove=try c.decodeIfPresent([String].self,forKey:.remove) ?? [];arrows=try c.decodeIfPresent([[String]].self,forKey:.arrows);hl=try c.decodeIfPresent([Highlight].self,forKey:.hl);count=try c.decodeIfPresent([String].self,forKey:.count) ?? [];big=try c.decodeIfPresent(String.self,forKey:.big);miniGame=try c.decodeIfPresent(Bool.self,forKey:.miniGame) ?? false;pause=try c.decodeIfPresent(Double.self,forKey:.pause);hasQuiz=c.contains(.quiz)}
}
public struct CourseLesson:Decodable {public let id:String,title:String,teaches:[String]?,mascot:String?,beats:[CourseBeat]}
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
    public var lessonTiming:CourseTiming {timing ?? .standard}
    enum CodingKeys:String,CodingKey {case schemaVersion,lessons,voices,exercises,puzzles,stepTitles,sounds,timing;case referenceFrames="frames"}
    public init() throws {self=try JSONDecoder().decode(Self.self,from:Data(contentsOf:NativeResources.url("course.json")))}
    public func frame(lesson:Int,step:Int,seconds:Double,duration:Double=CourseTiming.standard.pieceDuration) throws -> CourseFrame {
        guard lessons.indices.contains(lesson),lessons[lesson].beats.indices.contains(step) else{throw CheckmateError.invalid("Invalid lesson step.")}
        var state=CourseFrame()
        for i in 0...step {
            let b=lessons[lesson].beats[i]
            state=CourseFrame(board:b.hasSet ? b.set:state.board,hl:b.hl ?? (b.hasSet ? []:state.hl),arrows:b.arrows ?? (b.hasSet ? []:state.arrows),big:b.big ?? state.big)
            if i<step {if var board=state.board {try Self.apply(&board,moves:b.moves,remove:b.remove);state.board=board}}
        }
        let beat=lessons[lesson].beats[step],timing=lessonTiming
        if var board=state.board {
            for (i,m) in beat.moves.enumerated() {
                let elapsed=seconds-timing.movementStart-Double(i)*timing.movementInterval,t=duration==0 ? (elapsed>=0 ? 1.0:0.0):max(0,min(1,elapsed/duration))
                if t>=1 {try Self.apply(&board,moves:[m])}else if t>0 {state.motion=PieceMotion(from:m[0],to:m[1],t:t);break}
            }
            let end=beat.moves.isEmpty ? 0:timing.movementStart+Double(beat.moves.count-1)*timing.movementInterval+timing.pieceDuration
            if seconds>=end+timing.removalDelay {try Self.apply(&board,moves:[],remove:beat.remove)}
            state.board=board
        }
        let spacing=max(timing.minimumCountSpacing,voices[lesson][step].seconds/Double(max(1,beat.count.count)))
        state.counts=Array(beat.count.prefix(max(0,Int(floor(seconds/spacing))+1)))
        return state
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
        guard from != to,let p=board[from],ChessRules.validSquare(from),ChessRules.validSquare(to) else{return false}
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
