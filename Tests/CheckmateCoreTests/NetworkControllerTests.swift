import XCTest
@testable import CheckmateApplication
@testable import CheckmateDomain
import CheckmateRules
import CheckmateSupport

/// What one Mac's VoiceOver was asked to say, in order. Shared with the network assistant's tests.
final class Heard {var lines:[String]=[];func count(_ line:String)->Int {lines.filter{$0==line}.count}}
/// Several Macs on one local network, in memory: one manual scheduler and transport, and each Mac's own discovery fed
/// with the records a host publishes when its listeners are ready, as the loopback gate does (D12).
final class MemoryLAN {
    let scheduler=NetworkManualScheduler()
    let transport:NetworkMemoryTransport
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-lan-\(UUID().uuidString)",isDirectory:true)
    private var discoveries:[NetworkFixedDiscovery]=[]
    private var published:[String:[NetworkServiceRecord]]=[:]
    /// The day review records are dated: 16 October 2026, at noon UTC.
    static let day:Date={var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"UTC")!;return calendar.date(from:DateComponents(year:2026,month:10,day:16,hour:12))!}()
    init(){transport=NetworkMemoryTransport(scheduler:scheduler)}
    deinit{try? FileManager.default.removeItem(at:root)}
    var records:[NetworkServiceRecord] {published.keys.sorted().flatMap{published[$0] ?? []}}
    func services(for name:String,discovery custom:(any NetworkDiscovery)?=nil)->NetworkServices {
        let discovery:any NetworkDiscovery
        if let custom{discovery=custom}else{let fixed=NetworkFixedDiscovery(records:records,scheduler:scheduler);discoveries.append(fixed);discovery=fixed}
        return NetworkServices(transport:transport,discovery:discovery,scheduler:scheduler,delivery:.immediate,rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash),appVersion:"0.8.0",crashFile:NetworkCrashFile(dataDirectory:root.appendingPathComponent(name+"-\(UUID().uuidString)")),today:{Self.day},
            listenersReady:{[weak self] configuration,endpoints in self?.publish(configuration,endpoints)},listenersClosed:{[weak self] gameID in self?.withdraw(gameID)})
    }
    private func publish(_ configuration:NetworkHostingConfiguration,_ endpoints:[NetworkListenerRole:NetworkEndpoint]){
        published[configuration.gameID.text]=configuration.roles.compactMap{role in endpoints[role].map{NetworkServiceRecord.published(configuration,role,at:$0)}};refresh()
    }
    private func withdraw(_ gameID:NetworkGameID){published[gameID.text]=nil;refresh()}
    private func refresh(){let records=records;for discovery in discoveries{discovery.publish(records)}}
    /// The guest's open connection.
    var guestConnection:NetworkTransportConnection? {transport.links.last{$0.key.role == .seat && $0.open && $0.connection != nil}?.connection}
}
/// One Mac's Checkmate: its network game, its participation (D8), its crash file (D9) and what VoiceOver heard.
@MainActor final class Mac {
    let game:NetworkGameController,participation=NetworkParticipation(),heard=Heard(),crashFile:NetworkCrashFile
    /// Every change of participation, in order.
    private(set) var roles:[NetworkParticipation.Role?]=[]
    init(_ lan:MemoryLAN,name:String,discovery:(any NetworkDiscovery)?=nil)throws {
        let services=lan.services(for:name,discovery:discovery);crashFile=services.crashFile!
        game=try NetworkGameController(services:services,participation:participation,playerName:name)
        let heard=heard;game.announce={heard.lines.append($0)}
        participation.observe{[weak self] role in self?.roles.append(role)}
    }
}
/// A discovery a test drives by hand: D11's denial signal, a failure, found games.
private final class ScriptedDiscovery:NetworkDiscovery {
    private let scheduler:any NetworkScheduler
    private var updates:((NetworkDiscoveryUpdate)->Void)?
    private(set) var starts=0,stops=0
    /// The callback the last `start` was given, kept after `stop`: a real browser's update can still be in flight.
    private(set) var lastUpdates:((NetworkDiscoveryUpdate)->Void)?
    init(scheduler:any NetworkScheduler){self.scheduler=scheduler}
    func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void){starts+=1;self.updates=updates;lastUpdates=updates}
    func stop(){stops+=1;updates=nil}
    func send(_ update:NetworkDiscoveryUpdate){scheduler.enqueue{[weak self] in self?.updates?(update)}}
    /// Delivers through the callback a browser had before it stopped, as an update already on its way would arrive.
    func sendLate(_ update:NetworkDiscoveryUpdate){let late=lastUpdates;scheduler.enqueue{late?(update)}}
}

/// The network game's controller (LAN-play plan D9, D10) over the in-memory transport and a manual scheduler: hosting,
/// joining and watching from the lobby, the shown game on every Mac, pending moves, participation and the crash file,
/// leaving, the hold, draws, clocks and what VoiceOver hears, and the review record.
@MainActor final class NetworkControllerTests:XCTestCase {
    func hosting(_ lan:MemoryLAN,_ name:String="Ana",file:StaticString=#filePath,line:UInt=#line,_ settings:(inout NetworkHostForm)->Void={_ in})throws -> Mac {
        let mac=try Mac(lan,name:name);settings(&mac.game.form)
        XCTAssertTrue(mac.game.host(),"the game is hosted",file:file,line:line);lan.scheduler.run()
        return mac
    }
    /// A Mac that opens the network place, picks the only game found and types the host's code.
    func joining(_ lan:MemoryLAN,_ name:String,_ host:Mac,watching:Bool=false,accepting:NetworkAssistance?=nil,file:StaticString=#filePath,line:UInt=#line)throws -> Mac {
        let mac=try Mac(lan,name:name);mac.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(mac.game.games.first,"the hosted game is found",file:file,line:line)
        let code=try XCTUnwrap(watching ? host.game.watchCode:host.game.playCode,file:file,line:line)
        XCTAssertTrue(mac.game.join(entry,code:code.grouped.lowercased(),watching:watching,accepting:accepting),file:file,line:line);lan.scheduler.run()
        XCTAssertEqual(mac.game.link,.live,"\(name) is in the game",file:file,line:line)
        return mac
    }
    /// A move made on the board with two clicks: pending until the game answers, then on every board.
    func play(_ mac:Mac,_ from:String,_ to:String,_ lan:MemoryLAN,file:StaticString=#filePath,line:UInt=#line){
        let piece=mac.game.board[from]
        mac.game.click(from);mac.game.click(to)
        XCTAssertEqual(mac.game.pending?.uci,from+to,"the move is pending",file:file,line:line);XCTAssertEqual(mac.game.notice,NetworkGameController.sendingNotice,file:file,line:line)
        XCTAssertEqual(mac.game.boardTitle,mac.game.title+" · Sending…","the board area says so too",file:file,line:line)
        XCTAssertEqual(mac.game.board[from],piece,"the board waits for the game's answer",file:file,line:line)
        lan.scheduler.run()
        XCTAssertNil(mac.game.pending,"the answer cleared the pending move",file:file,line:line);XCTAssertNil(mac.game.notice,file:file,line:line)
        XCTAssertEqual(mac.game.board[to],piece,file:file,line:line)
    }

