import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
public struct ReviewFact:Codable,Equatable,Identifiable {public let id:String,kind:String,text:String,squares:[String]}
public struct ReviewExplanation:Codable,Equatable {
    public let title:String,summary:String,facts:[ReviewFact],takeaways:[String],historyNote:String?
    static let standardStart="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    private static let centralSquares=Set(["d4","d5","e4","e5"])
    public static func make(document:GameDocument,node:Int,evidence:ReviewEvidence?=nil)throws -> ReviewExplanation {
        guard document.nodes.indices.contains(node) else{throw CheckmateError.invalid(String(localized:"Unknown review node.",bundle:.checkmate))}
        let n=document.nodes[node],rules=try document.snapshotRules(at:node),status=try document.status(at:node,using:rules)
        var facts:[ReviewFact]=[]
        func add(_ kind:String,_ text:String,_ squares:[String]=[]){let content=kind+"|"+text+"|"+squares.joined(separator:",");facts.append(ReviewFact(id:"\(document.contentHash.prefix(12)):\(node):\(reviewHash(Data(content.utf8)).prefix(16))",kind:kind,text:text,squares:squares))}
        if let parent=n.parent,let uci=n.uci {
            let before=try document.snapshotRules(at:parent),move=try before.move(uci:uci),name=PieceName.of(move.promotion ?? move.piece)
            add("move",String(localized:"\(PieceName.side(move.color)) moved the \(PieceName.of(move.piece)) from \(move.from) to \(move.to).",bundle:.checkmate),[move.from,move.to])
            if let capture=move.captured{let square=move.flags.contains("e") ? String(move.to.prefix(1))+String(move.from.suffix(1)):move.to;add("capture",String(localized:"This captures the \(PieceName.of(capture)) on \(square).",bundle:.checkmate),[square,move.to])}
            if let promotion=move.promotion{add("promotion",String(localized:"The pawn became a \(PieceName.of(promotion)).",bundle:.checkmate),[move.to])}
            if move.flags.contains("k") || move.flags.contains("q"){let rank=move.color=="w" ? "1":"8",rookFrom=(move.flags.contains("k") ? "h":"a")+rank,rookTo=(move.flags.contains("k") ? "f":"d")+rank;add("castle",String(localized:"The king and rook moved together when castling.",bundle:.checkmate),[move.from,move.to,rookFrom,rookTo])}
            let controlled=ChessRules.squares.filter{rules.attackers($0,move.color).contains(move.to)}
            let enemy=controlled.filter{rules.piece($0).map{$0.color != move.color} ?? false}
            if !enemy.isEmpty {add("coverage",String(localized:"The \(name) on \(move.to) covers \(enemy.joined(separator:", ")). Check pins and legal replies before treating coverage as a capture.",bundle:.checkmate),[move.to]+enemy)}
            else if move.piece=="p",!controlled.isEmpty {add("coverage",String(localized:"The pawn on \(move.to) controls \(controlled.joined(separator:", ")). Another piece needs a legal route to use those squares; this does not establish why the pawn was moved.",bundle:.checkmate),[move.to]+controlled)}
            else {let centre=controlled.filter{centralSquares.contains($0)};if !centre.isEmpty{add("centre",String(localized:"From \(move.to), the \(name) controls \(centre.joined(separator:", ")) in the center.",bundle:.checkmate),[move.to]+centre)}}
            let opponent=move.color=="w" ? "b":"w",attackers=rules.attackers(move.to,opponent)
            if !attackers.isEmpty {add("attack",String(localized:"The piece on \(move.to) is covered by an opposing piece from \(attackers.joined(separator:", ")). This is an attack map, not proof that a capture wins material.",bundle:.checkmate),[move.to]+attackers)}
            let replies=rules.moves().filter{$0.to==move.to && $0.captured != nil}
            if !replies.isEmpty{add("reply",String(localized:"A legal reply is \(Sentences.either(replies.prefix(2).map(\.san))). Compare what happens after the capture before calling the piece safe.",bundle:.checkmate),[move.to]+replies.prefix(2).map(\.from))}
        }
        if node==0 {add("turn",String(localized:"\(PieceName.side(rules.turn)) is to move in the displayed position.",bundle:.checkmate))}
        if let square=n.uci.map({String($0.dropFirst(2).prefix(2))}),let protection=try? rules.relationships(square,mode:.protected) {
            for relation in protection.relations.prefix(2){add("defender",String(localized:"\(relation.label): \(relation.explanation(mode:.protected,legalContext:true,king:protection.piece=="k"))",bundle:.checkmate,comment:"A defending piece, then what it does"),[square,relation.square])}
        }
        if status.checkmate {add("checkmate",String(localized:"The position is checkmate; there is no legal continuation.",bundle:.checkmate))}
        else if status.stalemate {add("stalemate",String(localized:"The side to move has no legal moves and is not in check: stalemate.",bundle:.checkmate))}
        else if status.insufficientMaterial {add("insufficient",String(localized:"Neither side has enough material to give checkmate: the position is drawn.",bundle:.checkmate))}
        else if status.check {add("check",String(localized:"\(PieceName.side(rules.turn)) is in check and must answer it.",bundle:.checkmate))}
        if status.automaticFivefold{add("automatic",String(localized:"This position has occurred five times: an automatic draw.",bundle:.checkmate))}
        else if status.claimableThreefold{add("claim",String(localized:"This position has occurred at least three times; a draw may be claimed.",bundle:.checkmate))}
        if status.automaticSeventyFiveMove{add("automatic",String(localized:"The seventy-five-move automatic draw applies.",bundle:.checkmate))}
        else if status.claimableFiftyMove && !status.checkmate{add("claim",String(localized:"The fifty-move draw can be claimed.",bundle:.checkmate))}
        if let e=evidence,e.documentHash==document.contentHash,e.nodeID==node,let best=e.root.lines.first,let uci=best.pv.first {
            let rootNode=n.parent ?? node,prior=try document.snapshotRules(at:rootNode),candidate=try prior.move(uci:uci)
            if n.uci != nil && n.uci != uci {let played=n.san ?? String(localized:"the played move",bundle:.checkmate);add("alternative",e.provisional ? String(localized:"Before \(played), the engine's leading option is \(candidate.san). This short search is provisional; compare its legal replies rather than treating it as a verdict.",bundle:.checkmate):String(localized:"Before \(played), the engine's leading option is \(candidate.san). The deeper search supports comparing this alternative.",bundle:.checkmate),[candidate.from,candidate.to])}
            else if n.uci==nil && !status.terminal {add("recommendation",e.provisional ? String(localized:"The engine's leading option is \(candidate.san). It is a provisional suggestion from a short search.",bundle:.checkmate):String(localized:"The engine's leading option is \(candidate.san). It remained the leading option in the deeper search.",bundle:.checkmate),[candidate.from,candidate.to])}
            if !e.provisional,["near-best","same-mate-outcome","mate-outcome-changed","engine-prefers-alternative"].contains(e.quality) {
                let text:String
                switch e.quality {
                case "near-best":text=String(localized:"The played move is close to the leading alternative at the recorded search budgets.",bundle:.checkmate)
                case "same-mate-outcome":text=String(localized:"Both measured continuations retain the same mate outcome; their routes and mate distances can differ.",bundle:.checkmate)
                case "mate-outcome-changed":text=String(localized:"The measured continuations differ in whether the engine finds forced mate. Replay both lines; this is a search result, not proof of the game outcome.",bundle:.checkmate)
                default:text=String(localized:"The recorded searches prefer a different continuation; replay the line to see its consequences.",bundle:.checkmate)
                };add("comparison",text)
            }
        }
        var takeaways:[String]=[]
        if node==0 {
        let final=try document.snapshotRules(at:document.mainline.last ?? 0),finalStatus=try document.status(at:document.mainline.last ?? 0,using:final)
        // The recorded result stays independent of the board; a confirmed contradiction is explained, never rewritten.
        let boardResult=finalStatus.checkmate ? (final.turn=="w" ? "0-1":"1-0"):finalStatus.stalemate ? "1/2-1/2":nil
        let contradiction=boardResult.flatMap{expected in document.result != "*" && document.result != expected ? String(localized:"The record states \(document.result), which differs from this final board; the original record is kept unchanged.",bundle:.checkmate):nil} ?? ""
        if finalStatus.checkmate{takeaways.append(Sentences.join(String(localized:"The final \(PieceName.side(final.turn)) king has no legal answer to check. Replay the last moves to see how its escape squares disappeared.",bundle:.checkmate),contradiction))}
        else if finalStatus.stalemate{takeaways.append(Sentences.join(String(localized:"The final position is stalemate. When ahead, leave the opposing king a legal move unless your move gives checkmate.",bundle:.checkmate),contradiction))}
        else if document.result=="*" {takeaways.append(String(localized:"The record stops with \(PieceName.side(final.turn)) to move. Start by inspecting the threats in that actual position.",bundle:.checkmate))}
        else {
            let known=["normal","abandoned","adjudication","death","emergency","rules infraction","time forfeit","unterminated"] // not localized: PGN Termination tag values
            let ended=document.termination.map{$0.lowercased()}.flatMap{known.contains($0) ? String(localized:"Its stated termination is \($0).",bundle:.checkmate,comment:"The value is the PGN record's own word, such as normal or time forfeit"):nil} ?? String(localized:"The record does not state why play ended; legal moves may still remain.",bundle:.checkmate)
            takeaways.append(Sentences.join(String(localized:"The recorded result is \(document.result).",bundle:.checkmate),ended))
        }
        let captures=document.mainline.compactMap{document.nodes[$0]}.filter{$0.san?.contains("x")==true}
        if let capture=captures.first {takeaways.append(String(localized:"Revisit \(capture.fullmove)\(capture.side=="w" ? ".":"...") \(capture.san ?? ""): compare the material before the capture with the opponent's legal replies.",bundle:.checkmate))}
        if let castle=document.mainline.map({document.nodes[$0]}).first(where:{$0.san?.hasPrefix("O-O")==true}){takeaways.append(String(localized:"At \(castle.fullmove)\(castle.side=="w" ? ".":"...") \(castle.san ?? ""), both king and rook change squares. Inspect the king's safety afterward.",bundle:.checkmate))}
        }
        let overview=Sentences.join(String(localized:"\(document.mainline.count) moves recorded, counting each side's moves separately.",bundle:.checkmate),takeaways.first ?? String(localized:"Inspect the recorded position.",bundle:.checkmate))
        return ReviewExplanation(title:node==0 ? String(localized:"Game overview",bundle:.checkmate):"\(n.fullmove)\(n.side=="w" ? ".":"...") \(n.san ?? String(localized:"Position",bundle:.checkmate))",summary:node==0 ? overview:Sentences.join(facts.prefix(3).map(\.text)),facts:facts,takeaways:Array(takeaways.prefix(3)),historyNote:!document.historyAvailable ? String(localized:"This FEN contains no earlier move history; repetition before this position is unknown.",bundle:.checkmate):document.startingFEN.split(separator:" ").prefix(4) != Self.standardStart.split(separator:" ").prefix(4) ? String(localized:"This game starts from a set-up position; moves before it are unknown, so earlier repetitions are not counted.",bundle:.checkmate):nil)
    }
    public static func imagined(rules:ChessRules)->ReviewExplanation {
        let text=rules.checkmate ? String(localized:"This imagined position is checkmate.",bundle:.checkmate):rules.check ? String(localized:"\(PieceName.side(rules.turn)) is in check in this imagined position.",bundle:.checkmate):String(localized:"This is a separate imagined position, with \(PieceName.side(rules.turn)) to move. The original record is unchanged.",bundle:.checkmate)
        let fact=ReviewFact(id:reviewHash(Data((rules.fen+text).utf8)),kind:"imagined",text:text,squares:[])
        return ReviewExplanation(title:String(localized:"Imagined continuation",bundle:.checkmate),summary:text,facts:[fact],takeaways:[],historyNote:nil)
    }
}
