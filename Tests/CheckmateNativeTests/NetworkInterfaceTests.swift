import CheckmateTestSupport
import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

/// LAN-play plan D9–D12 in the app: the Game menu in network mode, the sidebar badge, the empty control bar, the
/// confirmations before leaving or quitting, the review hand-off, the crash notice and the loopback composition. The
/// app's network game runs here over the in-memory transport, against a second controller playing Ben.
@MainActor final class NetworkInterfaceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");unsetenv(NativeModel.networkLoopbackVariable);try? FileManager.default.removeItem(at:directory)}
    private func bar(_ model:NativeModel)->ControlBarModel {ControlBarModel.make(session:model.session,learning:model.learning,review:model.review,training:model.training,voice:.off(available:true))}

    /// One manual scheduler and memory transport; a host's records reach every discovery made here.
    private final class LAN {
        let scheduler=NetworkManualScheduler()
        lazy var transport=NetworkMemoryTransport(scheduler:scheduler)
        private var discoveries:[NetworkFixedDiscovery]=[]
        private(set) var records:[NetworkServiceRecord]=[]
        func services(crashFile:NetworkCrashFile?)->NetworkServices {
            let discovery=NetworkFixedDiscovery(records:records,scheduler:scheduler);discoveries.append(discovery)
            return NetworkServices(transport:transport,discovery:discovery,scheduler:scheduler,delivery:.immediate,rules:NetworkRulesFactory{try ChessRules()},hashing:NetworkHashing(reviewHash),appVersion:"0.8.0",crashFile:crashFile,
                listenersReady:{[weak self] configuration,endpoints in guard let self else{return};self.records=configuration.roles.compactMap{role in endpoints[role].map{NetworkServiceRecord.published(configuration,role,at:$0)}};for discovery in self.discoveries{discovery.publish(self.records)}},
                listenersClosed:{[weak self] _ in guard let self else{return};self.records=[];for discovery in self.discoveries{discovery.publish([])}})
        }
    }
    /// The app hosts as Ana; Ben joins from a second controller. Both are seated and the game runs.
    private func hostedGame(_ model:NativeModel,_ lan:LAN,file:StaticString=#filePath,line:UInt=#line)throws -> NetworkGameController {
        model.network.services=lan.services(crashFile:NetworkCrashFile(dataDirectory:directory));model.network.playerName="Ana"
        XCTAssertTrue(model.network.host(),file:file,line:line);lan.scheduler.run()
        let ben=try NetworkGameController(services:lan.services(crashFile:nil),participation:NetworkParticipation(),playerName:"Ben")
        ben.setShown(true);lan.scheduler.run()
        let entry=try XCTUnwrap(ben.games.first,file:file,line:line)
        XCTAssertTrue(ben.join(entry,code:model.network.playCode!.grouped,accepting:model.network.form.assistance),file:file,line:line);lan.scheduler.run()
        XCTAssertEqual(model.network.hostPhase,.running,file:file,line:line);XCTAssertEqual(ben.link,.live,file:file,line:line)
        return ben
    }

    /// D9: in network mode the Game menu shows only Resign, Offer Draw, Claim Draw, Flip Board and Leave Game, and the
    /// Lesson menu hides; elsewhere the network-only items hide.
    func testTheGameMenuShowsOnlyTheNetworkItemsInNetworkMode(){
        let menu=AppDelegate.makeGameMenu(target:nil),lesson=NSMenuItem(title:"Lesson",action:nil,keyEquivalent:"")
        func visible()->[String] {menu.items.filter{!$0.isHidden}.map{$0.isSeparatorItem ? "—":$0.title}}
        GameWindow.syncMenus(menu,lesson:lesson,network:true)
        XCTAssertEqual(visible(),["Offer Draw","Claim Draw","Resign…","Flip Board","Leave Game…"]);XCTAssertTrue(lesson.isHidden)
        XCTAssertEqual(menu.items.compactMap{$0.identifier?.rawValue}.filter{$0.hasPrefix("network-")},["network-menu-offer-draw","network-menu-flip-board","network-menu-leave-game"])
        GameWindow.syncMenus(menu,lesson:lesson,network:false)
        XCTAssertEqual(visible(),["New Game…","Take Back Move","Restore Previous Game","Claim Draw","Resign…","—","Protected by","Attacked by","Dismiss Piece Inspection"]);XCTAssertFalse(lesson.isHidden)
        GameWindow.syncMenus(menu,lesson:lesson,network:true);GameWindow.syncMenus(menu,lesson:lesson,network:true)
        XCTAssertEqual(visible(),["Offer Draw","Claim Draw","Resign…","Flip Board","Leave Game…"],"repeated syncs change nothing")
        // Assistance plan A1: at board insight the network game's menu also shows the piece inspector.
        GameWindow.syncMenus(menu,lesson:lesson,network:true,inspector:true)
        XCTAssertEqual(Set(visible()),["Offer Draw","Claim Draw","Resign…","Flip Board","Leave Game…","Protected by","Attacked by","Dismiss Piece Inspection"])
    }

    /// The network items follow the network game; outside network mode the shared items keep the window's own rules.
    func testTheNetworkItemsFollowTheGame()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let game=model.network,offer=#selector(GameWindow.offerDraw),flip=#selector(GameWindow.flipBoard),leave=#selector(GameWindow.leaveGame),resign=#selector(GameWindow.resign),claim=#selector(GameWindow.claimDraw)
        for action in [offer,flip,leave]{XCTAssertEqual(GameWindow.networkItemEnabled(action,network:false,game:game),false,"\(action) outside network mode")}
        for action in [resign,claim,#selector(GameWindow.newGame)]{XCTAssertNil(GameWindow.networkItemEnabled(action,network:false,game:game),"practice decides \(action)")}
        XCTAssertNil(GameWindow.networkItemEnabled(#selector(GameWindow.newGame),network:true,game:game))
        for action in [offer,flip,leave,resign,claim]{XCTAssertEqual(GameWindow.networkItemEnabled(action,network:true,game:game),false,"\(action) in the lobby")}
        let lan=LAN(),ben=try hostedGame(model,lan);model.playOnNetwork()
        for action in [offer,flip,leave,resign]{XCTAssertEqual(GameWindow.networkItemEnabled(action,network:true,game:game),true,"\(action) in a running game")}
        XCTAssertEqual(GameWindow.networkItemEnabled(claim,network:true,game:game),false,"nothing to claim")
        ben.offerDraw();lan.scheduler.run();XCTAssertEqual(GameWindow.networkItemEnabled(offer,network:true,game:game),false,"an offer is open")
    }

    /// D9 and D10: away from the network place the sidebar says "Network game · your move" while it is; the control bar
    /// stays empty in network mode; fairness holds while the host's seat is taken.
    func testTheBadgeAndTheEmptyControlBar()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let lan=LAN(),ben=try hostedGame(model,lan),game=model.network
        model.playOnNetwork();XCTAssertEqual(model.session.activity,.at(.network))
        XCTAssertNil(SidebarSelection.networkBadge(model.session.activity,game),"no badge on the network place itself")
        XCTAssertEqual(bar(model),ControlBarModel(),"no new toolbar items (D10)");XCTAssertEqual(model.fairness.participation.role,.player)
        model.practice();XCTAssertEqual(SidebarSelection.networkBadge(model.session.activity,game),NetworkGameController.yourMoveBadge)
        game.play(from:"e2",to:"e4");lan.scheduler.run();XCTAssertNil(SidebarSelection.networkBadge(model.session.activity,game),"Ben's move")
        ben.play(from:"e7",to:"e5");lan.scheduler.run();XCTAssertEqual(SidebarSelection.networkBadge(model.session.activity,game),NetworkGameController.yourMoveBadge,"the game went on while away")
        model.playOnNetwork();XCTAssertEqual(game.board["e5"],"bp");XCTAssertEqual(bar(model),ControlBarModel())
    }

    /// D9: Leave and Resign ask first when they count as a resignation; Cancel keeps the game; quitting asks too, then
    /// waits for the resignation to go out.
    func testLeavingAndQuittingAskFirst()throws {
        let model=try NativeModel();defer{model.shutdown()}
        XCTAssertTrue(model.mayQuitNetworkGame(),"nothing to ask without a game");XCTAssertFalse(model.closeNetworkSession{XCTFail("nothing to wait for")})
        let lan=LAN(),ben=try hostedGame(model,lan),game=model.network
        var asked=0;model.confirmLeavingNetworkGame={asked+=1;return false}
        model.leaveNetworkGame();lan.scheduler.run();XCTAssertEqual(asked,1);XCTAssertEqual(game.part,.host);XCTAssertNil(ben.outcome,"Cancel keeps the game")
        XCTAssertFalse(model.mayQuitNetworkGame(),"Cancel keeps the app open");XCTAssertEqual(asked,2)
        model.confirmResigningNetworkGame={false};model.resignNetworkGame();lan.scheduler.run();XCTAssertNil(ben.outcome)
        model.confirmLeavingNetworkGame={asked+=1;return true}
        XCTAssertTrue(model.mayQuitNetworkGame());XCTAssertEqual(asked,3)
        var closed=false;XCTAssertTrue(model.closeNetworkSession{closed=true})
        lan.scheduler.advance(by:.seconds(6))
        XCTAssertTrue(closed,"the quit goes on once the resignation is out");XCTAssertNil(game.part)
        XCTAssertEqual(ben.outcome,NetworkOutcome(result:.blackWins,termination:.resignation));XCTAssertNil(model.fairness.participation.role)
    }

    /// Confirming Leave still leaves when the same game ended while the confirmation was open.
    func testConfirmingLeaveAfterTheGameEndedMeanwhileStillLeaves()throws {
        let model=try NativeModel();defer{model.shutdown()}
        let lan=LAN(),ben=try hostedGame(model,lan),game=model.network
        model.confirmLeavingNetworkGame={ben.resign();lan.scheduler.run();return true}
        model.leaveNetworkGame();lan.scheduler.run()
        XCTAssertEqual(ben.outcome,NetworkOutcome(result:.whiteWins,termination:.resignation),"Ben resigned while the sheet was open")
        XCTAssertNil(game.part,"the confirmed Leave still left the finished game")
    }

    /// D9: Resign asks, then resigns; Review this game opens the record as a draft review through the import path.
    func testResignThenReviewThisGame()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let lan=LAN(),ben=try hostedGame(model,lan),game=model.network;model.playOnNetwork()
        game.play(from:"e2",to:"e4");lan.scheduler.run();ben.play(from:"e7",to:"e5");lan.scheduler.run()
        XCTAssertFalse(game.canReview,"not while the game runs");model.reviewNetworkGame();XCTAssertFalse(model.importingReview)
        var asked=0;model.confirmResigningNetworkGame={asked+=1;return true}
        model.resignNetworkGame();lan.scheduler.run()
        XCTAssertEqual(asked,1);XCTAssertEqual(game.outcome,NetworkOutcome(result:.blackWins,termination:.resignation));XCTAssertTrue(game.canReview)
        model.reviewNetworkGame()
        for _ in 0..<300 where !model.review.active{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(model.review.document)
        XCTAssertEqual(document.header("Event"),"Checkmate network game");XCTAssertEqual(document.header("White"),"Ana");XCTAssertEqual(document.header("Black"),"Ben")
        XCTAssertEqual(document.result,"0-1");XCTAssertEqual(document.header("Termination"),"Resignation");XCTAssertEqual(document.mainline.count,2)
        XCTAssertEqual(model.session.activity.review?.draft,true,"a draft review");XCTAssertEqual(model.session.activity.review?.returnTo,.network)
    }

    /// D9: the next launch reads the crash file once, says its notice, offers Review when there are moves, and deletes it.
    func testTheCrashNoticeIsReadOnceAndReviewable()async throws {
        let model=try NativeModel();defer{model.shutdown()}
        let file=try XCTUnwrap(model.network.services?.crashFile,"the app keeps a crash file in its data directory")
        XCTAssertNil(model.takeNetworkCrashNotice(),"nothing to say after a clean exit")
        let game=NetworkPublicGame(gameID:.random(using:.system),revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"1. e4 e5",clocks:nil,openOffer:nil,outcome:nil)
        try file.save(NetworkCrashFile.Entry(game:game,part:.white))
        let entry=try XCTUnwrap(model.takeNetworkCrashNotice())
        XCTAssertEqual(entry.notice,"Your network game with Ben ended when Checkmate closed.");XCTAssertNil(file.pending(),"read once, then deleted");XCTAssertNil(model.takeNetworkCrashNotice())
        XCTAssertTrue(NativeModel.reviewable(entry))
        var empty=game;empty.pgn="";XCTAssertFalse(NativeModel.reviewable(NetworkCrashFile.Entry(game:empty,part:.black)),"no moves, nothing to review")
        model.reviewNetworkCrash(entry)
        for _ in 0..<300 where !model.review.active{try await Task.sleep(for:.milliseconds(10))}
        let document=try XCTUnwrap(model.review.document);XCTAssertEqual(document.result,"*","an interrupted game");XCTAssertEqual(document.mainline.count,2)
        XCTAssertEqual(model.session.activity.review?.draft,true)
    }

    /// D10: the host sheet's choices and defaults, and how the pane writes and speaks clocks and codes.
    func testTheHostSheetAndThePanesText()throws {
        XCTAssertEqual(NetworkTimeControl.allCases.map(NetworkHostSheet.label),["Untimed","3 + 2","5 + 3","10 + 5","15 + 10","30 + 0"])
        let form=NetworkHostForm();XCTAssertEqual(form.timeControl,.untimed,"untimed by default");XCTAssertEqual(form.side,.white);XCTAssertTrue(form.allowSpectators)
        XCTAssertEqual(NetworkDetail.clock(180_000),"3:00");XCTAssertEqual(NetworkDetail.clock(65_001),"1:06","rounded up");XCTAssertEqual(NetworkDetail.clock(0),"0:00");XCTAssertEqual(NetworkDetail.clock(-5),"0:00")
        XCTAssertEqual(NetworkDetail.spokenClock(65_000),"1 minute 5 seconds");XCTAssertEqual(NetworkDetail.spokenClock(120_000),"2 minutes");XCTAssertEqual(NetworkDetail.spokenClock(1_000),"1 second");XCTAssertEqual(NetworkDetail.spokenClock(0),"0 seconds")
        let code=try XCTUnwrap(NetworkCode(typed:"K7QD2M9X"));XCTAssertEqual(code.grouped,"K7QD-2M9X");XCTAssertEqual(NetworkDetail.spelled(code),"K 7 Q D, 2 M 9 X")
        XCTAssertEqual(NetworkGameController.gameName(host:"Ana"),"Ana's game")
    }

    /// A position-only engine whose every hint is Nf3.
    @MainActor private final class KnightEngine:TestEngineService {
        func analyze(fen:String,skill:Int,budget:Int,multiPv:Int)async throws -> EngineAnalysis {EngineAnalysis(bestMove:"g1f3")}
        func analyzeHistory(startFEN:String,moves:[String],profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int)async throws -> EngineAnalysis {EngineAnalysis(bestMove:"g1f3")}
    }
    /// Assistance plan A1, A6 and A12 in the window: under hints for both, P inspects the network board's pieces (an
    /// opponent's too), Escape dismisses it, the Hint's arrow is drawn and the pane shows the terms and counts. Without
    /// assistance P does nothing and the inspector stays out of the Game menu.
    func testTheInspectorAndTheHintOnTheNetworkBoard()async throws {
        let model=try NativeModel(),game=GameWindow(model:model);defer{game.window?.delegate=nil;model.shutdown()}
        let lan=LAN();model.network.form.assistance=NetworkAssistance(both:.hints)
        let ben=try hostedGame(model,lan);model.playOnNetwork();game.refresh()
        XCTAssertTrue(model.network.inspectable);XCTAssertEqual(model.fairness.networkAssistance,.hints)
        game.select("e2");XCTAssertEqual(game.board.selected,"e2")
        game.toggleRelationship(.protected)
        XCTAssertEqual(game.relationships.report?.mode,.protected);XCTAssertEqual(game.relationships.report?.square,"e2")
        XCTAssertTrue(game.board.relationshipConnectors.contains{$0.source=="e1" && $0.target=="e2"},"the king protects the pawn")
        game.select("d7");XCTAssertEqual(game.relationships.report?.square,"d7","an opponent's piece is inspected too");XCTAssertEqual(model.network.selected,"d7")
        game.dismissInspection();XCTAssertNil(game.relationships.mode)
        model.networkAssistant.engine=KnightEngine();model.networkAssistant.ask()
        for _ in 0..<200 where model.networkAssistant.hint==nil{try await Task.sleep(for:.milliseconds(5))}
        game.refresh();XCTAssertEqual(game.board.arrows,[["g1","f3"]],"the hint's arrow");XCTAssertTrue(model.network.assistedThisTurn)
        model.network.click("g1");model.network.click("f3");lan.scheduler.run();game.refresh()
        XCTAssertEqual(ben.record.map{NetworkWording.hintsUsed($0,players:ben.players)},"Hints used: Ana 1 · Ben 0");XCTAssertEqual(game.board.arrows,[],"the hint goes with the turn")
        // Off: the same clicks and keys inspect nothing.
        model.network.leave();lan.scheduler.run()
        let plain=LAN();model.network.form.assistance = .off
        _=try hostedGame(model,plain);game.refresh()
        XCTAssertFalse(model.network.inspectable);game.select("e2");game.toggleRelationship(.protected)
        XCTAssertNil(game.relationships.mode,"P does nothing without assistance");XCTAssertNil(game.relationships.selectedLabel)
    }

    /// D12: an isolated automation run with `CHECKMATE_NETWORK_LOOPBACK_DIR` gets loopback listeners and the shared
    /// directory's discovery, and its hosted games are published there; without it, a build declaring no Bonjour
    /// service type says it cannot browse.
    func testTheLoopbackGateIsComposedOnlyOnRequest()throws {
        XCTAssertTrue(AppDelegate.isolatedAutomation,"fixture: an isolated automation run")
        let plain=NativeModel.networkServices(directory:directory)
        XCTAssertTrue(plain.discovery is NetworkUnavailableDiscovery,"the test runner declares no Bonjour service type")
        let shared=directory.appendingPathComponent("lan",isDirectory:true);setenv(NativeModel.networkLoopbackVariable,shared.path,1)
        let loopback=NativeModel.networkServices(directory:directory)
        XCTAssertFalse(loopback.discovery is NetworkUnavailableDiscovery);XCTAssertTrue((loopback.transport as? NWNetworkTransport)?.configuration.loopbackOnly == true)
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        loopback.listenersReady(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_003)])
        let published=shared.appendingPathComponent(configuration.gameID.text+".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath:published.path))
        loopback.listenersClosed(configuration.gameID);XCTAssertFalse(FileManager.default.fileExists(atPath:published.path))
    }
}
