import Foundation
public struct ReviewFact:Codable,Equatable,Identifiable {public let id:String,kind:String,text:String,squares:[String]}
public struct ReviewExplanation:Codable,Equatable {
    public let title:String,summary:String,facts:[ReviewFact],takeaways:[String],historyNote:String?
    private static let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    private static let centralSquares=Set(["d4","d5","e4","e5"])
    public static func make(document:GameDocument,node:Int,evidence:ReviewEvidence?=nil)throws -> ReviewExplanation {
        guard document.nodes.indices.contains(node) else{throw CheckmateError.invalid("Unknown review node.")}
        let n=document.nodes[node],rules=try document.snapshotRules(at:node),status=try document.status(at:node,using:rules)
        var facts:[ReviewFact]=[]
        func add(_ kind:String,_ text:String,_ squares:[String]=[]){let content=kind+"|"+text+"|"+squares.joined(separator:",");facts.append(ReviewFact(id:"\(document.contentHash.prefix(12)):\(node):\(reviewHash(Data(content.utf8)).prefix(16))",kind:kind,text:text,squares:squares))}
        if let parent=n.parent,let uci=n.uci {
            let before=try document.snapshotRules(at:parent),move=try before.move(uci:uci),name=names[move.promotion ?? move.piece] ?? "piece"
            add("move","\(move.color=="w" ? "White":"Black") moved the \(names[move.piece] ?? "piece") from \(move.from) to \(move.to).",[move.from,move.to])
            if let capture=move.captured{let square=move.flags.contains("e") ? String(move.to.prefix(1))+String(move.from.suffix(1)):move.to;add("capture","This captures the \(names[capture] ?? "piece") on \(square).",[square,move.to])}
            if let promotion=move.promotion{add("promotion","The pawn became a \(names[promotion] ?? "piece").",[move.to])}
            if move.flags.contains("k") || move.flags.contains("q"){let rank=move.color=="w" ? "1":"8",rookFrom=(move.flags.contains("k") ? "h":"a")+rank,rookTo=(move.flags.contains("k") ? "f":"d")+rank;add("castle","The king and rook moved together when castling.",[move.from,move.to,rookFrom,rookTo])}
            let controlled=ChessRules.squares.filter{rules.attackers($0,move.color).contains(move.to)}
            let enemy=controlled.filter{rules.piece($0).map{$0.color != move.color} ?? false}
            if !enemy.isEmpty {add("coverage","The \(name) on \(move.to) covers \(enemy.joined(separator:", ")). Check pins and legal replies before treating coverage as a capture.",[move.to]+enemy)}
            else if move.piece=="p",!controlled.isEmpty {add("coverage","The pawn on \(move.to) controls \(controlled.joined(separator:", ")). Another piece needs a legal route to use those squares; this does not establish why the pawn was moved.",[move.to]+controlled)}
            else {let centre=controlled.filter{centralSquares.contains($0)};if !centre.isEmpty{add("centre","From \(move.to), the \(name) controls \(centre.joined(separator:", ")) in the centre.",[move.to]+centre)}}
            let opponent=move.color=="w" ? "b":"w",attackers=rules.attackers(move.to,opponent)
            if !attackers.isEmpty {add("attack","The piece on \(move.to) is covered by an opposing piece from \(attackers.joined(separator:", ")). This is an attack map, not proof that a capture wins material.",[move.to]+attackers)}
            let replies=rules.moves().filter{$0.to==move.to && $0.captured != nil}
            if !replies.isEmpty{add("reply","A legal reply is "+replies.prefix(2).map(\.san).joined(separator:" or ")+". Compare what happens after the capture before calling the piece safe.",[move.to]+replies.prefix(2).map(\.from))}
        }
        if node==0 {add("turn","\(rules.turn=="w" ? "White":"Black") is to move in the displayed position.")}
        if let square=n.uci.map({String($0.dropFirst(2).prefix(2))}),let protection=try? rules.relationships(square,mode:.protected) {
            for relation in protection.relations.prefix(2){add("defender",relation.label+": "+relation.explanation(mode:.protected,legalContext:true,king:protection.piece=="k"),[square,relation.square])}
        }
        if status.checkmate {add("checkmate","The position is checkmate; there is no legal continuation.")}
        else if status.stalemate {add("stalemate","The side to move has no legal moves and is not in check: stalemate.")}
        else if status.insufficientMaterial {add("insufficient","Neither side has enough material to give checkmate: the position is drawn.")}
        else if status.check {add("check","\(rules.turn=="w" ? "White":"Black") is in check and must answer it.")}
        if status.automaticFivefold{add("automatic","This position has occurred five times: an automatic draw.")}
        else if status.claimableThreefold{add("claim","This position has occurred at least three times; a draw may be claimed.")}
        if status.automaticSeventyFiveMove{add("automatic","The seventy-five-move automatic draw applies.")}
        else if status.claimableFiftyMove && !status.checkmate{add("claim","The fifty-move draw can be claimed.")}
        if let e=evidence,e.documentHash==document.contentHash,e.nodeID==node,let best=e.root.lines.first,let uci=best.pv.first {
            let rootNode=n.parent ?? node,prior=try document.snapshotRules(at:rootNode),candidate=try prior.move(uci:uci)
            if n.uci != nil && n.uci != uci {add("alternative","Before \(n.san ?? "the played move"), the engine's leading option is \(candidate.san). \(e.provisional ? "This short search is provisional; compare its legal replies rather than treating it as a verdict.":"The deeper search supports comparing this alternative.")",[candidate.from,candidate.to])}
            else if n.uci==nil && !status.terminal {add("recommendation","The engine's leading option is \(candidate.san). \(e.provisional ? "It is a provisional suggestion from a short search.":"It remained the leading option in the deeper search.")",[candidate.from,candidate.to])}
            if !e.provisional,["near-best","same-mate-outcome","mate-outcome-changed","engine-prefers-alternative"].contains(e.quality) {
                let text:String
                switch e.quality {
                case "near-best":text="The played move is close to the leading alternative at the recorded search budgets."
                case "same-mate-outcome":text="Both measured continuations retain the same mate outcome; their routes and mate distances can differ."
                case "mate-outcome-changed":text="The measured continuations differ in whether the engine finds forced mate. Replay both lines; this is a search result, not proof of the game outcome."
                default:text="The recorded searches prefer a different continuation; replay the line to see its consequences."
                };add("comparison",text)
            }
        }
        var takeaways:[String]=[]
        if node==0 {
        let final=try document.snapshotRules(at:document.mainline.last ?? 0),finalStatus=try document.status(at:document.mainline.last ?? 0,using:final)
        // The recorded result stays independent of the board; a confirmed contradiction is explained, never rewritten.
        let boardResult=finalStatus.checkmate ? (final.turn=="w" ? "0-1":"1-0"):finalStatus.stalemate ? "1/2-1/2":nil
        let contradiction=boardResult.flatMap{expected in document.result != "*" && document.result != expected ? " The record states \(document.result), which differs from this final board; the original record is kept unchanged.":nil} ?? ""
        if finalStatus.checkmate{takeaways.append("The final \(final.turn=="w" ? "White":"Black") king has no legal answer to check. Replay the last moves to see how its escape squares disappeared."+contradiction)}
        else if finalStatus.stalemate{takeaways.append("The final position is stalemate. When ahead, leave the opposing king a legal move unless your move gives checkmate."+contradiction)}
        else if document.result=="*" {takeaways.append("The record stops with \(final.turn=="w" ? "White":"Black") to move. Start by inspecting the threats in that actual position.")}
        else {takeaways.append("The recorded result is \(document.result). \(document.termination.flatMap{value -> String? in let known=["normal","abandoned","adjudication","death","emergency","rules infraction","time forfeit","unterminated"];return known.contains(value.lowercased()) ? "Its stated termination is \(value.lowercased()).":nil} ?? "The record does not state why play ended; legal moves may still remain.")")}
        let captures=document.mainline.compactMap{document.nodes[$0]}.filter{$0.san?.contains("x")==true}
        if let capture=captures.first {takeaways.append("Revisit \(capture.fullmove)\(capture.side=="w" ? ".":"...") \(capture.san ?? ""): compare the material before the capture with the opponent's legal replies.")}
        if let castle=document.mainline.map({document.nodes[$0]}).first(where:{$0.san?.hasPrefix("O-O")==true}){takeaways.append("At \(castle.fullmove)\(castle.side=="w" ? ".":"...") \(castle.san ?? ""), both king and rook change squares. Inspect the king's safety afterward.")}
        }
        let overview="\(document.mainline.count) recorded half-moves. "+(takeaways.first ?? "Inspect the recorded position.")
        return ReviewExplanation(title:node==0 ? "Game overview":"\(n.fullmove)\(n.side=="w" ? ".":"...") \(n.san ?? "Position")",summary:node==0 ? overview:facts.prefix(3).map(\.text).joined(separator:" "),facts:facts,takeaways:Array(takeaways.prefix(3)),historyNote:document.historyAvailable ? nil:"This FEN contains no earlier move history; repetition before this position is unknown.")
    }
    public static func imagined(rules:ChessRules)->ReviewExplanation {
        let text=rules.checkmate ? "This imagined position is checkmate.":rules.check ? "\(rules.turn=="w" ? "White":"Black") is in check in this imagined position.":"This is a separate imagined position, with \(rules.turn=="w" ? "White":"Black") to move. The original record is unchanged."
        let fact=ReviewFact(id:reviewHash(Data((rules.fen+text).utf8)),kind:"imagined",text:text,squares:[])
        return ReviewExplanation(title:"Imagined continuation",summary:text,facts:[fact],takeaways:[],historyNote:nil)
    }
}
