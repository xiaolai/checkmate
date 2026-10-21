import AppKit
import CheckmateCore
/// Game ▸ Type a Move… (⌘L, B-23): a move typed in SAN or as squares, played on whatever board takes moves through
/// that board's own path, so its rules, grading and announcements stay its own. Review boards are not included.
extension GameWindow {
    /// Where a typed move goes: the moves the board offers, read against its pieces and side to move, and how the chosen
    /// one is played. `play` returns a refusal when the board turned it down after all.
    struct TypedMoveTarget {let moves:[MoveRecord],board:Position,turn:String,enPassant:String?,inCheck:Bool,asTyped:Bool,play:(TypedMove.Choice)->String?}
    enum TypedMovePlace {
        /// No board here takes moves: the menu item is disabled.
        case none
        /// A board that takes moves, but not now, and why.
        case waiting(String)
        case ready(TypedMoveTarget)
    }
    static let typedMoveUnavailable=String(localized:"Typed moves work in a game, a lesson exercise or a training exercise.",bundle:.checkmate)
    static let notYourMove=String(localized:"It's not your move yet.",bundle:.checkmate)
    var typedMoveAvailable:Bool {if case .none=typedMovePlace(){return false};return true}
    func typedMovePlace()->TypedMovePlace {
        let s=model.session,l=model.learning
        guard !model.review.active,!model.reviewWorkspace else{return .none}
        if s.mode == .network {
            let game=model.network
            guard let seat=game.seat else{return .none}
            if seat == .spectator{return .waiting(String(localized:"You're watching this game, so you can't move.",bundle:.checkmate))}
            guard game.canMove else{return .waiting(game.pending != nil ? String(localized:"Your move is on its way.",bundle:.checkmate):game.rules.turn==game.side ? String(localized:"You can't move right now.",bundle:.checkmate):Self.notYourMove)}
            return .ready(TypedMoveTarget(moves:game.rules.moves(nil),board:game.rules.board,turn:game.rules.turn,enPassant:game.rules.enPassantTarget,inCheck:game.rules.check,asTyped:false){choice in
                game.play(from:choice.from,to:choice.to,promotion:choice.promotion ?? "q");return game.pending==nil ? String(localized:"That move could not be sent. Try again.",bundle:.checkmate):nil})
        }
        if s.mode == .practice {
            if shownHistoryPly != nil{return .waiting(Self.earlierPositionRefusal)}
            if s.finished{return .waiting(String(localized:"The game is over. Start a new game to play again.",bundle:.checkmate))}
            guard s.presentationHidden || s.preview==nil && s.demonstration==nil else{return .waiting(String(localized:"Go back to the game to play a move.",bundle:.checkmate))}
            guard s.rules.turn==s.humanSide,s.busyReason != .opponent else{return .waiting(Self.notYourMove)}
            return .ready(TypedMoveTarget(moves:s.rules.moves(),board:s.rules.board,turn:s.rules.turn,enPassant:s.rules.enPassantTarget,inCheck:s.rules.check,asTyped:false){choice in
                do{try s.playWhite(from:choice.from,to:choice.to,promotion:choice.promotion ?? "q");return nil}catch{return Self.failureMessage(error)}})
        }
        if let training=model.training,let exercise=trainingExercise {
            if exercise.finished{return .waiting(String(localized:"This exercise is finished.",bundle:.checkmate))}
            guard exercise.task == .move || exercise.task == .game else{return .waiting(String(localized:"This exercise asks you to choose squares, not to play a move.",bundle:.checkmate))}
            if exercise.task == .game,training.games.thinking{return .waiting(Self.notYourMove)}
            // The exercise grades a raw attempt itself and never reveals its legal moves (training plan rule 3): squares go
            // through as typed, and SAN is read from where the pieces can reach.
            let learner=exercise.scenario.learner,board=exercise.board,passant=exercise.enPassant
            return .ready(TypedMoveTarget(moves:TypedMove.reachable(board:board,turn:learner,enPassant:passant),board:board,turn:learner,enPassant:passant,inCheck:false,asTyped:true){[weak self] choice in
                training.attempt(from:choice.from,to:choice.to,promotion:choice.promotion);if let feedback=training.exercise?.feedback,!feedback.isEmpty{self?.announceTypedMove(feedback)};return nil})
        }
        if l.attemptStep,let attempt=l.attempt {
            guard attempt.learnerToMove else{return .waiting(attempt.phase == .offTrack || attempt.phase == .failed ? attempt.judgement?.feedback ?? Self.notYourMove:Self.notYourMove)}
            return .ready(TypedMoveTarget(moves:attempt.rules.moves(),board:attempt.rules.board,turn:attempt.rules.turn,enPassant:attempt.rules.enPassantTarget,inCheck:attempt.rules.check,asTyped:false){choice in attempt.play(from:choice.from,to:choice.to,promotion:choice.promotion);return nil})
        }
        if l.mini,let game=l.miniGame {
            if game.isFinished{return .waiting(String(localized:"The game is over.",bundle:.checkmate))}
            if l.miniThinking || game.computer && game.turn=="b"{return .waiting(Self.notYourMove)}
            let moves=MiniGameRules.moves(board:game.board,kind:game.kind,side:game.turn).map{MoveRecord(color:game.turn,from:$0.from,to:$0.to,piece:String(game.board[$0.from]?.suffix(1) ?? ""),flags:"n",san:"",before:"",after:"",captured:game.board[$0.to].map{String($0.suffix(1))},promotion:nil)}
            return .ready(TypedMoveTarget(moves:moves,board:game.board,turn:game.turn,enPassant:nil,inCheck:false,asTyped:false){choice in l.clearSelection();l.click(choice.from);l.click(choice.to);return nil})
        }
        if l.activePuzzle != nil,let exercise=l.exercise,exercise.kind=="move" {
            if l.passed{return .waiting(String(localized:"This exercise is finished.",bundle:.checkmate))}
            let board=l.frame.board ?? [:],mover=exercise.from.flatMap{board[$0].map{String($0.prefix(1))}} ?? "w"
            // The puzzle grades the pair of squares as clicks would: any move of one of the learner's pieces is an answer.
            return .ready(TypedMoveTarget(moves:Self.puzzleMoves(board:board,mover:mover),board:board,turn:mover,enPassant:nil,inCheck:false,asTyped:true){[weak self] choice in
                guard board[choice.from]?.hasPrefix(mover)==true else{return String(localized:"There's no piece of yours on \(choice.from).",bundle:.checkmate)}
                l.clearSelection();l.click(choice.from);l.click(choice.to);if !l.feedback.isEmpty{self?.announceTypedMove(l.feedback)};return nil})
        }
        return .none
    }
    /// The moves SAN is read against in a lesson puzzle: where the mover's pieces can reach, plus each en passant
    /// capture the board allows. A puzzle holds no move history, so its board is the only source of that square, and
    /// a typed capture is graded like a clicked one whether or not it is the answer.
    static func puzzleMoves(board:Position,mover:String)->[MoveRecord] {
        TypedMove.reachable(board:board,turn:mover,enPassant:nil)+TypedMove.possibleEnPassant(board:board,turn:mover).flatMap{square in TypedMove.reachable(board:board,turn:mover,enPassant:square).filter{$0.piece=="p" && $0.to==square}}
    }
    /// Plays `text` on the board that takes moves; nil when it was played, otherwise why not. Nothing changes on a refusal.
    func submitTypedMove(_ text:String)->String? {
        switch typedMovePlace() {
        case .none:return Self.typedMoveUnavailable
        case .waiting(let reason):return reason
        case .ready(let target):
            switch TypedMove.resolve(text,moves:target.moves,board:target.board,turn:target.turn,enPassant:target.enPassant,inCheck:target.inCheck,squaresAsTyped:target.asTyped) {
            case .refused(let reason):return reason
            case .move(let choice):let refusal=target.play(choice);refresh();return refusal
            }
        }
    }
    func announceTypedMove(_ text:String){NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    @objc func typeMove(){
        guard typedMoveAvailable else{return}
        let entry=TypedMoveController(),popover=NSPopover()
        entry.submit={[weak self,weak popover] text in guard let self else{return nil};let refusal=self.submitTypedMove(text);if refusal==nil{popover?.performClose(nil)}else{self.announceTypedMove(refusal!)};return refusal}
        popover.behavior = .transient;popover.contentViewController=entry
        popover.show(relativeTo:board.squareRect(board.focus),of:board,preferredEdge:.maxY)
        entry.view.window?.makeFirstResponder(entry.field)
    }
}
/// The field ⌘L opens beside the board: Return plays the move, a refusal stays under the field, Escape closes it.
final class TypedMoveController:NSViewController {
    let field=NSTextField(),message=textLabel("",.callout)
    var submit:(String)->String?={_ in nil}
    override func loadView(){
        let title=textLabel(String(localized:"Type a Move",bundle:.checkmate),.headline,.semibold);title.setAccessibilityRole(.staticText)
        field.placeholderString="e4, Nf3, O-O or e2e4";field.setAccessibilityLabel(String(localized:"Move",bundle:.checkmate,comment:"Noun: one move in a chess game"));field.identifier=NSUserInterfaceItemIdentifier("typed-move-field");field.target=self;field.action=#selector(enter)
        message.identifier=NSUserInterfaceItemIdentifier("typed-move-message");message.textColor = .secondaryLabelColor;message.maximumNumberOfLines=0;message.preferredMaxLayoutWidth=260;message.isHidden=true
        let stack=NSStackView(views:[title,field,message]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=Metrics.smallGap;stack.edgeInsets=NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        field.widthAnchor.constraint(equalToConstant:260).isActive=true
        view=stack
    }
    @objc func enter(){guard let refusal=submit(field.stringValue) else{return};message.stringValue=refusal;message.isHidden=false;field.selectText(nil)}
}
