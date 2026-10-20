import XCTest
@testable import CheckmateDomain

/// Mini-games plan WI-024 (D7, L2, `docs/network-protocol-1.3.md`): the ruleset descriptor and its capability, the
/// bounded record, replay through the referee, the canonical state the hash covers, the added endings and who may
/// receive them, assistance off, solo kinds refused, and protocol 1.3 against the frozen 1.2 bytes.
final class NetworkRulesetTests:XCTestCase {
    let pawnDuel=NetworkRuleset(.pawnDuel)!,rookSweep=NetworkRuleset(.rookSweep)!
    /// Pawn Duel to a far-rank win by White at ply 9: each side breaks through on its wing, and White promotes first.
    static let farRankWin=["b2b4","g7g5","b4b5","g5g4","b5b6","g4g3","b6c7","g3f2","c7c8"]
    private func moves(_ list:[String])->[MiniGameMove] {list.map{MiniGameMove(from:String($0.prefix(2)),to:String($0.suffix(2)))}}
    private func played(_ ruleset:NetworkRuleset,_ list:[String])throws -> NetworkMiniGame {let game=NetworkMiniGame(ruleset);for uci in list {_ = try game.networkPlay(uci:uci)};return game}

    // MARK: The descriptor and the capability budget
    func testEveryCompetitiveKindIsARulesetAndItsTokensFit12sBounds()throws {
        XCTAssertEqual(NetworkRuleset.supported.map(\.kind),MiniGameKind.allCases.filter{!$0.solo})
        for ruleset in NetworkRuleset.supported {
            XCTAssertEqual(ruleset.descriptor,"mini:\(ruleset.kind.rawValue)@\(MiniGameRules.version)")
            XCTAssertEqual(NetworkRuleset(descriptor:ruleset.descriptor),ruleset)
            XCTAssertLessThanOrEqual(ruleset.descriptor.utf8.count,NetworkRuleset.maximumDescriptorBytes)
            XCTAssertNotNil(NetworkCapabilities([ruleset.capability]),"\(ruleset.capability) is a token 1.2 accepts")
        }
        // The budget is full: eight tokens, the longest exactly 32 bytes. One more must fail here, not be dropped.
        XCTAssertEqual(NetworkCapabilities.supported.tokens.count,NetworkCapabilities.maximumTokens)
        XCTAssertEqual(NetworkCapabilities.supported.tokens.map(\.utf8.count).max(),NetworkCapabilities.maximumTokenBytes)
        XCTAssertNil(NetworkCapabilities(NetworkCapabilities.supported.tokens+["one-more"]),"a ninth token is malformed to a 1.2 host")
        XCTAssertNil(NetworkCapabilities(["ruleset:mini:bishops-and-pawns@10"]),"a two-digit rules version does not fit")
        for text in ["mini:pawn-duel@\(MiniGameRules.version+1)","mini:pawn-duel@0\(MiniGameRules.version)","mini:pawn-duel","pawn-duel@1","mini:pawn-duel@2 ","mini:Pawn-Duel@1","mini:chess@1","mini:knight-corners@\(MiniGameRules.version)",""] {
            XCTAssertNil(NetworkRuleset(descriptor:text),text)
        }
    }
    /// Knight Corners has no opponent: no ruleset, no token, no label, and a record naming it is refused.
    func testSoloKindsAreRefusedEverywhere()throws {
        XCTAssertNil(NetworkRuleset(.knightCorners))
        XCTAssertFalse(NetworkCapabilities.supported.tokens.contains{$0.contains("knight-corners")})
        XCTAssertNil(NetworkRuleset.displayKind("mini:knight-corners@1"))
        let game=NetworkPublicGame(gameID:.random(using:TestRandom(seed:3).source),revision:0,hostSide:.white,whiteName:"Ana",blackName:nil,timeControl:.untimed,pgn:"mini:knight-corners@1",clocks:nil,openOffer:nil,outcome:nil,ruleset:"mini:knight-corners@1")
        XCTAssertThrowsError(try install(game,hash:"x")){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("ruleset"))}
    }
    /// The descriptor names the referee and the start: freeze each kind's start and one finished trace, so a change
    /// to either without bumping `MiniGameRules.version` fails (Codex objection 6).
    func testTheRulesVersionPinsEveryStartAndAFinishedTrace()throws {
        XCTAssertEqual(MiniGameRules.version,2)
        let starts=Dictionary(uniqueKeysWithValues:NetworkRuleset.supported.map{($0.kind,NetworkMiniGame.placement($0.kind.initialBoard))})
        XCTAssertEqual(starts,[.pawnDuel:"8/1pppppp1/8/8/8/8/1PPPPPP1/8",.rookSweep:"6r1/3p4/1p1P1p1P/5P1p/P1p5/p1P1p1P1/4P3/1R6",
                               .rooksAndPawns:"3rr3/ppp2ppp/8/8/8/8/PPP2PPP/3RR3",.bishopSweep:"8/3b2b1/2p4p/p1P1p1P1/1p1P1p1P/P4P2/1B2B3/8",
                               .bishopsAndPawns:"3bb3/ppp2ppp/8/8/8/8/PPP2PPP/3BB3",.queenVsPawns:"4q3/8/8/8/8/8/PPPPPPPP/8",.knightCapture:"2r3n1/1p2b3/3p3p/p4p2/2P4P/P3P3/3B2P1/1N3R2"],
                       "the starts each descriptor names")
        // The record limit's inputs (`NetworkRuleset.maximumPlies`): at most 16 pieces and 16 pawns in any start, and
        // the 80-ply rule; then 111 irreversible plies and 112 stretches of at most 80 stay under the limit.
        XCTAssertLessThanOrEqual(NetworkRuleset.supported.map{$0.kind.initialBoard.count}.max()!,16)
        XCTAssertLessThanOrEqual(NetworkRuleset.supported.map{$0.kind.initialBoard.values.filter{$0.hasSuffix("p")}.count}.max()!,16)
        XCTAssertEqual(MiniGameState.noProgressPlies,80);XCTAssertLessThan(111+112*80,NetworkRuleset.maximumPlies)
        let game=try played(pawnDuel,Self.farRankWin)
        XCTAssertEqual(try game.networkAutomaticEnding(),.mini(winner:.white,.farRank))
        XCTAssertEqual(game.history,["b2-b4","g7-g5","b4-b5","g5-g4","b5-b6","g4-g3","b6xc7","g3xf2","c7-c8"])
    }

    // MARK: The record
    func testTheRecordIsTheMoveListAndAnythingElseIsRefused()throws {
        let game=try played(pawnDuel,Array(Self.farRankWin.prefix(3)))
        XCTAssertEqual(try game.networkPGN(),"mini:pawn-duel@2 b2b4 g7g5 b4b5")
        XCTAssertEqual(try pawnDuel.moves(of:"mini:pawn-duel@2"),[])
        for bad in ["","mini:pawn-duel@2 ","mini:pawn-duel@2  b2b4","mini:pawn-duel@2 b2b4 ","mini:pawn-duel@2\nb2b4","mini:pawn-duel@2 B2B4","mini:pawn-duel@2 b2b4q","mini:pawn-duel@2 b2b9",
                    "mini:rook-sweep@2 b1b2","1. b4 g5","[Event \"?\"]\n\n1. b4 *","mini:pawn-duel@2 b2-b4"," mini:pawn-duel@2"] {
            XCTAssertThrowsError(try pawnDuel.moves(of:bad),bad){XCTAssertEqual($0 as? NetworkRulesError,.badRecord,bad)}
            XCTAssertThrowsError(try NetworkMiniGame(pawnDuel).networkLoad(pgn:bad),bad)
        }
        // Over the limit, refused unread: one move too many.
        let long="mini:pawn-duel@2"+String(repeating:" b2b3",count:NetworkRuleset.maximumPlies+1)
        XCTAssertThrowsError(try pawnDuel.moves(of:long)){XCTAssertEqual($0 as? NetworkRulesError,.badRecord)}
        // Well formed but not legal under the referee: an illegal move, a move after the game ended, and a load that
        // fails leaves the game as it was.
        let kept=try played(pawnDuel,["b2b4"])
        for bad in ["mini:pawn-duel@2 b2b5","mini:pawn-duel@2 g7g5","mini:pawn-duel@2 "+Self.farRankWin.joined(separator:" ")+" g2g3"] {
            XCTAssertThrowsError(try kept.networkLoad(pgn:bad),bad);XCTAssertEqual(try kept.networkMoves(),["b2b4"],bad)
        }
        XCTAssertThrowsError(try kept.networkPlay(uci:"g2g4q")){XCTAssertEqual($0 as? NetworkRulesError,.illegalMove)}
        XCTAssertThrowsError(try kept.networkLoad(start:NetworkStart.standard)){XCTAssertEqual($0 as? NetworkRulesError,.illegalStart)}
        // And a record loads to the same game as playing it.
        let loaded=NetworkMiniGame(pawnDuel);try loaded.networkLoad(pgn:try game.networkPGN())
        XCTAssertEqual(try loaded.networkFEN(),try game.networkFEN());XCTAssertEqual(loaded.state,game.state)
    }

    // MARK: The canonical state (the hash)
    /// Rook Sweep, where only the rooks move: X is White's rook on b2 and Black's on g7, White to move. One game
    /// reaches X once, the other twice; the boards are equal and the hashes are not. Played on, the second ends by
    /// repetition and the first goes on, on the host and on a receiver that replayed each record.
    func testEqualBoardsWithDifferentHistoriesHashDifferentlyAndEndIdenticallyAfterReplay()throws {
        let once=try played(rookSweep,["b1b2","g8g7"]),twice=try played(rookSweep,["b1b2","g8g7","b2b1","g7g8","b1b2","g8g7"])
        XCTAssertEqual(once.board,twice.board);XCTAssertEqual(once.turn,twice.turn)
        XCTAssertNotEqual(try once.networkFEN(),try twice.networkFEN())
        XCTAssertNotEqual(testHashing.positionHash(fen:try once.networkFEN(),revision:6),testHashing.positionHash(fen:try twice.networkFEN(),revision:6))
        for game in [once,twice] {
            let receiver=NetworkMiniGame(rookSweep);try receiver.networkLoad(pgn:try game.networkPGN())
            XCTAssertEqual(try receiver.networkFEN(),try game.networkFEN(),"the receiver recomputed the history from the moves")
            for uci in ["b2b1","g7g8"] {_ = try game.networkPlay(uci:uci);_ = try receiver.networkPlay(uci:uci)}
            XCTAssertEqual(try receiver.networkAutomaticEnding(),try game.networkAutomaticEnding())
        }
        XCTAssertNil(try once.networkAutomaticEnding(),"the start twice: play goes on")
        XCTAssertEqual(try twice.networkAutomaticEnding(),.mini(winner:nil,.miniRepetition),"the start a third time")
        // The no-progress count is part of the state too: the same board after one stretch of rook moves or another.
        let short=try played(rookSweep,["b1c1","g8f8","c1b1","f8g8"]),start=NetworkMiniGame(rookSweep)
        XCTAssertEqual(short.board,start.board);XCTAssertNotEqual(try short.networkFEN(),try start.networkFEN())
        XCTAssertTrue(try start.networkFEN().hasSuffix("||0"));XCTAssertTrue(try short.networkFEN().hasSuffix("|4"))
    }
    /// A game far past the referee's 256-position memory: the state the hash covers is still exactly the positions
    /// since the last capture or pawn move, and the review sees every position at its own ply (Codex objection 4).
    func testALongGameKeepsItsWholeStateAndIsReviewedFromItsStart()throws {
        let ruleset=NetworkRuleset(.rooksAndPawns)!,list=Self.longGame(ruleset.kind,plies:300)
        XCTAssertEqual(list.count,300,"the generator found a 300-ply game")
        let game=NetworkMiniGame(ruleset);for move in list {_ = try game.networkPlay(uci:move.from+move.to)}
        XCTAssertEqual(game.state.history.count,MiniGameState.maximumHistory,"the referee forgot the oldest positions")
        // The reference: every snapshot kept.
        var full=MiniGameState(kind:ruleset.kind,computer:false),all=[full.snapshot]
        for move in list {XCTAssertTrue(full.play(move));all.append(full.snapshot)}
        let current=all.last!,pawns=current.board.filter{$0.value.hasSuffix("p")}
        let since=all.dropLast().reversed().prefix{$0.board.count==current.board.count && $0.board.filter{$0.value.hasSuffix("p")}==pawns}.count
        XCTAssertTrue(try game.networkFEN().hasSuffix("|\(since)"));XCTAssertEqual(try game.networkFEN().split(separator:"|",omittingEmptySubsequences:false).dropFirst(5).first?.split(separator:"/").count,since)
        // The review's positions: every ply from the start, each with exactly the draw context its complete history
        // gives, so each is judged as in the game, however far past 256 plies.
        let replay=try XCTUnwrap(MiniGameReview.Replay(kind:ruleset.kind,moves:list))
        XCTAssertEqual(replay.snapshots,all)
        for ply in all.indices {
            var reference=MiniGameState(kind:ruleset.kind,computer:false);reference.snapshot=all[ply];reference.history=Array(all[..<ply])
            let position=replay.position(ply)
            XCTAssertEqual(MiniGameProof.drawContext(position,historyComplete:true),MiniGameProof.drawContext(reference,historyComplete:true),"ply \(ply)")
            XCTAssertEqual(position.winner,reference.winner);XCTAssertEqual(position.draw,reference.draw)
        }
        // A review of it is consistent and counts plies from the start; facts are numbered from the start.
        let review=MiniGameReview.run(kind:ruleset.kind,moves:list,budget:0.3,cpuSeconds:{Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))/1e9},stop:{false})
        XCTAssertTrue(review.consistent);XCTAssertEqual(review.plies,300)
        let reached=review.answers.keys.sorted();if let first=reached.first {XCTAssertEqual(reached,Array(first...300),"worked back from the last position")}
        XCTAssertTrue(review.facts.allSatisfy{$0.ply<300 && $0.text.hasPrefix("Move \($0.ply/2+1)")},"numbered from the start")
        XCTAssertFalse(MiniGameReview.run(kind:ruleset.kind,moves:list+[MiniGameMove(from:"a1",to:"a1")],budget:1,cpuSeconds:{0},stop:{false}).consistent,"a move the referee refuses")
    }
    /// A long game by the referee's rules: quiet rook moves to positions not seen before, a pawn move when the
    /// no-progress count nears 80, never a move that ends the game. Deterministic.
    static func longGame(_ kind:MiniGameKind,plies:Int)->[MiniGameMove] {
        var state=MiniGameState(kind:kind,computer:false),list:[MiniGameMove]=[],seen:Set<String>=[],quiet=0,seed:UInt64=7
        func key(_ s:MiniGameSnapshot)->String {s.board.keys.sorted().map{$0+s.board[$0]!}.joined()+s.turn}
        while list.count<plies {
            let legal=MiniGameRules.moves(board:state.board,kind:kind,side:state.turn)
            let candidates=legal.filter{move in var next=state;guard next.play(move),!next.isFinished else{return false};return true}
            let pawnMoves=candidates.filter{state.board[$0.from]!.hasSuffix("p") && state.board[$0.to]==nil}
            let fresh=candidates.filter{move in var next=state;_ = next.play(move);return !state.board[move.from]!.hasSuffix("p") && state.board[move.to]==nil && !seen.contains(key(next.snapshot))}
            let pool=quiet>=70 && !pawnMoves.isEmpty ? pawnMoves:(fresh.isEmpty ? (pawnMoves.isEmpty ? candidates:pawnMoves):fresh)
            guard !pool.isEmpty else{break}
            seed=seed &* 6364136223846793005 &+ 1442695040888963407
            let move=pool[Int((seed>>33) % UInt64(pool.count))]
            let irreversible=state.board[move.from]!.hasSuffix("p") || state.board[move.to] != nil
            _ = state.play(move);list.append(move);seen.insert(key(state.snapshot));quiet=irreversible ? 0:quiet+1
        }
        return list
    }

    // MARK: Endings and who receives them
    private func ruleset(_ net:TestNetwork)->NetworkRuleset? {net.host.settings.ruleset}
    /// A 1.1 Mac, a 1.2 Mac, a 1.3 Mac without Pawn Duel and one with another rules version are each refused before
    /// anything is sent, guests and spectators alike; a capable guest and spectator play to a far-rank win, and the
    /// new ending reaches only them (the test plan D7 keeps).
    func testPeersWithoutTheRulesetSeeNothingButTheRefusalAndTheEndingReachesOnlyCapablePeers()throws {
        let net=try TestNetwork(ruleset:pawnDuel)
        XCTAssertEqual(net.host.requiredCapabilities.tokens,[pawnDuel.capability])
        let otherKinds=NetworkCapabilities([NetworkStart.capability]+NetworkRuleset.supported.filter{$0 != pawnDuel}.map(\.capability))!
        let otherVersion=NetworkCapabilities([NetworkStart.capability,"ruleset:mini:pawn-duel@\(MiniGameRules.version+1)"])!
        var refused:[TestClient]=[]
        for (index,capabilities) in [NetworkCapabilities.none,NetworkCapabilities([NetworkStart.capability])!,otherKinds,otherVersion].enumerated() {
            for listener in [NetworkListenerRole.watch,.seat] {
                let client=net.client(listener,name:"Old \(index)",capabilities:capabilities);try net.connect(client)
                XCTAssertEqual(client.closedWith,.protocolVersion);XCTAssertNil(client.receiver.installed);XCTAssertEqual(client.received,[],"nothing but the refusal (the transport's bye)")
                refused.append(client)
            }
        }
        XCTAssertEqual(net.host.phase,.waiting);XCTAssertEqual(net.host.spectators,[])
        let (guest,watchers)=try net.startGame(spectators:1)
        XCTAssertEqual(guest.receiver.installed?.ruleset,pawnDuel.descriptor);XCTAssertEqual(guest.receiver.pinnedStart,pawnDuel.descriptor)
        for (index,uci) in Self.farRankWin.enumerated() {if index%2==0 {try net.hostPlays(uci)}else{try net.play(guest,uci)}}
        let ended=NetworkOutcome(result:.whiteWins,termination:.farRank)
        XCTAssertEqual(net.host.outcome,ended)
        for client in [guest]+watchers {XCTAssertEqual(client.receiver.outcome,ended);XCTAssertNil(client.closedWith)}
        // Every frame any refused connection was ever sent, and every client's: no new value but on capable ones.
        for client in refused {XCTAssertFalse(client.received.contains{if case .ended=$0 {return true};if case .snapshotBegin=$0 {return true};return false})}
        for (id,frames) in net.sent where !([guest.connection,watchers[0].connection].contains(id)) {
            for frame in frames {let text=String(decoding:frame,as:UTF8.self);XCTAssertFalse(text.contains("farRank") || text.contains("mini:"),text)}
        }
        // A chess game cannot produce one.
        XCTAssertTrue(NetworkTermination.allCases.filter{!$0.inProtocol12}.allSatisfy{!Legacy12Fixtures.terminations.contains($0.rawValue)})
        XCTAssertEqual(Set(NetworkTermination.allCases.filter(\.inProtocol12).map(\.rawValue)),Legacy12Fixtures.terminations)
    }
    /// A guest that stated the ruleset and then withdraws it on its next `resume` is refused, and the hold begins.
    func testAResumeWithdrawingTheRulesetIsRefused()throws {
        let net=try TestNetwork(ruleset:pawnDuel)
        let (guest,_)=try net.startGame()
        try net.hostPlays("b2b4")
        let credential=try XCTUnwrap(guest.receiver.credential);try net.cut(guest)
        let id=try net.open(.seat);try net.send(.resume(gameID:net.gameID,credential:credential,capabilities:NetworkCapabilities([NetworkStart.capability])!),on:id)
        XCTAssertEqual(net.closes[id],.protocolVersion);XCTAssertEqual(net.messages(id),[]);XCTAssertEqual(net.host.phase,.disconnected)
        try net.connect(guest);XCTAssertEqual(net.host.phase,.running,"the same guest stating it again resumes")
    }
    /// A mini-game has no claimed draw: the host's claim and the guest's are each refused as not claimable, and the game
    /// goes on, though a chess game's scripted rules would allow one.
    func testADrawClaimInAMiniGameIsNotClaimable()throws {
        let net=try TestNetwork(ruleset:pawnDuel)
        let (guest,_)=try net.startGame()
        net.script.claimable = .repetition
        try net.perform(.claimDraw);XCTAssertEqual(net.refusals,[.notClaimable],"the host is to move, and may not claim")
        try net.hostPlays("b2b4")
        let revision=net.host.revision
        try net.command(guest,guest.receiver.claimDraw())
        guard case .rejected(_,.notClaimable)?=guest.received.last else{return XCTFail("\(String(describing:guest.received.last))")}
        XCTAssertNil(net.host.outcome);XCTAssertEqual(net.host.revision,revision);XCTAssertEqual(net.host.phase,.running)
    }
    /// Codex objection 2: a receiver checks every ending the rules decide against its own replay, live and in a snapshot.
    func testAnEndingTheBoardDoesNotShowIsRefused()throws {
        // A chess game told it ended at the far rank, a mini-game told it ended by repetition at the start, or won by
        // the wrong side, closes; the true ending is accepted.
        let chess=try TestNetwork();let (chessGuest,_)=try chess.startGame()
        let farRank=try chessGuest.receiver.receive(message:.ended(NetworkEnded(outcome:NetworkOutcome(result:.whiteWins,termination:.farRank),revision:1,clocks:nil)),at:chess.now)
        XCTAssertEqual(farRank.close,.malformed);XCTAssertNil(chessGuest.receiver.outcome)
        let mini=try TestNetwork(ruleset:pawnDuel);let (guest,_)=try mini.startGame()
        for wrong in [NetworkOutcome(result:.draw,termination:.miniRepetition),NetworkOutcome(result:.draw,termination:.checkmate),NetworkOutcome(result:.draw,termination:.repetition)] {
            XCTAssertEqual(try guest.receiver.receive(message:.ended(NetworkEnded(outcome:wrong,revision:1,clocks:nil)),at:mini.now).close,.malformed,"\(wrong)")
        }
        XCTAssertEqual(try guest.receiver.receive(message:.ended(NetworkEnded(outcome:NetworkOutcome(result:.whiteWins,termination:.resignation),revision:1,clocks:nil)),at:mini.now).close,nil,"a resignation is the host's word")
        let played=try played(pawnDuel,Self.farRankWin)
        let real=try XCTUnwrap(try played.networkAutomaticEnding()).outcome,wrongWinner=NetworkOutcome(result:.blackWins,termination:.farRank)
        XCTAssertTrue(try NetworkSnapshotInstaller.verified(real,on:played,ruleset:true))
        XCTAssertFalse(try NetworkSnapshotInstaller.verified(wrongWinner,on:played,ruleset:true))
        // In a snapshot: the finished game with the wrong winner is refused; with the right one it installs.
        let base=NetworkPublicGame(gameID:.random(using:TestRandom(seed:9).source),revision:10,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:try played.networkPGN(),clocks:nil,openOffer:nil,outcome:real,ruleset:pawnDuel.descriptor)
        let hash=testHashing.positionHash(fen:try played.networkFEN(),revision:10)
        XCTAssertNoThrow(try install(base,hash:hash))
        var lying=base;lying.outcome=wrongWinner
        XCTAssertThrowsError(try install(lying,hash:hash)){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("outcome"))}
        // A chess snapshot cannot carry a mini-game's ending: with no ruleset, one is refused, and a resignation installs.
        let chessGame=NetworkPublicGame(gameID:.random(using:TestRandom(seed:10).source),revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"[Fake]\nb2b4",clocks:nil,openOffer:nil,outcome:NetworkOutcome(result:.whiteWins,termination:.resignation))
        let chessHash=testHashing.positionHash(fen:"b2b4 b - - 0 1",revision:2)
        XCTAssertNoThrow(try install(chessGame,hash:chessHash))
        for termination in NetworkTermination.allCases where !termination.inProtocol12 {
            var mini=chessGame;mini.outcome=NetworkOutcome(result:termination == .farRank || termination == .allCaptured ? .whiteWins:.draw,termination:termination)
            XCTAssertThrowsError(try install(mini,hash:chessHash),"\(termination)"){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("outcome"))}
        }
    }

    // MARK: Receivers: before any replay (Codex objection 8)
    /// Makes the games a receiver would replay into, counting them.
    final class Counter {var games=0}
    private func install(_ game:NetworkPublicGame,hash:String,pinned:String?=nil,stated:NetworkCapabilities = .supported,counter:Counter=Counter())throws -> NetworkSnapshotInstaller.Installed {
        let factory=NetworkRulesFactory({counter.games+=1;return FakeRules(script:FakeScript())},ruleset:{counter.games+=1;return NetworkMiniGame($0)})
        return try NetworkSnapshotInstaller.install(try JSONEncoder().encode(game),revision:game.revision,hash:hash,gameID:game.gameID,rules:factory,hashing:testHashing,pinned:pinned,stated:stated)
    }
    func testAnUnsupportedUnstatedOrUnpinnedRulesetIsRefusedBeforeAnyReplay()throws {
        let gameID=NetworkGameID.random(using:TestRandom(seed:11).source)
        func record(_ ruleset:String?,_ pgn:String,revision:Int=0)->NetworkPublicGame {NetworkPublicGame(gameID:gameID,revision:revision,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:nil,ruleset:ruleset)}
        let start=NetworkMiniGame(pawnDuel),hash=testHashing.positionHash(fen:try start.networkFEN(),revision:0)
        let cases:[(NetworkPublicGame,String?,NetworkCapabilities,NetworkSnapshotError)]=[
            (record("mini:pawn-duel@\(MiniGameRules.version+1)","mini:pawn-duel@\(MiniGameRules.version+1)"),nil,.supported,.badSnapshot("ruleset")),
            (record("mini:pawn-duel@2","mini:pawn-duel@2"),nil,NetworkCapabilities([NetworkStart.capability])!,.badSnapshot("ruleset")),
            (record("mini:pawn-duel@2","mini:pawn-duel@2"),NetworkStart.standard,.supported,.pinMismatch),
            (record("mini:pawn-duel@2","mini:pawn-duel@2"),rookSweep.descriptor,.supported,.pinMismatch),
            (record(nil,"[Fake]\n"),pawnDuel.descriptor,.supported,.pinMismatch),
        ]
        for (game,pinned,stated,expected) in cases {
            let counter=Counter()
            XCTAssertThrowsError(try install(game,hash:hash,pinned:pinned,stated:stated,counter:counter)){XCTAssertEqual($0 as? NetworkSnapshotError,expected,"\(game.ruleset ?? "chess") pinned \(pinned ?? "-")")}
            XCTAssertEqual(counter.games,0,"refused before any game was made to replay into")
        }
        // Oversized and malformed records: refused unread, before any game is made.
        for (pgn,revision) in [("mini:pawn-duel@2"+String(repeating:" b2b3",count:5),2),("mini:pawn-duel@2 b2b4",NetworkRuleset.maximumPlies+2),("mini:pawn-duel@2  b2b4",1),("1. b4 *",1),("mini:pawn-duel@2 b2b4 g7g5",1)] {
            let counter=Counter()
            XCTAssertThrowsError(try install(record(pawnDuel.descriptor,pgn,revision:revision),hash:hash,counter:counter),pgn)
            XCTAssertEqual(counter.games,0,pgn)
        }
        // A ruleset record may not declare a start too.
        XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try JSONEncoder().encode(NetworkPublicGame(gameID:gameID,revision:0,hostSide:.white,whiteName:nil,blackName:nil,timeControl:.untimed,pgn:"",clocks:nil,openOffer:nil,outcome:nil,startFEN:"8/8/4k3/8/8/4K3/4P3/8 b - - 0 37",ruleset:pawnDuel.descriptor))))
        // The true record installs, and its board is the referee's own replay.
        let installed=try install(record(pawnDuel.descriptor,pawnDuel.descriptor),hash:hash)
        XCTAssertEqual(installed.ruleset,pawnDuel);XCTAssertEqual(installed.start,pawnDuel.descriptor);XCTAssertTrue(installed.rules is NetworkMiniGame)
    }
    /// A receiver that pinned chess refuses a later snapshot naming a mini-game, and the reverse, at the same
    /// revision, without replaying it.
    func testTheRulesetIsPinnedAcrossSnapshots()throws {
        let mini=try TestNetwork(ruleset:pawnDuel);let (guest,_)=try mini.startGame()
        XCTAssertEqual(guest.receiver.pinnedStart,pawnDuel.descriptor)
        let chess=try TestNetwork();let (chessGuest,_)=try chess.startGame()
        XCTAssertEqual(chessGuest.receiver.pinnedStart,NetworkStart.standard)
        // The mini-game's snapshot, handed to the chess receiver as if its host sent it, with the chess game's ID.
        var game=try mini.host.publicGame(at:mini.now);game.gameID=chess.gameID
        let payload=try JSONEncoder().encode(game),snapshot=NetworkSnapshot(snapshotID:.random(using:TestRandom(seed:5).source),revision:0,hash:mini.host.positionHash,payload:payload)
        var output=NetworkReceiverOutput()
        for message in snapshot.messages {output=try chessGuest.receiver.receive(message:message,at:chess.now);if output.close != nil {break}}
        XCTAssertEqual(output.close,.malformed);XCTAssertEqual(chessGuest.receiver.pinnedStart,NetworkStart.standard);XCTAssertNil(chessGuest.receiver.installed?.ruleset)
    }

    // MARK: Assistance off
    func testAMiniGameHasNoAssistance()throws {
        XCTAssertThrowsError(try TestNetwork(assistance:NetworkAssistance(both:.hints),ruleset:pawnDuel)){XCTAssertEqual($0 as? NetworkHostError,.assistanceNotAllowed)}
        XCTAssertThrowsError(try TestNetwork(start:"8/8/4k3/8/8/4K3/4P3/8 b - - 0 37",ruleset:pawnDuel)){XCTAssertEqual($0 as? NetworkHostError,.illegalStart)}
        let net=try TestNetwork(ruleset:pawnDuel);let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("b2b4",assisted:true);try net.play(guest,"g7g5",assisted:true)
        XCTAssertEqual(net.host.assistedPlies,[],"an assisted flag is dropped");XCTAssertEqual(guest.receiver.assistedPlies,[]);XCTAssertEqual(watchers[0].receiver.assistedPlies,[])
        XCTAssertFalse(net.sent.values.joined().contains{String(decoding:$0,as:UTF8.self).contains(#""assisted""#) && String(decoding:$0,as:UTF8.self).contains("moved")})
        // A host that says otherwise is not this game.
        let fake=NetworkMoved(revision:3,uci:"b4b5",san:"b4-b5",hash:"x",clocks:nil,receiptFor:nil,assisted:true)
        XCTAssertEqual(try watchers[0].receiver.receive(message:.moved(fake),at:net.now).close,.malformed)
        var game=try net.host.publicGame(at:net.now);game.assistance=NetworkAssistance(both:.hints)
        XCTAssertThrowsError(try install(game,hash:net.host.positionHash)){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("assistance"))}
    }

    // MARK: Protocol 1.3 against the frozen 1.2 bytes
    func testEveryFrozen12MessageDecodesAndKeepsItsBytes()throws {
        for text in Legacy12Fixtures.messages {
            let message=try NetworkCodec.decode(Data(text.utf8))
            XCTAssertEqual(String(decoding:try NetworkCodec.encode(message),as:UTF8.self),text.replacingOccurrences(of:#""minor":2"#,with:#""minor":3"#))
        }
        let record=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(Legacy12Fixtures.record.utf8))
        XCTAssertNil(record.ruleset);XCTAssertEqual(record.start,record.startFEN)
        XCTAssertEqual(String(decoding:try record.encoded(),as:UTF8.self),Legacy12Fixtures.record,"a chess record from a declared start is 1.2's, byte for byte")
        XCTAssertEqual(Set(Legacy12Fixtures.messages.map{try! NetworkCodec.decode(Data($0.utf8)).type}),["hello","resume","move","moved","ended","bye"])
    }
}
