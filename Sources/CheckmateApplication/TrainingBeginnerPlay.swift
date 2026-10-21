import CheckmateAssets
import CheckmateDomain
/// Increment B play on the immutable validated content (plan: multi-move runtime): the learner decides at teaching
/// nodes, the published reply is shown after each move, and a technical fault voids only the uncommitted ply. The app
/// never searches at runtime.
extension TrainingController {
    func clickBeginner(_ square:String){
        guard var state=exercise else{return}
        switch state.task {
        case .select:toggle(&state,square);exercise=state;publish()
        case .move,.game:
            let mover=state.scenario.learner
            if let from=state.picked,from != square {
                // A castling question grades king-onto-rook as an attempt instead of picking the rook.
                let castlingAttempt=state.scenario.check == .castle && state.board[from]==mover+"k" && state.board[square]==mover+"r"
                if state.board[square]?.hasPrefix(mover) != true || castlingAttempt{attempt(from:from,to:square,promotion:nil);return}
            }
            pick(&state,square);exercise=state;publish()
        default:break
        }
    }
    /// The answers that are right for a choice question, re-derived where cheap and otherwise the validated oracle.
    func correctChoices(_ state:Exercise)throws -> Set<String> {
        let scenario=state.scenario,expected=scenario.expected ?? TrainingExpected()
        guard let legality=state.current ?? state.legality else{throw CheckmateError.invalid(String(localized:"No position.",bundle:.checkmate))}
        switch scenario.check {
        case .castleReason:return Set(try TrainingSpecialRules.castleReasons(legality,destination:scenario.target ?? "").map(\.label))
        case .enPassantChoice:return Set(try TrainingSpecialRules.passantReasons(legality,target:scenario.target ?? "",prelude:scenario.prelude ?? []).map(\.label))
        case .status:return [try legality.status().label]
        case .diagnosis:return Set(expected.choices ?? [])
        default:return Set([expected.choice].compactMap{$0})
        }
    }
    func chooseBeginner(_ option:String){
        guard var state=exercise else{return}
        do {
            let correct=try correctChoices(state),right=correct.contains(option)
            state.snapshot.actions.append(.choose(option))
            if state.scenario.check == .diagnosis {
                guard right else{let answers=correct.sorted().joined(separator:"; ");state.feedback=String(localized:"Not quite. Look again: \(answers).",bundle:.checkmate,comment:"The right answers, separated by semicolons");finish(state,.incorrect);return}
                state.stage=1;state.feedback=Sentences.join(String(localized:"Yes: \(option.prefix(1).lowercased()+option.dropFirst()).",bundle:.checkmate),state.prompt);save(state);return
            }
            state.feedback=Sentences.join(right ? String(localized:"Correct.",bundle:.checkmate):String(localized:"Not quite. The answer is: \(Sentences.either(correct.sorted())).",bundle:.checkmate),state.scenario.explanation)
            finish(state,right ? .correct:.incorrect)
        }catch{fault()}
    }
    /// The scenario's rules at the shown position disagree with its checked content: withdraw it, count nothing.
    func suspend(){
        guard var state=exercise else{return}
        provider?.suspend(state.scenario.id)
        state.status = .suspended;state.feedback=String(localized:"This exercise did not match its checked answers, so it has been withdrawn. Nothing was counted.",bundle:.checkmate);exercise=state
        if session.state.trainingWritable,training.active?.id==state.snapshot.id{var record=training;record.active=nil;session.state.training=record}
        publish();session.emit(semantic:false,save:true)
    }
    private func miss(_ state:Exercise)->String {
        switch state.scenario.check {
        case .castle:return String(localized:"That move is legal, but it is not castling.",bundle:.checkmate)
        case .promotion:return String(localized:"That move does not promote a pawn.",bundle:.checkmate)
        case .enPassant:return String(localized:"That is not the en-passant capture.",bundle:.checkmate)
        case .mateThreatCreate:return String(localized:"After that move you do not threaten checkmate.",bundle:.checkmate)
        default:return String(localized:"That does not reach the goal.",bundle:.checkmate)
        }
    }
    /// The technique a saving move used, named from its actual tags (plan: defense method coverage).
    private func technique(_ state:Exercise,before:Position,outcome:MoveOutcome)->String {
        guard state.scenario.check == .defense,let target=state.scenario.goal?.target,let after=TrainingMaterial.board(fen:outcome.after) else{return ""}
        let names:[TrainingMaterial.DefenseMethod:String]=[.moveAway:String(localized:"moving it away",bundle:.checkmate),.captureAttacker:String(localized:"capturing the attacker",bundle:.checkmate),.protect:String(localized:"protecting it",bundle:.checkmate),.block:String(localized:"blocking the attack",bundle:.checkmate),.other:String(localized:"a move that meets the threat",bundle:.checkmate)]
        let tags=TrainingMaterial.defenseTags(before:before,after:after,from:outcome.from,to:outcome.to,target:target,learner:Character(state.scenario.learner))
        let used=TrainingMaterial.DefenseMethod.allCases.filter(tags.contains).compactMap{names[$0]}
        let methods=used.dropFirst().reduce(used.first ?? ""){String(localized:"\($0) and \($1)",bundle:.checkmate,comment:"Two ways of defending a piece, inside a sentence")}
        return String(localized:"You saved it by \(methods).",bundle:.checkmate,comment:"How the learner's move defended the piece")
    }
    /// A move at a teaching node. Only the move stage takes one: a diagnosis answers its question first.
    func attemptBeginner(from:String,to:String,promotion:String?){
        guard var state=exercise,state.task == .move,let nodes=state.scenario.nodes,let legality=state.current,state.node<nodes.count,state.scenario.fen != nil else{return}
        state.picked=nil;state.pendingPromotion=nil
        let node=nodes[state.node],scenario=state.scenario
        do {
            guard try legality.fingerprint()==node.fingerprint else{suspend();return}
            let grade=try legality.grade(from:from,to:to,promotion:promotion,castling:scenario.check == .castle)
            guard case .legal(let outcome)=grade else{gradeNonlegal(grade,state,from:from,to:to,promotion:promotion,ending:scenario.explanation);return}
            let move=outcome.uci,right=node.accepted.contains(move)
            guard let prepared=try continuation(state,node:node,move:move,right:right) else{suspend();return}
            let reply=prepared.reply,praise=right ? technique(state,before:state.board,outcome:outcome):""
            let moved=try boardAfter(outcome.after),replied=try reply.map{try boardAfter($0.after)}
            state.snapshot.actions.append(.move(from:from,to:to,promotion:outcome.promotion));state.line.append(move)
            state.board=moved;state.lastMove=(from,to)
            if let reply,let replied{state.snapshot.actions.append(.reply(reply.uci));state.line.append(reply.uci);state.board=replied;state.lastMove=(reply.from,reply.to)}
            // The learner's move and the published reply are committed together, and land in that order.
            let land={[weak self] in self?.landed(outcome,from:legality.fen);if let reply{self?.landed(reply,from:outcome.after)}}
            if let after=prepared.after,let next=node.next?[move] {
                state.node=next;state.current=after;clearHints(&state)
                state.feedback=Sentences.join(String(localized:"Good.",bundle:.checkmate),reply.map{String(localized:"The reply was \($0.san).",bundle:.checkmate)} ?? "",String(localized:"Keep going: find the next move.",bundle:.checkmate))
                if save(state){land()};return
            }
            if right{state.feedback=Sentences.join(String(localized:"Correct.",bundle:.checkmate),praise,reply.map{String(localized:"The best reply, \($0.san), does not change that.",bundle:.checkmate)} ?? "",scenario.explanation)}
            else{state.feedback=Sentences.join(reply.map{String(localized:"After \($0.san) it goes wrong.",bundle:.checkmate)} ?? miss(state),scenario.explanation)}
            if finish(state,right ? .correct:.incorrect){land()}
        }catch{fault()}
    }
    /// Everything a legal ply needs, prepared before anything is recorded so a fault voids only this ply: the published
    /// reply and, after a right move that continues, the next teaching position. Nil when the content disagrees with
    /// the rules here (a reply that is not legal, a continuation without its reply or reaching another position).
    private func continuation(_ state:Exercise,node:TrainingTeachingNode,move:String,right:Bool)throws -> (reply:MoveOutcome?,after:TrainingLegality?)? {
        guard let nodes=state.scenario.nodes,let fen=state.scenario.fen else{return nil}
        let base=(state.scenario.prelude ?? [])+state.line,next=right ? node.next?[move]:nil
        guard let answer=node.replies[move] else{if next != nil{return nil};return (nil,nil)}
        let afterMove=try TrainingLegality(fen:fen,prelude:base+[move],runtimeFactory:runtimeFactory)
        guard let reply=try afterMove.legalOutcome(from:String(answer.prefix(2)),to:String(answer.dropFirst(2).prefix(2)),promotion:answer.count==5 ? String(answer.suffix(1)):nil) else{return nil}
        guard let next else{return (reply,nil)}
        let reached=try TrainingLegality(fen:fen,prelude:base+[move,answer],runtimeFactory:runtimeFactory)
        guard nodes.indices.contains(next),try reached.fingerprint()==nodes[next].fingerprint else{return nil}
        return (reply,reached)
    }
    /// The board a validated FEN shows; a FEN that cannot be read is a fault, never the previous board kept.
    func boardAfter(_ fen:String)throws -> Position {
        guard let board=TrainingMaterial.board(fen:fen) else{throw CheckmateError.invalid(String(localized:"A position could not be read.",bundle:.checkmate))}
        return board
    }
    /// Hints belong to the teaching node they were given for: reaching the next node clears them; the recorded help stays.
    private func clearHints(_ state:inout Exercise){state.hintLevel=0;state.hintText=nil;state.hintSquares=[]}
    // MARK: Resume
    /// Whether the last saved action is a learner move still waiting for its published reply. Live play records a
    /// continuing move and its reply together, so a saved attempt never ends between them.
    func awaitingReply(_ state:Exercise)->Bool {if state.scenario.check != nil,state.task == .move,case .move? = state.snapshot.actions.last{return true};return false}
    func replayMove(_ state:inout Exercise,uci:String)throws {
        guard state.task == .move,!awaitingReply(state),let nodes=state.scenario.nodes,let legality=state.current,state.node<nodes.count else{throw CheckmateError.invalid(String(localized:"A saved move no longer applies.",bundle:.checkmate))}
        let node=nodes[state.node]
        guard try legality.fingerprint()==node.fingerprint,node.accepted.contains(uci),node.next?[uci] != nil,let outcome=try legality.outcomes().first(where:{$0.uci==uci}) else{throw CheckmateError.invalid(String(localized:"A saved move no longer applies.",bundle:.checkmate))}
        state.line.append(uci);state.board=try boardAfter(outcome.after);state.lastMove=(outcome.from,outcome.to)
    }
    func replayReply(_ state:inout Exercise,_ move:String)throws {
        guard awaitingReply(state),let nodes=state.scenario.nodes,let fen=state.scenario.fen,let last=state.line.last,state.node<nodes.count,let next=nodes[state.node].next?[last],nodes[state.node].replies[last]==move else{throw CheckmateError.invalid(String(localized:"A saved reply no longer applies.",bundle:.checkmate))}
        let after=try TrainingLegality(fen:fen,prelude:(state.scenario.prelude ?? [])+state.line+[move],runtimeFactory:runtimeFactory)
        guard try after.fingerprint()==nodes[next].fingerprint else{throw CheckmateError.invalid(String(localized:"A saved reply no longer applies.",bundle:.checkmate))}
        state.line.append(move);state.board=try after.board();state.lastMove=(String(move.prefix(2)),String(move.dropFirst(2).prefix(2)));state.node=next;state.current=after;clearHints(&state)
    }
    func replayConcern(_ state:inout Exercise,_ option:String)throws {
        guard try correctChoices(state).contains(option) else{throw CheckmateError.invalid(String(localized:"A saved answer no longer applies.",bundle:.checkmate))}
        state.stage=1
    }
    // MARK: Answers
    func beginnerSquares(_ state:Exercise)throws -> Set<String> {
        let color=Character(state.scenario.askColor ?? state.scenario.learner)
        switch state.scenario.check {
        case .forks:return TrainingRelationship.forks(by:color,board:state.board)
        case .pins:return TrainingRelationship.pinned(color:color,board:state.board)
        case .kingSquares:guard let legality=state.current else{throw CheckmateError.invalid(String(localized:"No position.",bundle:.checkmate))};return try legality.kingDestinations()
        default:return []
        }
    }
    func beginnerSolution(_ state:Exercise)throws -> String {
        switch state.task {
        case .select:let squares=try beginnerSquares(state).sorted();return squares.isEmpty ? String(localized:"The answer is None.",bundle:.checkmate):String(localized:"The answer is \(squares.joined(separator:", ")).",bundle:.checkmate)
        case .choose:let answers=Sentences.either(try correctChoices(state).sorted());return String(localized:"The answer is: \(answers).",bundle:.checkmate)
        case .move:
            guard let legality=state.current,let node=state.scenario.nodes?[state.node] else{return ""}
            let moves=try legality.outcomes().filter{node.accepted.contains($0.uci)}.map(\.san)
            return moves.isEmpty ? String(localized:"No move reaches the goal here.",bundle:.checkmate):String(localized:"Moves that work: \(moves.joined(separator:", ")).",bundle:.checkmate,comment:"Moves separated by commas")
        case .game:return ""
        }
    }
}