    /// Host, guest and spectator play Fool's Mate through: the seats and names, a spectator's click, pending moves,
    /// what each Mac hears, participation and the crash file while it runs and after the result, then the review
    /// record, and back to the lobby.
    func testAShortGameReachesItsResultOnEveryMac()throws {
        let lan=MemoryLAN(),ana=try hosting(lan)
        XCTAssertEqual(ana.game.part,.host);XCTAssertEqual(ana.game.link,.waiting);XCTAssertEqual(ana.game.hostPhase,.waiting)
        XCTAssertEqual(ana.game.title,"Ana's game");XCTAssertEqual(ana.game.seat,.player(side:"w"));XCTAssertNotNil(ana.game.playCode);XCTAssertNotNil(ana.game.watchCode)
        XCTAssertEqual(ana.game.statusText,"Waiting for someone to join. Share the play code.");XCTAssertFalse(ana.game.canMove,"the game waits for the guest")
        XCTAssertTrue(ana.roles.isEmpty,"hosting alone is not participating (D8)");XCTAssertNil(ana.crashFile.pending())

        let ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        XCTAssertTrue(ben.game.browsing);let entry=try XCTUnwrap(ben.game.games.first)
        XCTAssertEqual(ben.game.games.count,1);XCTAssertTrue(entry.displayName.hasPrefix("Ana's game · "),entry.displayName)
        XCTAssertTrue(ben.game.join(entry,code:ana.game.playCode!.grouped.lowercased()))
        XCTAssertFalse(ben.game.browsing,"browsing stops once a game is chosen (D1)");XCTAssertEqual(ben.game.title,"Joining Ana's game");XCTAssertEqual(ben.game.statusText,"Joining Ana's game…")
        lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.live);XCTAssertEqual(ben.game.seat,.player(side:"b"));XCTAssertEqual(ben.game.learnerSide,.black)
        XCTAssertEqual(ana.game.hostPhase,.running);XCTAssertEqual(ana.game.link,.live)
        for mac in [ana,ben]{XCTAssertEqual(mac.game.title,"Ana vs Ben");XCTAssertEqual(mac.game.whiteName,"Ana");XCTAssertEqual(mac.game.blackName,"Ben");XCTAssertEqual(mac.roles,[.player])}
        XCTAssertTrue(ben.game.blackAtBottom);XCTAssertFalse(ana.game.blackAtBottom)
        XCTAssertEqual(ana.game.statusText,"Your move.");XCTAssertEqual(ben.game.statusText,"Ana's move.");XCTAssertEqual(ben.game.opponentName,"Ana")
        XCTAssertTrue(ana.game.canMove);XCTAssertFalse(ben.game.canMove);XCTAssertEqual(ana.game.badge,NetworkGameController.yourMoveBadge);XCTAssertNil(ben.game.badge)

        let cy=try joining(lan,"Cy",ana,watching:true)
        XCTAssertEqual(cy.game.seat,.spectator);XCTAssertNil(cy.game.learnerSide);XCTAssertEqual(cy.roles,[.spectator]);XCTAssertEqual(ana.game.spectators,["Cy"])
        XCTAssertEqual(cy.game.title,"Ana vs Ben");XCTAssertEqual(cy.game.statusText,"Ana's move.")
        // D10: a spectator's board accepts no moves; a click says so.
        cy.game.click("e2");XCTAssertEqual(cy.game.notice,NetworkGameController.watchingNotice);XCTAssertNil(cy.game.selected);XCTAssertNil(cy.game.pending)
        XCTAssertEqual(cy.game.boardTitle,"Ana vs Ben · You're watching");XCTAssertEqual(cy.heard.lines.last,"You're watching")
        cy.game.play(from:"e2",to:"e4");lan.scheduler.run();XCTAssertEqual(ana.game.board["e2"],"wp","nothing reached the game")

        play(ana,"f2","f3",lan)
        for mac in [ben,cy]{XCTAssertEqual(mac.game.board["f3"],"wp");XCTAssertNil(mac.game.board["f2"])}
        XCTAssertEqual(ana.heard.lines.last,"You played pawn to f3");XCTAssertEqual(ben.heard.lines.last,"Ana played pawn to f3");XCTAssertEqual(cy.heard.lines.last,"Ana played pawn to f3")
        XCTAssertEqual(ben.game.statusText,"Your move.");XCTAssertEqual(cy.game.statusText,"Ben's move.")
        // D9: while it runs, each Mac keeps the public record for the next launch's notice.
        let hostEntry=try XCTUnwrap(ana.crashFile.pending()),guestEntry=try XCTUnwrap(ben.crashFile.pending()),watchEntry=try XCTUnwrap(cy.crashFile.pending())
        XCTAssertEqual(hostEntry.part,.white);XCTAssertEqual(guestEntry.part,.black);XCTAssertEqual(watchEntry.part,.spectator)
        XCTAssertEqual(hostEntry.notice,"Your network game with Ben ended when Checkmate closed.");XCTAssertEqual(guestEntry.notice,"Your network game with Ana ended when Checkmate closed.")
        XCTAssertTrue(guestEntry.game.pgn.contains("f3"),guestEntry.game.pgn)

        play(ben,"e7","e5",lan);play(ana,"g2","g4",lan);play(ben,"d8","h4",lan)
        XCTAssertEqual(ben.heard.lines.suffix(2),["You played queen to h4, checkmate","Checkmate. You win."])
        XCTAssertEqual(ana.heard.lines.suffix(2),["Ben played queen to h4, checkmate","Checkmate. Ben wins."])
        XCTAssertEqual(cy.heard.lines.last,"Checkmate. Ben wins.")
        for mac in [ana,ben,cy]{
            XCTAssertEqual(mac.game.outcome,NetworkOutcome(result:.blackWins,termination:.checkmate))
            XCTAssertNil(mac.game.participation?.role,"the result ends participation");XCTAssertNil(mac.crashFile.pending(),"and the crash file")
            XCTAssertNil(mac.game.stopMessage);XCTAssertFalse(mac.game.canMove);XCTAssertFalse(mac.game.leavingResigns);XCTAssertTrue(mac.game.canReview)
        }
        XCTAssertEqual(ana.roles,[.player,nil]);XCTAssertEqual(ben.roles,[.player,nil]);XCTAssertEqual(cy.roles,[.spectator,nil])
        XCTAssertEqual(ana.game.statusText,"Checkmate. Ben wins.");XCTAssertEqual(ben.game.statusText,"Checkmate. You win.")

