import CheckmateDomain
import CheckmateRules
import Foundation
/// The review record of a standard-rule training game (mini-games plan D6): the scenario's own start, written as
/// SetUp/FEN, then its prelude and the moves the saved actions commit (learner moves and `.reply` actions, less what
/// Take back removed). It is built from the attempt alone, never from the practice game (`session.rules`), and its
/// move numbers and first side come from the start's FEN, so a game may begin with Black at any move.
@MainActor public enum TrainingReviewRecord {
    /// The PGN of `snapshot`'s game. `title` is its Event; the learner is "You". The result is the board's (checkmate,
    /// stalemate or an automatic draw), a claimed draw's, or `*` for a game stopped on a board that plays on.
    public static func pgn(_ snapshot:TrainingSessionSnapshot,title:String,calendar:Calendar=Calendar(identifier:.gregorian),runtimeFactory:(() throws -> any ChessScriptRuntime)?=nil)throws -> String {
        let scenario=snapshot.scenario
        guard [.ending,.guidedGame].contains(scenario.check),let start=scenario.fen else{throw CheckmateError.invalid("Only a training game can be reviewed.")}
        let prelude=scenario.prelude ?? [],line=try committed(snapshot.actions,learnerMovesFirst:TrainingLegality(fen:start,prelude:prelude,runtimeFactory:runtimeFactory).turn()==scenario.learner)
        let rules=try runtimeFactory.map{try ChessRules(fen:start,runtimeFactory:$0)} ?? ChessRules(fen:start)
        let sans=try (prelude+line).map{try rules.move(uci:$0).san}
        let result:String
        if try rules.isCheckmate(){result=try rules.currentTurn()=="w" ? "0-1":"1-0"}
        else if try rules.isStalemate(){result="1/2-1/2"}
        else if try rules.automaticDrawReason() != nil{result="1/2-1/2"}
        else if case .claim=snapshot.actions.last{result="1/2-1/2"}
        else{result="*"}
        let day=calendar.dateComponents([.year,.month,.day],from:snapshot.startedAt)
        let opponent=scenario.check == .guidedGame ? "Gentle opponent":"Practice defender"
        let headers=[("Event",title),("Date",String(format:"%04d.%02d.%02d",day.year ?? 0,day.month ?? 0,day.day ?? 0)),("White",scenario.learner=="w" ? "You":opponent),("Black",scenario.learner=="w" ? opponent:"You"),("Result",result),("SetUp","1"),("FEN",start)]
        return headers.map{"[\($0.0) \"\(escaped($0.1))\"]"}.joined(separator:"\n")+"\n\n"+movetext(sans,from:start,result:result)
    }
    /// The plies the actions commit, in order: a move or reply adds one; Take back removes the learner's last move and
    /// everything after it. Hints and a draw claim add nothing. Any other action, or a take-back with nothing to take,
    /// is not a game's and throws.
    static func committed(_ actions:[TrainingAction],learnerMovesFirst:Bool)throws -> [String] {
        var line:[String]=[];let parity=learnerMovesFirst ? 0:1
        for action in actions {
            switch action {
            case .move(let from,let to,let promotion):line.append(from+to+(promotion ?? ""))
            case .reply(let move):line.append(move)
            case .undo:guard let index=line.indices.last(where:{$0 % 2==parity}) else{throw CheckmateError.invalid("A saved undo no longer applies.")};line.removeSubrange(index...)
            case .hint,.claim:break
            default:throw CheckmateError.invalid("This attempt is not a game.")
            }
        }
        return line
    }
    /// Numbered movetext from the start's own move number and side: "37... Qb7 38. Kg8 Qb8# 0-1".
    static func movetext(_ sans:[String],from fen:String,result:String)->String {
        let fields=fen.split(separator:" ");var number=fields.dropFirst(5).first.flatMap{Int($0)} ?? 1,white=fields.dropFirst().first != "b"
        var tokens:[String]=[]
        for (index,san) in sans.enumerated() {
            if white{tokens.append("\(number).")}else if index==0{tokens.append("\(number)...")}
            tokens.append(san);if !white{number+=1};white.toggle()
        }
        return (tokens+[result]).joined(separator:" ")
    }
    private static func escaped(_ value:String)->String {value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")}
}
extension TrainingController {
    /// Whether the shown exercise is a finished game that can be reviewed: an ending or guided game that is over,
    /// won, lost, drawn or ended. A withdrawn board is not offered.
    public func canReview(_ state:Exercise)->Bool {state.task == .game && state.finished && state.status != .suspended}
    /// The review record of the finished game shown. Its replayed moves must be the game the learner saw.
    public func reviewRecord()throws -> Data {
        guard showing,let state=exercise,canReview(state) else{throw CheckmateError.unavailable("Only a finished training game can be reviewed.")}
        let pgn=try TrainingReviewRecord.pgn(state.snapshot,title:state.definition.title,calendar:calendar,runtimeFactory:runtimeFactory)
        guard try TrainingReviewRecord.committed(state.snapshot.actions,learnerMovesFirst:state.parity==0)==state.line else{throw CheckmateError.invalid("This game's saved moves do not match the board.")}
        return Data(pgn.utf8)
    }
}