        // D9: Review this game: the headers over the moves, as a draft through the import path.
        let record=try XCTUnwrap(ben.game.reviewRecord())
        // The record is dated in this Mac's own calendar, so the expected day is too: noon UTC is the 17th east of UTC+12.
        let local=Calendar(identifier:.gregorian).dateComponents([.year,.month,.day],from:MemoryLAN.day)
        let date=String(format:"%04d.%02d.%02d",local.year!,local.month!,local.day!)
        for header in ["[Event \"Checkmate network game\"]","[Date \"\(date)\"]","[White \"Ana\"]","[Black \"Ben\"]","[Result \"0-1\"]","[TimeControl \"-\"]","[Termination \"Checkmate\"]"] {XCTAssertTrue(record.contains(header),"\(header) in \(record)")}
        XCTAssertTrue(record.hasSuffix("1. f3 e5 2. g4 Qh4# 0-1"),record)
        let review=try XCTUnwrap(PGNImporter.parse(Data(record.utf8)).first);XCTAssertEqual(review.result,"0-1");XCTAssertEqual(review.mainline.count,4)
        XCTAssertEqual(ana.game.reviewRecord(),record,"the host's record is the same game")

        // Back to the lobby: each leaves without resigning anything, and the host's listeners close.
        for mac in [ben,cy,ana]{var done=false;mac.game.leave{done=true};lan.scheduler.advance(by:.seconds(6));XCTAssertTrue(done);XCTAssertNil(mac.game.part);XCTAssertNil(mac.game.seat)}
        XCTAssertEqual(ana.game.title,NetworkGameController.lobbyTitle);XCTAssertEqual(ana.game.board,[:]);XCTAssertTrue(lan.records.isEmpty,"the host withdrew its game");XCTAssertEqual(lan.transport.openListeners,0)
        XCTAssertTrue(ben.game.browsing,"the lobby browses again while it is on screen");XCTAssertTrue(ben.game.games.isEmpty)
    }

    /// D2: a move lost with its connection goes back to its square, and the board never showed it; once the guest is
    /// back it can be played again.
    func testAMoveLostWithTheConnectionGoesBackAndCanBePlayedAgain()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        ben.game.click("e7");ben.game.click("e5");XCTAssertEqual(ben.game.pending?.uci,"e7e5")
        lan.transport.cut(try XCTUnwrap(lan.guestConnection))
        lan.scheduler.run()
        XCTAssertNil(ben.game.pending,"the lost move went back");XCTAssertNotEqual(ben.game.notice,NetworkGameController.sendingNotice)
        XCTAssertEqual(ben.game.link,.live,"the guest reconnected within the hold");XCTAssertEqual(ana.game.link,.live)
        XCTAssertEqual(ben.game.board["e7"],"bp");XCTAssertNil(ben.game.board["e5"]);XCTAssertEqual(ana.game.board["e7"],"bp","the move never reached the game")
        XCTAssertEqual(ben.roles,[.player],"a reconnect is the same participation");XCTAssertTrue(ben.game.canMove)
        play(ben,"e7","e5",lan);XCTAssertEqual(ana.game.board["e5"],"bp")
    }

    /// D9: a seated guest's Leave is a resignation; it ends participation and the crash file at once.
    func testAGuestLeavingResigns()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        XCTAssertTrue(ben.game.leavingResigns);XCTAssertTrue(ben.game.canResign);XCTAssertNotNil(ben.crashFile.pending())
        var done=false;ben.game.leave{done=true}
        XCTAssertEqual(ben.roles,[.player,nil]);XCTAssertNil(ben.crashFile.pending());XCTAssertEqual(ben.game.statusText,"Leaving…");XCTAssertFalse(ben.game.canMove)
        lan.scheduler.advance(by:.seconds(3))
        XCTAssertTrue(done);XCTAssertNil(ben.game.part)
        XCTAssertEqual(ana.game.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation));XCTAssertEqual(ana.game.statusText,"Ben resigned. You win.")
        XCTAssertEqual(ana.heard.lines.last,"Ben resigned. You win.");XCTAssertNil(ana.participation.role);XCTAssertNil(ana.crashFile.pending())
    }

    /// D9 and R3-2: the host's Leave resigns, and `ended` reaches the guest and spectators before the listeners close.
    func testTheHostLeavingResignsAndTellsEveryoneFirst()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana),cy=try joining(lan,"Cy",ana,watching:true)
        play(ana,"e2","e4",lan)
        XCTAssertTrue(ana.game.leavingResigns)
        var done=false;ana.game.leave{done=true};XCTAssertEqual(ana.roles,[.player,nil]);XCTAssertNil(ana.crashFile.pending())
        lan.scheduler.advance(by:.seconds(6))
        XCTAssertTrue(done);XCTAssertNil(ana.game.part);XCTAssertTrue(lan.records.isEmpty);XCTAssertEqual(lan.transport.openListeners,0)
        for mac in [ben,cy]{XCTAssertEqual(mac.game.outcome,NetworkOutcome(result:.blackWins,termination:.resignation));XCTAssertNil(mac.game.stopMessage,"a result, not an interruption");XCTAssertNil(mac.participation.role);XCTAssertTrue(mac.game.canReview)}
        XCTAssertEqual(ben.game.statusText,"Ana resigned. You win.");XCTAssertEqual(cy.game.statusText,"Ana resigned. Ben wins.")
        let record=try XCTUnwrap(cy.game.reviewRecord());XCTAssertTrue(record.contains("[Termination \"Resignation\"]"));XCTAssertTrue(record.hasSuffix("1. e4 0-1"),record)
    }

    /// D9: a spectator just leaves; the game goes on.
    func testASpectatorJustLeaves()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana),cy=try joining(lan,"Cy",ana,watching:true)
        XCTAssertFalse(cy.game.leavingResigns);XCTAssertFalse(cy.game.canResign);XCTAssertFalse(cy.game.canOfferDraw)
        cy.game.leave();XCTAssertEqual(cy.roles,[.spectator,nil]);XCTAssertNil(cy.crashFile.pending())
        lan.scheduler.advance(by:.seconds(3))
        XCTAssertNil(cy.game.part);XCTAssertTrue(ana.game.spectators.isEmpty);XCTAssertNil(ana.game.outcome);XCTAssertEqual(ben.game.link,.live)
        play(ana,"d2","d4",lan)
    }

    /// A host nobody joins never participates; leaving it closes the listeners without a result.
    func testHostingAloneNeverParticipates()throws {
        let lan=MemoryLAN(),ana=try hosting(lan)
        XCTAssertFalse(ana.game.leavingResigns,"nobody to resign to");XCTAssertFalse(ana.game.canResign);XCTAssertEqual(lan.records.count,2)
        var done=false;ana.game.leave{done=true};lan.scheduler.advance(by:.seconds(6))
        XCTAssertTrue(done);XCTAssertNil(ana.game.part);XCTAssertTrue(ana.roles.isEmpty);XCTAssertTrue(lan.records.isEmpty);XCTAssertEqual(lan.transport.openListeners,0)
    }

    /// D9: the host's Mac vanishes. Guest and spectator see "Ana's game has stopped": interrupted, no result, and
    /// reviewable with the result `*`.
    func testAGameWhoseHostVanishesIsInterruptedAndReviewable()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana),cy=try joining(lan,"Cy",ana,watching:true)
        play(ana,"e2","e4",lan);play(ben,"c7","c5",lan)
        for hosting in lan.transport.hostings{hosting.shutdown()}
        lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.reconnecting);XCTAssertEqual(ben.game.statusText,"Reconnecting to Ana's game…");XCTAssertEqual(ben.participation.role,.player,"the seat may still be held")
        XCTAssertFalse(ben.game.canMove,"no moves while the connection is regained")
        lan.scheduler.advance(by:.seconds(130))
        for mac in [ben,cy]{
            XCTAssertEqual(mac.game.link,.stopped);XCTAssertNil(mac.game.outcome);XCTAssertEqual(mac.game.stopMessage,"Ana's game has stopped.");XCTAssertEqual(mac.game.statusText,"Ana's game has stopped.")
            // The seat can still be tried again, so engine help stays off until this Mac gives it up (D8).
            XCTAssertNotNil(mac.participation.role);XCTAssertTrue(mac.game.canTryAgain);XCTAssertFalse(mac.game.sessionOpen);XCTAssertTrue(mac.game.canReview)
            let record=try XCTUnwrap(mac.game.reviewRecord())
            XCTAssertNil(mac.participation.role,"reviewing gives the seat up");XCTAssertNil(mac.crashFile.pending(),"this Mac did not crash")
            XCTAssertTrue(record.contains("[Result \"*\"]"),record);XCTAssertFalse(record.contains("[Termination"),record);XCTAssertTrue(record.hasSuffix("1. e4 c5 *"),record)
        }
        XCTAssertEqual(ben.game.board["c5"],"bp","the board keeps the game for Review")
        ben.game.leave();XCTAssertNil(ben.game.part,"Back to Games")
    }

    /// D4: the guest stays away. The host's seat is held, then Claim Win or Keep Waiting; Keep Waiting holds it
    /// another while, Claim Win ends it as abandoned. The guest's own side gives up with "Ana's game has stopped".
    func testTheHostHoldsTheSeatThenClaimsTheWin()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        lan.transport.stallConnects=true;lan.transport.cut(try XCTUnwrap(lan.guestConnection));lan.scheduler.run()
        XCTAssertEqual(ana.game.link,.away);XCTAssertEqual(ana.game.hostPhase,.disconnected);XCTAssertFalse(ana.game.holdExpired)
        XCTAssertEqual(ana.game.statusText,"Ben is away. Their seat is held for 2 minutes.");XCTAssertTrue(ana.game.canResign);XCTAssertEqual(ana.participation.role,.player)
        lan.scheduler.advance(by:NetworkLimits.holdDuration + .seconds(1))
        XCTAssertTrue(ana.game.holdExpired);XCTAssertEqual(ana.game.statusText,"Ben has been away for a while. Claim the win, or keep waiting.")
        ana.game.keepWaiting();lan.scheduler.run();XCTAssertFalse(ana.game.holdExpired);XCTAssertNil(ana.game.outcome)
        lan.scheduler.advance(by:NetworkLimits.holdDuration + .seconds(1));XCTAssertTrue(ana.game.holdExpired)
        // The guest stopped trying once its reconnect window, the hold, had passed and its last attempt timed out.
        XCTAssertEqual(ben.game.stopMessage,"Ana's game has stopped.");XCTAssertEqual(ben.participation.role,.player,"held until Ben gives it up");XCTAssertTrue(ben.game.canReview)
        ana.game.claimWin();lan.scheduler.run()
        XCTAssertEqual(ana.game.outcome,NetworkOutcome(result:.whiteWins,termination:.abandoned));XCTAssertEqual(ana.game.statusText,"Ben left the game. You win.")
        XCTAssertFalse(ana.game.holdExpired);XCTAssertNil(ana.participation.role);XCTAssertTrue(try XCTUnwrap(ana.game.reviewRecord()).contains("[Termination \"Abandoned\"]"))
    }

    /// D4: Keep Waiting keeps resume valid past the guest's own reconnect window, so a guest that gave up can try again
    /// and resume the same seat with the credential it still holds; nobody else could take it meanwhile.
    func testAGuestThatGaveUpCanTryAgainWhileTheHostKeepsWaiting()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        XCTAssertFalse(ben.game.canTryAgain,"nothing to retry while connected")
        lan.transport.stallConnects=true;lan.transport.cut(try XCTUnwrap(lan.guestConnection));lan.scheduler.run()
        lan.scheduler.advance(by:NetworkLimits.holdDuration + .seconds(1))
        ana.game.keepWaiting();lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(30))
        XCTAssertEqual(ben.game.stopMessage,"Ana's game has stopped.")
        XCTAssertTrue(ben.game.canTryAgain,"a guest that was playing may try again");XCTAssertEqual(ana.game.hostPhase,.disconnected)
        XCTAssertEqual(ben.participation.role,.player,"a seat that can be tried again is still held, so engine help stays off (D8)")
        lan.transport.stallConnects=false
        ben.game.tryAgain();lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.live);XCTAssertNil(ben.game.stopMessage);XCTAssertFalse(ben.game.canTryAgain)
        XCTAssertEqual(ana.game.hostPhase,.running,"the same seat resumed");XCTAssertEqual(ana.game.link,.live)
        XCTAssertEqual(ben.participation.role,.player);XCTAssertEqual(ben.game.board["e4"],"wp")
        play(ben,"e7","e5",lan);XCTAssertEqual(ana.game.board["e5"],"bp")
    }
    /// The clocks a guest saw when its link dropped stay frozen through Try Again: the new connection attempt, still
    /// stalled, does not count the time it was away against the side to move.
    func testTryAgainKeepsTheFrozenClocks()throws {
        let lan=MemoryLAN(),ana=try hosting(lan){$0.timeControl = .threePlusTwo},ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        lan.transport.stallConnects=true;lan.transport.cut(try XCTUnwrap(lan.guestConnection));lan.scheduler.run()
        let frozen=try XCTUnwrap(ben.game.clocks(at:lan.scheduler.now))
        lan.scheduler.advance(by:NetworkLimits.holdDuration + .seconds(1))
        ana.game.keepWaiting();lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(30))
        XCTAssertTrue(ben.game.canTryAgain)
        ben.game.tryAgain();lan.scheduler.run();lan.scheduler.advance(by:.seconds(5))
        XCTAssertNotEqual(ben.game.link,.live,"the new attempt is still stalled")
        let shown=try XCTUnwrap(ben.game.clocks(at:lan.scheduler.now))
        XCTAssertEqual(shown.black,frozen.black,"black's clock did not run while Ben was away");XCTAssertEqual(shown.white,frozen.white);XCTAssertNil(shown.active)
    }
    /// A refusal of another command does not reopen a move still pending: the refused draw claim here arrives while
    /// Ben's move is unanswered, and Ben's turn stays closed until the game answers the move itself (A7).
    func testARefusedClaimKeepsTheMoveStillPending()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        lan.transport.losesToHost={(try? NetworkCodec.decode($0))?.type=="move"}
        ben.game.claimDraw();ben.game.click("e7");ben.game.click("e5")
        XCTAssertEqual(ben.game.pending?.uci,"e7e5")
        lan.scheduler.run()
        XCTAssertEqual(ben.game.pending?.uci,"e7e5","the refused claim was not the move");XCTAssertFalse(ben.game.yourTurn,"so the turn stays closed")
        XCTAssertEqual(ben.game.board["e7"],"bp","nothing played yet")
    }
    /// Assistance follows the turn at once: sending a move tells the assistant before any answer arrives, so a hint
    /// shown for the turn just ended goes with it.
    func testSendingAMoveSettlesTheAssistantAtOnce()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),_=try joining(lan,"Ben",ana)
        var settled=0;ana.game.onSettle={settled+=1}
        ana.game.click("e2");settled=0;ana.game.click("e4")
        XCTAssertNotNil(ana.game.pending);XCTAssertGreaterThan(settled,0,"told before the scheduler ran");XCTAssertFalse(ana.game.yourTurn)
        let before=settled;lan.scheduler.run()
        XCTAssertNil(ana.game.pending);XCTAssertGreaterThan(settled,before,"and again when the answer cleared it")
    }
    /// D11: a connection denied local-network access waits without timing out, shows the permission help, and goes on
    /// by itself once access is granted.
    func testADeniedConnectionShowsTheHelpAndGoesOnOnceAccessIsGranted()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try Mac(lan,name:"Ben")
        ben.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(ben.game.games.first),code=try XCTUnwrap(ana.game.playCode)
        lan.transport.deniesAccess=true
        XCTAssertTrue(ben.game.join(entry,code:code.grouped,watching:false));lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.denied);XCTAssertTrue(ben.game.localNetworkDenied);XCTAssertTrue(ben.game.permissionHelp)
        XCTAssertEqual(ben.game.statusText,"Waiting for Local Network access…")
        lan.scheduler.advance(by:.seconds(60))
        XCTAssertEqual(ben.game.link,.denied,"a denial is not a timeout");XCTAssertNil(ben.game.stopMessage)
        lan.transport.grantAccess();lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.live);XCTAssertFalse(ben.game.localNetworkDenied);XCTAssertFalse(ben.game.permissionHelp)
        XCTAssertEqual(ana.game.hostPhase,.running)
    }
    /// Escape clears a network selection, so clicking a former destination afterwards plays nothing.
    func testClearingTheSelectionForgetsItsDestinations()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),_=try joining(lan,"Ben",ana)
        ana.game.click("e2");XCTAssertEqual(ana.game.selected,"e2");XCTAssertTrue(ana.game.destinations.contains("e4"))
        ana.game.clearSelection();XCTAssertNil(ana.game.selected);XCTAssertTrue(ana.game.destinations.isEmpty)
        ana.game.click("e4");XCTAssertNil(ana.game.pending,"a former dot is just a square now");XCTAssertEqual(ana.game.board["e2"],"wp")
    }
    /// D9: a host whose Mac sleeps stops the game as interrupted, so no clock runs through the sleep; the guest is told.
    func testAHostGoingToSleepStopsTheGameWithoutAResult()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        ana.game.systemWillSleep();lan.scheduler.run()
        XCTAssertEqual(ana.game.link,.stopped);XCTAssertEqual(ana.game.stopMessage,"Your game stopped when this Mac went to sleep.")
        XCTAssertFalse(ana.game.canMove,"a stopped host's board takes no moves");ana.game.click("d2");ana.game.click("d4")
        XCTAssertNil(ana.game.pending);XCTAssertEqual(ana.game.board["d2"],"wp")
        XCTAssertNil(ana.game.outcome);XCTAssertNil(ana.participation.role);XCTAssertFalse(ana.game.canTryAgain)
        XCTAssertEqual(ben.game.stopMessage,"Ana's game has stopped.");XCTAssertNil(ben.participation.role)
        XCTAssertTrue(try XCTUnwrap(ana.game.reviewRecord()).contains("[Result \"*\"]"),"an interrupted game has no result")
    }
    /// D9: a guest whose Mac sleeps leaves at once, so the host pauses its clock now; on waking it resumes the seat.
    func testAGuestGoingToSleepIsAwayAtOnceAndResumes()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        let attempts=lan.transport.connectAttempts
        ben.game.systemWillSleep();lan.scheduler.run()
        XCTAssertEqual(ana.game.hostPhase,.disconnected,"the host knew at once, not at its pong deadline");XCTAssertEqual(ana.game.link,.away)
        XCTAssertEqual(ben.game.link,.reconnecting);XCTAssertEqual(ben.participation.role,.player)
        lan.scheduler.advance(by:.seconds(30))
        XCTAssertEqual(lan.transport.connectAttempts,attempts,"nothing reconnects before waking");XCTAssertEqual(ana.game.hostPhase,.disconnected)
        ben.game.systemDidWake();lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.live);XCTAssertEqual(ana.game.hostPhase,.running,"the same seat resumed")
        play(ben,"e7","e5",lan)
    }
    /// D8: opening Review after giving up lets the seat go, so engine help returns and Try Again is gone.
    func testReviewingAGameGivenUpLetsTheSeatGo()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan)
        lan.transport.stallConnects=true;lan.transport.cut(try XCTUnwrap(lan.guestConnection));lan.scheduler.run()
        lan.scheduler.advance(by:NetworkLimits.holdDuration + .seconds(1))
        ana.game.keepWaiting();lan.scheduler.run()
        lan.scheduler.advance(by:.seconds(30))
        XCTAssertTrue(ben.game.canTryAgain);XCTAssertTrue(ben.game.canReview);XCTAssertEqual(ben.participation.role,.player)
        XCTAssertEqual(NetworkWording.seatHeld,"Your seat is kept for you, so practice help stays off until you review this game or go back to games.")
        XCTAssertNotNil(ben.game.reviewRecord())
        XCTAssertFalse(ben.game.canTryAgain,"reviewing gives up the seat");XCTAssertNil(ben.participation.role)
    }
    /// D5: an offer, its answer either way, and what each side hears.
    func testDrawOffersAreOfferedAnsweredAndHeard()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        XCTAssertTrue(ben.game.canOfferDraw);XCTAssertFalse(ben.game.canAnswerDraw)
        ben.game.offerDraw();lan.scheduler.run()
        XCTAssertEqual(ana.game.openOffer?.by,.black);XCTAssertEqual(ana.heard.lines.last,"Ben offers a draw")
        XCTAssertTrue(ana.game.canAnswerDraw);XCTAssertFalse(ben.game.canAnswerDraw,"not one's own offer");XCTAssertFalse(ben.game.canOfferDraw,"one offer at a time")
        ana.game.answerDraw(accept:false);lan.scheduler.run()
        XCTAssertNil(ana.game.openOffer);XCTAssertNil(ben.game.openOffer);XCTAssertEqual(ben.heard.lines.last,"Ana declined the draw")
        ana.game.offerDraw();lan.scheduler.run();XCTAssertEqual(ben.heard.lines.last,"Ana offers a draw");XCTAssertTrue(ben.game.canAnswerDraw)
        ben.game.answerDraw(accept:true);lan.scheduler.run()
        for mac in [ana,ben]{XCTAssertEqual(mac.game.outcome,NetworkOutcome(result:.draw,termination:.agreement));XCTAssertEqual(mac.game.statusText,"Draw agreed.");XCTAssertEqual(mac.heard.lines.last,"Draw agreed.")}
        XCTAssertFalse(ana.game.canReview,"no moves to review")
    }

    /// D5: threefold repetition is claimable on the claimant's move, and the host checks it on its own rules.
    func testARepetitionIsClaimedOnTheClaimantsMove()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        for (index,move) in ["g1f3","g8f6","f3g1","f6g8","g1f3","g8f6","f3g1","f6g8"].enumerated() {
            let mover=index%2==0 ? ana:ben
            XCTAssertFalse(mover.game.canClaimDraw);play(mover,String(move.prefix(2)),String(move.suffix(2)),lan)
        }
        XCTAssertTrue(ana.game.canClaimDraw);XCTAssertFalse(ben.game.canClaimDraw,"not Ben's move")
        ana.game.claimDraw();lan.scheduler.run()
        for mac in [ana,ben]{XCTAssertEqual(mac.game.outcome,NetworkOutcome(result:.draw,termination:.repetition));XCTAssertEqual(mac.game.statusText,"Draw by threefold repetition.")}
    }

    /// D6 and D10: clocks count down locally between the host's readings, and VoiceOver hears the running clock at
    /// 60, 30 and 10 seconds, once each, until the flag falls.
    func testClocksCountDownLocallyAndAreAnnounced()throws {
        let lan=MemoryLAN(),ana=try hosting(lan){$0.timeControl = .threePlusTwo},ben=try joining(lan,"Ben",ana)
        let start=NetworkClocks(white:180_000,black:180_000,active:nil)
        XCTAssertEqual(ana.game.currentClocks,start);XCTAssertEqual(ben.game.currentClocks,start,"no clock runs before the first move")
        XCTAssertEqual(ben.game.timeControl,.threePlusTwo)
        play(ana,"e2","e4",lan)
        XCTAssertEqual(ana.game.currentClocks,NetworkClocks(white:180_000,black:180_000,active:.black))
        XCTAssertEqual(ana.game.clocks(at:lan.scheduler.now + .seconds(5))?.black,175_000,"the host's reading, counted down locally")
        lan.scheduler.advance(by:.seconds(5))
        XCTAssertEqual(ana.game.currentClocks?.black,175_000);XCTAssertEqual(ana.game.currentClocks?.white,180_000)
        let guest=try XCTUnwrap(ben.game.currentClocks?.black);XCTAssertTrue((174_000...175_000).contains(guest),"\(guest)")
        XCTAssertEqual(ben.game.clocks(at:lan.scheduler.now + .seconds(2))?.black,guest-2000,"the guest counts down between readings")
        XCTAssertTrue(ben.heard.lines.allSatisfy{!$0.contains("seconds left")})
        for (seconds,threshold) in [(116,60),(30,30),(20,10)] {
            lan.scheduler.advance(by:.seconds(seconds))
            XCTAssertEqual(ben.heard.count("You have \(threshold) seconds left"),1,"\(threshold) s, the guest's own clock");XCTAssertEqual(ana.heard.count("Ben has \(threshold) seconds left"),1,"\(threshold) s, on the host")
        }
        lan.scheduler.advance(by:.seconds(10))
        XCTAssertEqual(ben.game.outcome,NetworkOutcome(result:.whiteWins,termination:.time));XCTAssertEqual(ben.game.statusText,"You ran out of time. Ana wins.");XCTAssertEqual(ana.game.statusText,"Ben ran out of time. You win.")
        XCTAssertEqual(ben.game.currentClocks?.black,0)
        for threshold in [60,30,10]{XCTAssertEqual(ben.heard.count("You have \(threshold) seconds left"),1,"announced once")}
        let frozen=ben.game.currentClocks;lan.scheduler.advance(by:.seconds(5));XCTAssertEqual(ben.game.currentClocks,frozen,"clocks stop at the result")
    }

    /// D3 and D11 in the lobby: a name and an 8-character code are needed, Watch needs spectators allowed, and a wrong
    /// code says so in plain words without starting participation.
    func testTheLobbyExplainsWhatItNeeds()throws {
        let lan=MemoryLAN()
        let nobody=try Mac(lan,name:"");XCTAssertFalse(nobody.game.host());XCTAssertEqual(nobody.game.lobbyMessage,NetworkGameController.nameNeeded);XCTAssertNil(nobody.game.part)
        let ana=try hosting(lan){$0.allowSpectators=false};XCTAssertNil(ana.game.watchCode);XCTAssertEqual(lan.records.count,1)
        let ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run();let entry=try XCTUnwrap(ben.game.games.first)
        XCTAssertFalse(ben.game.join(entry,code:"K7QD",watching:false));XCTAssertEqual(ben.game.lobbyMessage,NetworkGameController.codeNeeded)
        XCTAssertFalse(ben.game.join(entry,code:ana.game.playCode!.grouped,watching:true));XCTAssertEqual(ben.game.lobbyMessage,"Ana's game doesn't allow spectators.")
        ben.game.playerName="  ";XCTAssertFalse(ben.game.join(entry,code:ana.game.playCode!.grouped));XCTAssertEqual(ben.game.lobbyMessage,NetworkGameController.nameNeeded)
        ben.game.playerName="Ben"
        var wrong=NetworkCode.random(using:.system);while wrong==ana.game.playCode{wrong=NetworkCode.random(using:.system)}
        XCTAssertTrue(ben.game.join(entry,code:wrong.grouped));XCTAssertNil(ben.game.lobbyMessage)
        lan.scheduler.advance(by:.seconds(30))
        XCTAssertEqual(ben.game.link,.stopped);XCTAssertEqual(ben.game.stopMessage,"Couldn't open Ana's game with that code.");XCTAssertEqual(ben.game.statusText,"Couldn't open Ana's game with that code.")
        XCTAssertTrue(ben.roles.isEmpty);XCTAssertFalse(ben.game.canReview);XCTAssertEqual(ana.game.hostPhase,.waiting,"the host's game is untouched")
        ben.game.leave();XCTAssertNil(ben.game.part);lan.scheduler.run();XCTAssertTrue(ben.game.browsing);XCTAssertEqual(ben.game.games.count,1,"back in the lobby, the game is found again")
    }

    /// D1 and D11: the lobby browses only while shown and before a game is chosen; D11's denial signal shows the
    /// permission help once until dismissed, and access coming back clears it.
    func testBrowsingAndThePermissionHelp()throws {
        let lan=MemoryLAN(),discovery=ScriptedDiscovery(scheduler:lan.scheduler),ben=try Mac(lan,name:"Ben",discovery:discovery)
        lan.scheduler.run();XCTAssertEqual(discovery.starts,0,"nothing browses before the network place is shown")
        ben.game.setShown(true);lan.scheduler.run();XCTAssertEqual(discovery.starts,1);XCTAssertTrue(ben.game.browsing)
        discovery.send(.denied);lan.scheduler.run();XCTAssertTrue(ben.game.localNetworkDenied);XCTAssertTrue(ben.game.permissionHelp)
        ben.game.dismissPermissionHelp();XCTAssertFalse(ben.game.permissionHelp);XCTAssertTrue(ben.game.localNetworkDenied,"the lobby still says access is needed")
        discovery.send(.denied);lan.scheduler.run();XCTAssertFalse(ben.game.permissionHelp,"dismissed help stays dismissed")
        discovery.send(.games([]));lan.scheduler.run();XCTAssertFalse(ben.game.localNetworkDenied,"access came back")
        discovery.send(.denied);lan.scheduler.run();XCTAssertTrue(ben.game.permissionHelp,"a new denial shows the help again")
        discovery.send(.failed("The browser failed."));lan.scheduler.run();XCTAssertEqual(ben.game.lobbyMessage,"Couldn't look for games on your network.")
        discovery.send(.games([]));lan.scheduler.run();XCTAssertFalse(ben.game.permissionHelp,"access came back: the help goes");XCTAssertNil(ben.game.lobbyMessage)
        ben.game.setShown(false);lan.scheduler.run();XCTAssertEqual(discovery.stops,1);XCTAssertFalse(ben.game.browsing)
        // A late update through the callback the stopped browser still held reaches the controller, which ignores it.
        discovery.sendLate(.denied);lan.scheduler.run();XCTAssertFalse(ben.game.permissionHelp,"updates after stopping are dropped");XCTAssertFalse(ben.game.localNetworkDenied)
    }

    /// D9: quitting cleanly leaves the game (a seated player resigns, after the quit's own confirmation) and keeps no
    /// crash file.
    func testShutdownLeavesAndKeepsNoCrashFile()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan);XCTAssertNotNil(ben.crashFile.pending())
        ben.game.shutdown();XCTAssertNil(ben.crashFile.pending());XCTAssertFalse(ben.game.browsing)
        lan.scheduler.advance(by:.seconds(3))
        XCTAssertEqual(ana.game.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation))
        ana.game.shutdown();lan.scheduler.advance(by:.seconds(6));XCTAssertNil(ana.crashFile.pending());XCTAssertEqual(lan.transport.openListeners,0)
    }

    /// Flip Board turns the learner's board round, and only theirs.
    func testFlipBoardTurnsOnlyThisBoard()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        XCTAssertTrue(ben.game.blackAtBottom);ben.game.flip();XCTAssertFalse(ben.game.blackAtBottom);XCTAssertFalse(ana.game.blackAtBottom)
        ben.game.flip();XCTAssertTrue(ben.game.blackAtBottom)
    }
}
/// Assistance plan A2 and A3 through the controller: the host's terms reach the list, a seat is joined only under
/// terms accepted, and a forged list entry is caught inside TLS.
extension NetworkControllerTests {
    func testTheTermsAreAdvertisedAndMustBeAcceptedToJoin()throws {
        let lan=MemoryLAN(),hints=NetworkAssistance(both:.hints)
        let ana=try hosting(lan){$0.assistance=hints}
        XCTAssertEqual(lan.records.map{$0.txt["assist"]},["hh","hh"])
        let ben=try Mac(lan,name:"Ben");ben.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(ben.game.games.first);XCTAssertEqual(entry.assistance,hints)
        let code=ana.game.playCode!.grouped
        XCTAssertFalse(ben.game.join(entry,code:code));XCTAssertEqual(ben.game.lobbyMessage,NetworkGameController.assistanceNeeded);XCTAssertNil(ben.game.part)
        XCTAssertFalse(ben.game.join(entry,code:code,accepting:NetworkAssistance(both:.guided)));XCTAssertEqual(ben.game.lobbyMessage,NetworkGameController.assistanceNeeded)
        XCTAssertTrue(ben.game.join(entry,code:code,accepting:hints));lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.live);XCTAssertEqual(ben.game.record?.assistance,hints);XCTAssertEqual(ana.game.record?.assistance,hints)
        // A spectator accepts nothing.
        let cy=try joining(lan,"Cy",ana,watching:true);XCTAssertEqual(cy.game.record?.assistance,hints)
    }
    /// A forged list entry advertising no assistance: the guest accepts `off`, and the host's check inside TLS refuses it.
    func testAForgedEntryIsRefusedByTheHost()throws {
        let lan=MemoryLAN()
        let ana=try hosting(lan){$0.assistance=NetworkAssistance(white:.off,black:.guided)}
        let forged=lan.records.map{record->NetworkServiceRecord in var txt=record.txt;txt["assist"]="oo";return NetworkServiceRecord(name:record.name,txt:txt,endpoint:record.endpoint)}
        let ben=try Mac(lan,name:"Ben",discovery:NetworkFixedDiscovery(records:forged,scheduler:lan.scheduler));ben.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(ben.game.games.first);XCTAssertEqual(entry.assistance,.off)
        XCTAssertTrue(ben.game.join(entry,code:ana.game.playCode!.grouped));lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.stopped);XCTAssertEqual(ben.game.stopMessage,"Ana's game has different assistance than the one you accepted.")
        XCTAssertTrue(ben.roles.isEmpty,"never seated, so never participating");XCTAssertEqual(ana.game.hostPhase,.waiting,"the seat is still free")
    }
    /// An entry that advertises no terms, as a 1.0 host's do, reads as without assistance and is joined as before. Both
    /// sides here speak 1.1; this checks the missing discovery terms, not a 1.0 handshake (NetworkAssistanceTests has
    /// the 1.0 wire).
    func testAnEntryWithoutTermsReadsAsUnassisted()throws {
        let lan=MemoryLAN(),ana=try hosting(lan)
        let old=lan.records.map{record->NetworkServiceRecord in var txt=record.txt;txt["assist"]=nil;return NetworkServiceRecord(name:record.name,txt:txt,endpoint:record.endpoint)}
        let ben=try Mac(lan,name:"Ben",discovery:NetworkFixedDiscovery(records:old,scheduler:lan.scheduler));ben.game.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(ben.game.games.first);XCTAssertEqual(entry.assistance,.off)
        XCTAssertTrue(ben.game.join(entry,code:ana.game.playCode!.grouped));lan.scheduler.run();XCTAssertEqual(ben.game.link,.live)
        let garbled=NetworkDiscoveredGame.pair([NetworkServiceRecord(name:"X",txt:["game":entry.gameID.text,"role":"seat","assist":"zz"],endpoint:old[0].endpoint)])
        XCTAssertEqual(garbled.first?.assistance,.off,"an unreadable value shows as none; the check inside TLS decides")
    }
    /// Assistance plan A1: at board insight a player picks any piece to inspect, on either turn, and is never shown dots
    /// for a move they cannot make; without it, and for a spectator, clicks work exactly as before.
    func testBoardInsightPicksAnyPieceToInspect()throws {
        let lan=MemoryLAN(),terms=NetworkAssistance(white:.insight,black:.off)
        let ana=try hosting(lan){$0.assistance=terms},ben=try joining(lan,"Ben",ana,accepting:terms),cy=try joining(lan,"Cy",ana,watching:true)
        XCTAssertTrue(ana.game.inspectable);XCTAssertFalse(ben.game.inspectable,"Black's level is off");XCTAssertFalse(cy.game.inspectable,"spectators never")
        ana.game.click("e7");XCTAssertEqual(ana.game.selected,"e7","an opponent's piece on her own move");XCTAssertEqual(ana.game.destinations,[])
        ana.game.click("e2");XCTAssertEqual(ana.game.selected,"e2");XCTAssertFalse(ana.game.destinations.isEmpty,"her own piece still shows its moves")
        ana.game.click("e5");XCTAssertNil(ana.game.selected,"an empty square clears the selection")
        ben.game.click("e7");XCTAssertNil(ben.game.selected,"off Ben's move, a click does nothing, as before")
        play(ana,"e2","e4",lan)
        ana.game.click("g1");XCTAssertEqual(ana.game.selected,"g1","off her move she may still inspect");XCTAssertEqual(ana.game.destinations,[])
        ben.game.click("e4");XCTAssertNil(ben.game.selected,"at off an opponent's piece is not selected")
        ben.game.resign();lan.scheduler.run();XCTAssertFalse(ana.game.inspectable,"the inspector goes with the game")
    }
    /// A12 in VoiceOver: a guest and a spectator hear the terms on joining; everyone hears that a move was made with a
    /// hint shown, by name, and the learner's own as "You".
    func testTheTermsAndHintedMovesAreAnnounced()throws {
        let lan=MemoryLAN(),terms=NetworkAssistance(both:.hints)
        let ana=try hosting(lan){$0.assistance=terms},ben=try joining(lan,"Ben",ana,accepting:terms),cy=try joining(lan,"Cy",ana,watching:true)
        let line="Assistance: hints on request for both players."
        XCTAssertEqual(ben.heard.count(line),1);XCTAssertEqual(cy.heard.count(line),1);XCTAssertEqual(ana.heard.count(line),0,"the host chose them")
        ana.game.hintShown();play(ana,"e2","e4",lan)
        XCTAssertEqual(ben.heard.count("Ana played pawn to e4. Ana used a hint"),1);XCTAssertEqual(cy.heard.count("Ana played pawn to e4. Ana used a hint"),1)
        XCTAssertEqual(ana.heard.count("You played pawn to e4. You used a hint"),1)
        play(ben,"e7","e5",lan);XCTAssertEqual(ana.heard.count("Ben played pawn to e5"),1,"a move without a hint says nothing more")
        XCTAssertEqual(ana.game.record.map{NetworkWording.hintsUsed($0,players:ana.game.players)},"Hints used: Ana 1 · Ben 0")
    }
    /// A record whose moves cannot be shown leaves the board behind the game: no move and no help is taken from it until
    /// a record that loads arrives, the same one again included.
    func testARecordThatCannotBeShownStopsInputUntilOneCan()throws {
        let lan=MemoryLAN(),ana=try hosting(lan){$0.assistance=NetworkAssistance(both:.insight)};_=try joining(lan,"Ben",ana,accepting:NetworkAssistance(both:.insight))
        let good=try XCTUnwrap(ana.game.record);XCTAssertTrue(ana.game.canMove)
        var broken=good;broken.pgn="1. e4 e5 2. Ke3 *";broken.revision=good.revision+3
        let revision=ana.game.gameRevision,fen=ana.game.rules.fen,history=ana.game.rules.history
        ana.game.present(broken,at:lan.scheduler.now)
        XCTAssertEqual(ana.game.record,good,"the unreadable record is not kept");XCTAssertEqual(ana.game.gameRevision,revision,"nor its revision")
        XCTAssertEqual(ana.game.rules.fen,fen,"the board is the last good one");XCTAssertEqual(ana.game.rules.history,history,"none of the broken record's moves stayed")
        XCTAssertFalse(ana.game.canMove);XCTAssertFalse(ana.game.yourTurn);ana.game.click("e2");XCTAssertNil(ana.game.selected,"no input")
        // The record is tried once more after the queue has run; failing again, the learner is told.
        lan.scheduler.run();XCTAssertEqual(ana.game.notice,NetworkWording.recordUnreadable);XCTAssertEqual(ana.heard.count(NetworkWording.recordUnreadable),1)
        ana.game.present(good,at:lan.scheduler.now);XCTAssertTrue(ana.game.canMove,"the shown record arriving again is readable");XCTAssertNil(ana.game.notice)
        XCTAssertEqual(ana.game.rules.fen,fen);XCTAssertEqual(ana.game.rules.history,history)
        play(ana,"e2","e4",lan);XCTAssertEqual(ana.game.rules.history,history+["e4"],"a move from the original position")
    }
    /// The clock announcements keep one alarm waiting, however many readings arrive before its threshold.
    func testClockReadingsKeepOneAnnouncementAlarm()throws {
        let lan=MemoryLAN(),ana=try hosting(lan){$0.timeControl = .threePlusTwo},ben=try joining(lan,"Ben",ana)
        play(ana,"e2","e4",lan);XCTAssertEqual(ben.game.currentClocks?.active,.black)
        lan.scheduler.advance(by:.seconds(1));let settled=lan.scheduler.pending,alarms=ben.game.clockAlarmsScheduled
        XCTAssertGreaterThan(alarms,0,"an alarm waits for the next threshold")
        for _ in 0..<10 {lan.scheduler.advance(by:.seconds(1))}
        XCTAssertEqual(ben.game.clockAlarmsScheduled,alarms,"ten readings scheduled no alarm: the waiting one is reused")
        XCTAssertLessThanOrEqual(lan.scheduler.pending,settled,"ten readings left no alarm behind")
    }
    /// Assistance plan A3: terms this guest finds changed in the host's snapshot stop the game with the same words as
    /// the host's own refusal, not as a broken connection.
    func testOtherTermsInTheHostsSnapshotReadAsChangedAssistance()throws {
        let lan=MemoryLAN(),ana=try hosting(lan),ben=try joining(lan,"Ben",ana)
        var forged=try XCTUnwrap(ben.game.record);forged.assistance=NetworkAssistance(both:.guided)
        let snapshot=try NetworkSnapshot.capture(forged,fen:ben.game.rules.fen,hashing:NetworkHashing(reviewHash),random:.system)
        let link=try XCTUnwrap(lan.transport.links.last{$0.key.role == .seat && $0.open && $0.connection != nil})
        for message in snapshot.messages {lan.transport.deliverLate(.received(try NetworkCodec.encode(message)),to:link)}
        lan.scheduler.run()
        XCTAssertEqual(ben.game.link,.stopped);XCTAssertEqual(ben.game.stopMessage,"Ana's game has different assistance than the one you accepted.")
        XCTAssertEqual(NetworkWording.stop(.assistanceChanged,game:"Ana's game",wasLive:true),NetworkWording.stop(.closedByHost(.assistanceChanged),game:"Ana's game",wasLive:true))
    }
}
