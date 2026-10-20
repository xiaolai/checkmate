import XCTest
@testable import CheckmateDomain

/// Mini-games plan WI-023 (D7, L1, `docs/network-protocol-1.2.md`): capabilities on every `hello` and `resume`,
/// admission before anything else, a declared start pinned by the first snapshot, starts the host refuses, ply parity
/// from the start, and protocol 1.2 against the frozen 1.1 bytes. On the fake rules; the real rules' side is in
/// CheckmateCoreTests (`NetworkRulesTests`, `NetworkGameRecordTests`).
final class NetworkStartTests:XCTestCase {
    /// Black to move at move 37: the FakeRules treat any well-formed FEN as canonical unless scripted.
    let black37="8/8/4k3/8/8/4K3/4P3/8 b - - 0 37"
    let other="8/8/4k3/8/8/4K3/4P3/8 w - - 0 37"
    let legacy=NetworkCapabilities.none
    private func messages(_ net:TestNetwork,_ id:NetworkConnectionID)->[String] {net.messages(id).map(\.type)}

    // MARK: Capabilities on the wire
    func testCapabilitiesRoundTripSortedAndAreBounded()throws {
        let random=TestRandom(seed:21),game=NetworkGameID.random(using:random.source),credential=NetworkSecret.random(using:random.source)
        let stated=try XCTUnwrap(NetworkCapabilities(["zeta","start","ruleset:mini:pawn-duel@1"]))
        XCTAssertEqual(stated.tokens,["ruleset:mini:pawn-duel@1","start","zeta"],"sorted, as written")
        for message:NetworkMessage in [.hello(name:"Ben",appVersion:"0.9.0",claimID:nil,capabilities:stated),.resume(gameID:game,credential:credential,capabilities:stated)] {
            let data=try NetworkCodec.encode(message)
            XCTAssertEqual(try NetworkCodec.decode(data),message)
            XCTAssertTrue(String(decoding:data,as:UTF8.self).contains(#""capabilities":["ruleset:mini:pawn-duel@1","start","zeta"]"#))
            // The frozen 1.0 rules, which 1.1 kept for every field it did not add, still read the message.
            XCTAssertNoThrow(try Legacy10Wire.decode(data))
        }
        // None stated is no field at all: the 1.1 shape.
        XCTAssertFalse(String(decoding:try NetworkCodec.encode(.hello(name:"Ben",appVersion:"1",claimID:nil,capabilities:NetworkCapabilities.none)),as:UTF8.self).contains("capabilities"))
        XCTAssertNil(NetworkCapabilities(Array(repeating:"a",count:2)),"a token twice")
        XCTAssertNil(NetworkCapabilities((0..<9).map{"t\($0)"}),"more than 8")
        XCTAssertNil(NetworkCapabilities([String(repeating:"x",count:33)]),"over 32 bytes")
        XCTAssertNotNil(NetworkCapabilities([String(repeating:"x",count:32)]),"32 bytes")
        XCTAssertNotNil(NetworkCapabilities((0..<8).map{"t\($0)"}),"8 tokens")
        let base=#"{"appVersion":"1","name":"Ben","protocol":{"major":1,"minor":2},"type":"hello","capabilities":"#
        for bad in [#"["a","a"]"#,#"[""]"#,#"["has space"]"#,#"["\u0007"]"#,#"["é"]"#,"["+(0..<9).map{"\"t\($0)\""}.joined(separator:",")+"]","[\""+String(repeating:"x",count:33)+"\"]",#""start""#,"[1]"] {
            XCTAssertThrowsError(try NetworkCodec.decode(Data((base+bad+"}").utf8)),bad){XCTAssertEqual(($0 as? NetworkCodecError)?.byeReason,.malformed,bad)}
        }
        let resume=#"{"credential":"\#(credential.text)","gameID":"\#(game.text)","protocol":{"major":1,"minor":2},"type":"resume","capabilities":["a","a"]}"#
        XCTAssertThrowsError(try NetworkCodec.decode(Data(resume.utf8)),"resume is bounded the same way")
    }

    // MARK: Admission (D7)
    func testAGuestWithoutTheCapabilityIsRefusedBeforeTheSeatIsReserved()throws {
        let net=try TestNetwork(start:black37)
        XCTAssertEqual(net.host.requiredCapabilities.tokens,[NetworkStart.capability])
        let watcher=net.client(.watch,name:"Cy");try net.connect(watcher)
        let old=net.client(.seat,capabilities:legacy);try net.connect(old)
        let id=try XCTUnwrap(net.closes.first{$0.value == .protocolVersion}?.key)
        XCTAssertEqual(messages(net,id),[],"nothing was sent before the refusal: no seated, no snapshot")
        XCTAssertEqual(old.closedWith,.protocolVersion);XCTAssertNil(old.receiver.installed);XCTAssertNil(old.receiver.credential)
        XCTAssertEqual(net.host.phase,.waiting,"no seat reserved");XCTAssertNil(net.host.guestName)
        XCTAssertEqual(watcher.received.filter{if case .snapshotBegin=$0 {return true};return false}.count,1,"spectators were not refreshed")
        // A 1.2 guest is let in, and installs the declared start.
        let guest=net.client(.seat);try net.connect(guest)
        XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(guest.receiver.pinnedStart,black37);XCTAssertEqual(guest.receiver.installed?.startFEN,black37)
        XCTAssertEqual(guest.receiver.side,.black);XCTAssertEqual(try guest.receiver.publicGame(at:net.now)?.startFEN,black37)
    }
    func testASpectatorIsNegotiatedTheSameWay()throws {
        let net=try TestNetwork(start:black37)
        let old=net.client(.watch,name:"Old",capabilities:legacy);try net.connect(old)
        XCTAssertEqual(old.closedWith,.protocolVersion);XCTAssertEqual(net.host.spectators,[]);XCTAssertNil(old.receiver.installed)
        let watcher=net.client(.watch,name:"Cy");try net.connect(watcher)
        XCTAssertEqual(net.host.spectatorNames,["Cy"]);XCTAssertEqual(watcher.receiver.pinnedStart,black37)
        // Withdrawn: the same spectator's next connection states nothing.
        try net.cut(watcher)
        let id=try net.open(.watch);try net.send(.hello(name:"Cy",appVersion:"0.8.0",claimID:nil),on:id)
        XCTAssertEqual(net.closes[id],.protocolVersion);XCTAssertEqual(messages(net,id),[]);XCTAssertEqual(net.host.spectators,[])
    }
    /// A standard-start game requires nothing: a 1.1 guest and spectator still play and watch it.
    func testAStandardStartGameStillAdmitsA11Mac()throws {
        let net=try TestNetwork()
        XCTAssertEqual(net.host.requiredCapabilities,.none)
        let guest=net.client(.seat,capabilities:legacy),watcher=net.client(.watch,name:"Cy",capabilities:legacy)
        try net.connect(guest);try net.connect(watcher)
        XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(net.host.spectatorNames,["Cy"]);XCTAssertEqual(guest.receiver.pinnedStart,NetworkStart.standard)
        XCTAssertNil(try net.host.publicGame(at:net.now).startFEN)
    }
    /// The reservation is recovered by `hello` with the same claim: without the capability the seat stays reserved
    /// and unanswered; with it, the claim is answered again.
    func testReservationRecoveryNeedsTheCapability()throws {
        let net=try TestNetwork(start:black37)
        let claim=NetworkSecret.random(using:net.random.source)
        let guest=net.client(.seat,claimID:claim);guest.lose=["seatedAck"];try net.connect(guest)
        XCTAssertEqual(net.host.phase,.reserved)
        let first=try XCTUnwrap(net.host.guestConnection)
        let id=try net.open(.seat);try net.send(.hello(name:"Ben",appVersion:"0.8.0",claimID:claim,assistance:.off),on:id)
        XCTAssertEqual(net.closes[id],.protocolVersion);XCTAssertEqual(messages(net,id),[])
        XCTAssertEqual(net.host.phase,.reserved);XCTAssertEqual(net.host.guestConnection,first,"the reserving connection is still the seat's")
        // A `resume` while reserved, without it, is refused the same way and is not taken as the ack.
        let resume=try net.open(.seat);try net.send(.resume(gameID:net.gameID,credential:try XCTUnwrap(guest.receiver.credential)),on:resume)
        XCTAssertEqual(net.closes[resume],.protocolVersion);XCTAssertEqual(net.host.phase,.reserved)
        guest.lose=[];try net.cut(guest);try net.connect(guest)
        XCTAssertEqual(net.host.phase,.running,"the capable guest resumed its reservation")
    }
    /// `resume` while running (a replacement connection) and while disconnected (the hold): without the capability
    /// nothing changes, the clocks stay paused, and the guest's own connection stays attached.
    func testResumeWithoutTheCapabilityChangesNothing()throws {
        let net=try TestNetwork(timeControl:.threePlusTwo,start:black37)
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.play(guest,"e6d6")
        let attached=try XCTUnwrap(net.host.guestConnection),credential=try XCTUnwrap(guest.receiver.credential)
        let replacing=try net.open(.seat);try net.send(.resume(gameID:net.gameID,credential:credential),on:replacing)
        XCTAssertEqual(net.closes[replacing],.protocolVersion);XCTAssertEqual(messages(net,replacing),[])
        XCTAssertEqual(net.host.guestConnection,attached,"not replaced");XCTAssertEqual(net.host.phase,.running);XCTAssertNil(net.closes[attached])
        try net.cut(guest);XCTAssertEqual(net.host.phase,.disconnected)
        let paused=try XCTUnwrap(net.host.publicGame(at:net.now).clocks);XCTAssertNil(paused.active)
        let watcherMessages=watchers[0].received.count
        try net.advance(3)
        let late=try net.open(.seat);try net.send(.resume(gameID:net.gameID,credential:credential),on:late)
        XCTAssertEqual(net.closes[late],.protocolVersion);XCTAssertEqual(messages(net,late),[])
        XCTAssertEqual(net.host.phase,.disconnected,"the hold goes on");XCTAssertNil(net.host.guestConnection)
        XCTAssertNil(try net.host.publicGame(at:net.now).clocks?.active,"the clocks stay paused")
        XCTAssertFalse(watchers[0].received.dropFirst(watcherMessages).contains{if case .clock(let clocks)=$0 {return clocks.active != nil};return false},"spectators were not told the clocks run")
        // The capable guest resumes.
        try net.connect(guest);XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(guest.receiver.pinnedStart,black37)
        // The guest's own connection withdrawing the capability in a later `resume` is refused too.
        let own=try XCTUnwrap(net.host.guestConnection)
        try net.send(.resume(gameID:net.gameID,credential:credential),on:own)
        XCTAssertEqual(net.closes[own],.protocolVersion);XCTAssertEqual(net.host.phase,.disconnected)
    }

    // MARK: Start pinning (D7)
    private func snapshot(_ game:NetworkPublicGame,random:TestRandom)throws -> [NetworkMessage] {
        let rules=FakeRules(script:FakeScript());try rules.networkLoad(pgn:game.pgn)
        return try NetworkSnapshot.capture(game,fen:try rules.networkFEN(),hashing:testHashing,random:random.source).messages
    }
    private func record(_ gameID:NetworkGameID,start:String?,moves:[String]=[],revision:Int?=nil)->NetworkPublicGame {
        NetworkPublicGame(gameID:gameID,revision:revision ?? moves.count,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"[Fake]\n"+(start.map{"[FEN \($0)]\n"} ?? "")+moves.joined(separator:" "),clocks:nil,openOffer:nil,outcome:nil,startFEN:start)
    }
    private func deliver(_ receiver:NetworkReceiver,_ messages:[NetworkMessage])throws -> NetworkReceiverOutput {
        var last=NetworkReceiverOutput()
        for message in messages {last=try receiver.receive(message:message,at:.origin);if last.close != nil {break}}
        return last
    }
    /// A later snapshot or resync declaring another start is refused at the same and at a newer revision, for a game
    /// with no moves, for castling or en passant rights alone, after a reconnect, and from the standard start.
    func testAnAlteredStartIsRefusedAfterTheFirstSnapshot()throws {
        let random=TestRandom(seed:31),gameID=NetworkGameID.random(using:random.source)
        let castling="r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",fewerRights="r3k2r/8/8/8/8/8/8/R3K2R w Kkq - 0 1"
        let passant="4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2",noPassant="4k3/8/8/3pP3/8/8/8/4K3 w - - 0 2"
        let cases:[(String,String?,NetworkPublicGame,NetworkPublicGame)]=[
            ("zero moves, same revision",black37,record(gameID,start:black37),record(gameID,start:other)),
            ("newer revision, same moves",black37,record(gameID,start:black37,moves:["e6d6"]),record(gameID,start:other,moves:["e6d6","e3d3"])),
            ("castling rights",castling,record(gameID,start:castling),record(gameID,start:fewerRights)),
            ("en passant rights",passant,record(gameID,start:passant,moves:["e1e2"]),record(gameID,start:noPassant,moves:["e1e2"])),
            ("a start where there was none",nil,record(gameID,start:nil,moves:["e2e4"]),record(gameID,start:black37,moves:["e2e4"])),
            ("none where there was one",black37,record(gameID,start:black37),record(gameID,start:nil)),
        ]
        for (name,pinned,first,altered) in cases {
            for role in [NetworkReceiverRole.guest(claimID:.random(using:random.source)),.spectator] {
                let receiver=NetworkReceiver(gameID:gameID,role:role,name:"Ben",appVersion:"0.9.0",rules:NetworkRulesFactory{FakeRules(script:FakeScript())},hashing:testHashing,random:random.source)
                let admit:NetworkMessage=role == .spectator ? .watching:.seated(credential:.random(using:random.source))
                XCTAssertNil(try deliver(receiver,[admit]+snapshot(first,random:random)).close,name)
                XCTAssertEqual(receiver.pinnedStart,pinned ?? NetworkStart.standard,name)
                let shown=receiver.fen
                // As a resync's answer, on the same connection.
                XCTAssertEqual(try deliver(receiver,snapshot(altered,random:random)).close,.malformed,name)
                XCTAssertEqual(receiver.fen,shown,"\(name): the board is untouched");XCTAssertEqual(receiver.installed,first,name)
                // After a reconnect the pin holds.
                receiver.connectionLost()
                let again:NetworkMessage=role == .spectator ? .watching:.resumed
                XCTAssertEqual(try deliver(receiver,[again]+snapshot(altered,random:random)).close,.malformed,"\(name), after a reconnect")
                receiver.connectionLost()
                XCTAssertNil(try deliver(receiver,[again]+snapshot(first,random:random)).close,"\(name): the same start is accepted again")
            }
        }
    }
    /// The installer's own checks: a start the rules refuse or write back otherwise, a record whose FEN header is
    /// another start, a malformed `startFEN`, and the standard start written out.
    func testTheInstallerRefusesAStartThatIsNotTheRecordsOwnOrNotCanonical()throws {
        let random=TestRandom(seed:41),gameID=NetworkGameID.random(using:random.source),script=FakeScript()
        let factory=NetworkRulesFactory{FakeRules(script:script)}
        func install(_ game:NetworkPublicGame,fen:String?=nil)throws {
            let rules=FakeRules(script:FakeScript());try rules.networkLoad(pgn:game.pgn)
            _ = try NetworkSnapshotInstaller.install(try game.encoded(),revision:game.revision,hash:testHashing.positionHash(fen:fen ?? (try rules.networkFEN()),revision:game.revision),gameID:gameID,rules:factory,hashing:testHashing)
        }
        XCTAssertNoThrow(try install(record(gameID,start:black37,moves:["e6d6"])))
        script.illegalStarts=[black37]
        XCTAssertThrowsError(try install(record(gameID,start:black37))){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"),"refused by the rules")}
        script.illegalStarts=[];script.canonical=[black37:other]
        XCTAssertThrowsError(try install(record(gameID,start:black37))){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"),"not canonical")}
        script.canonical=[:]
        var forged=record(gameID,start:black37,moves:["e6d6"]);forged.pgn="[Fake]\n[FEN \(other)]\ne6d6"
        XCTAssertThrowsError(try install(forged)){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"),"the record sets up another start")}
        var undeclared=record(gameID,start:nil,moves:["e6d6"]);undeclared.pgn="[Fake]\n[FEN \(black37)]\ne6d6"
        XCTAssertThrowsError(try install(undeclared)){XCTAssertEqual($0 as? NetworkSnapshotError,.badSnapshot("start"),"a start the record does not declare")}
        for bad in [NetworkStart.standard,"8/8/8 w - - 0 1","8/8/4k3/8/8/4K3/4P3/8 x - - 0 1","8/8/4k3/8/8/4K3/4P3/8 w - - 0 10000","8/8/4k3/8/8/4K3/4P3/8  w - - 0 1",black37+String(repeating:" ",count:100)] {
            var game=record(gameID,start:nil);game.startFEN=bad
            XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try game.encoded()),bad)
        }
    }

    // MARK: Hosting refuses (D7)
    func testHostingRefusesAnIllegalOrFinishedStartAndKeepsTheCanonicalOne()throws {
        XCTAssertThrowsError(try TestNetwork(start:black37){$0.illegalStarts=[self.black37]}){XCTAssertEqual($0 as? NetworkHostError,.illegalStart)}
        XCTAssertThrowsError(try TestNetwork(start:black37){$0.overStarts=[self.black37]}){XCTAssertEqual($0 as? NetworkHostError,.startOver)}
        XCTAssertThrowsError(try TestNetwork(start:"8/8/4k3/8/8/4K3/4P3/8 b - - 0 10000")){XCTAssertEqual($0 as? NetworkHostError,.illegalStart,"no record could declare it")}
        let canonical=try TestNetwork(start:"written otherwise"){$0.canonical=["written otherwise":self.black37]}
        XCTAssertEqual(canonical.host.settings.startFEN,black37);XCTAssertEqual(try canonical.host.publicGame(at:canonical.now).startFEN,black37)
        XCTAssertEqual(canonical.host.fen,black37);XCTAssertEqual(canonical.host.sideToMove,.black)
        // The standard start, however it was given, is no declared start: exactly a 1.1 game.
        let standard=try TestNetwork(start:"the standard start"){$0.canonical=["the standard start":NetworkStart.standard]}
        XCTAssertNil(standard.host.settings.startFEN);XCTAssertEqual(standard.host.requiredCapabilities,.none)
        XCTAssertEqual(try standard.host.publicGame(at:standard.now),try TestNetwork().host.publicGame(at:.origin).with(gameID:standard.gameID))
    }

    // MARK: Ply parity (D7)
    func testAssistedPliesAndHeadersCountFromTheStart()throws {
        let net=try TestNetwork(assistance:NetworkAssistance(both:.hints),start:black37)
        let (guest,watchers)=try net.startGame(spectators:1)
        XCTAssertEqual(guest.receiver.side,.black,"the guest plays Black, who moves first here")
        try net.play(guest,"e6d6",assisted:true);try net.hostPlays("e3d3",assisted:true);try net.play(guest,"d6e5",assisted:true)
        let game=try net.host.publicGame(at:net.now)
        XCTAssertEqual(game.assistedPlies,[1,2,3])
        XCTAssertEqual(game.assistedMoves(by:.black),2,"plies 1 and 3 are Black's");XCTAssertEqual(game.assistedMoves(by:.white),1)
        for client in [guest]+watchers {let seen=try XCTUnwrap(try client.receiver.publicGame(at:net.now));XCTAssertEqual(seen.assistedMoves(by:.black),2);XCTAssertEqual(seen.startFEN,black37)}
        let headers=game.recordHeaders(date:"2026.10.18")
        XCTAssertEqual(headers.map(\.name),["Event","Site","Date","Round","White","Black","Result","SetUp","FEN","TimeControl","Assistance"])
        XCTAssertEqual(headers.first{$0.name=="FEN"}?.value,black37);XCTAssertEqual(headers.first{$0.name=="SetUp"}?.value,"1")
        var standard=game;standard.startFEN=nil
        XCTAssertEqual(standard.assistedMoves(by:.white),2,"from the standard start White makes the odd plies")
        XCTAssertFalse(standard.recordHeaders(date:"2026.10.18").contains{$0.name=="FEN" || $0.name=="SetUp"})
    }
    func testTheStartsShapeAndStructure(){
        XCTAssertEqual(NetworkStart.side(black37),.black);XCTAssertEqual(NetworkStart.fullmove(black37),37)
        XCTAssertEqual(NetworkStart.side(NetworkStart.standard),.white);XCTAssertEqual(NetworkStart.fullmove(NetworkStart.standard),1)
        XCTAssertTrue(NetworkStart.wellFormed(black37));XCTAssertTrue(NetworkStart.consistent(NetworkStart.standard));XCTAssertTrue(NetworkStart.consistent(black37))
        for (fen,why) in [("4k3/8/8/8/8/8/8/4K3 w K - 0 1","a right with no rook"),("4k2r/8/8/8/8/8/8/R2K4 w Q - 0 1","a right with the king off its square"),("r3k2r/8/8/8/8/8/8/R4K1R w K - 0 1","White's king moved"),
                          ("4k3/8/8/4P3/8/8/8/4K3 w - d6 0 2","no pawn beyond the square"),("4k3/3p4/8/3pP3/8/8/8/4K3 w - d6 0 2","the pawn's start square is occupied"),("4k3/8/8/8/3P4/8/8/4K3 w - d3 0 2","the wrong side's square"),("4k3/8/8/8/8/8/4K3 w - - 0 1","not eight ranks")] {
            XCTAssertFalse(NetworkStart.consistent(fen),why)
        }
        XCTAssertTrue(NetworkStart.consistent("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2"),"Black's pawn has just passed d6")
        XCTAssertTrue(NetworkStart.consistent("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 2"),"White's pawn has just passed d3")
    }

    // MARK: The compatibility promise (D7), against the bytes 1.1 wrote
    /// 1. A 1.2 Mac (and a 1.3 one, protocol 1.3's promise) decodes every frozen 1.1 message, and re-encodes it to the
    /// same bytes but for the minor version.
    func testEveryFrozen11MessageDecodesAndKeepsItsBytes()throws {
        XCTAssertEqual(NetworkProtocolVersion.current,NetworkProtocolVersion(major:1,minor:3))
        XCTAssertEqual(Set(try Legacy11Fixtures.messages.map{try NetworkCodec.decode(Data($0.utf8)).type}).count,24,"every message type")
        for text in Legacy11Fixtures.messages {
            let message=try NetworkCodec.decode(Data(text.utf8))
            switch message {
            case .hello(_,_,_,_,let capabilities),.resume(_,_,let capabilities):XCTAssertNil(capabilities,"a 1.1 Mac states none")
            default:break
            }
            XCTAssertEqual(String(decoding:try NetworkCodec.encode(message),as:UTF8.self),text.replacingOccurrences(of:#""minor":1"#,with:#""minor":3"#))
        }
    }
    /// 2. A standard-start game's record is 1.1's, byte for byte, both ways.
    func testAStandardStartRecordIsThe11Bytes()throws {
        for text in [Legacy11Fixtures.record,Legacy11Fixtures.assistedRecord] {
            let game=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(text.utf8))
            XCTAssertNil(game.startFEN);XCTAssertEqual(game.start,NetworkStart.standard)
            XCTAssertEqual(String(decoding:try game.encoded(),as:UTF8.self),text)
        }
        let assisted=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(Legacy11Fixtures.assistedRecord.utf8))
        XCTAssertEqual(assisted.assistedMoves(by:.white),1);XCTAssertEqual(assisted.assistedMoves(by:.black),0,"1.1's parity, from the standard start")
        XCTAssertEqual(assisted.recordHeaders(date:"2026.10.18").map(\.name),["Event","Site","Date","Round","White","Black","Result","TimeControl","Assistance"])
    }
    /// 3. What 1.2 sends differs from 1.1 only in the version and the new optional fields, which the frozen decoder
    /// ignores: a 1.2 guest's `hello` and `resume`, field by field.
    func testA12MessageIs11ButForVersionAndCapabilities()throws {
        let random=TestRandom(seed:51),gameID=NetworkGameID.random(using:random.source)
        let receiver=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"0.9.0",rules:NetworkRulesFactory{FakeRules(script:FakeScript())},hashing:testHashing,random:random.source,accepting:NetworkAssistance(both:.hints))
        let opening=try NetworkCodec.encode(receiver.opening())
        var object=try XCTUnwrap(try JSONSerialization.jsonObject(with:opening) as? [String:Any])
        XCTAssertEqual(object.removeValue(forKey:"capabilities") as? [String],NetworkCapabilities.supported.tokens,"a guest states it, and since 1.3 its rulesets too")
        XCTAssertEqual(Set(object.keys),["appVersion","assistance","claimID","name","protocol","type"],"the rest is the 1.1 hello")
        XCTAssertNoThrow(try Legacy10Wire.decode(opening),"the frozen decoder reads it")
        // The frozen 1.1 decoder reads today's hello and resume, and the bytes 1.2 wrote, as the same message without capabilities.
        guard case .hello(let name,let appVersion,let claimID,let assistance,_)=receiver.opening() else{return XCTFail("a guest opens with hello")}
        XCTAssertEqual(try Legacy11Wire.decode(opening),.hello(name:name,appVersion:appVersion,claimID:claimID,assistance:assistance))
        let credential=NetworkSecret.random(using:random.source),resume=try NetworkCodec.encode(.resume(gameID:gameID,credential:credential,capabilities:.supported))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with:resume) as? [String:Any])?["capabilities"],"a resume states them too")
        XCTAssertEqual(try Legacy11Wire.decode(resume),.resume(gameID:gameID,credential:credential))
        for text in Legacy12Fixtures.messages.prefix(4) {
            var stated=try NetworkCodec.decode(Data(text.utf8))
            switch stated {case .hello(let n,let a,let c,let t,_):stated = .hello(name:n,appVersion:a,claimID:c,assistance:t);case .resume(let g,let c,_):stated = .resume(gameID:g,credential:c);default:XCTFail(text)}
            XCTAssertEqual(try Legacy11Wire.decode(Data(text.utf8)),stated,text)
        }
        let spectator=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"0.9.0",rules:NetworkRulesFactory{FakeRules(script:FakeScript())},hashing:testHashing)
        XCTAssertEqual(spectator.opening(),.hello(name:"Cy",appVersion:"0.9.0",claimID:nil,capabilities:.supported))
        let old=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"0.9.0",rules:NetworkRulesFactory{FakeRules(script:FakeScript())},hashing:testHashing,capabilities:.none)
        XCTAssertEqual(String(decoding:try NetworkCodec.encode(old.opening()),as:UTF8.self),#"{"appVersion":"0.9.0","name":"Cy","protocol":{"major":1,"minor":3},"type":"hello"}"#,"stating nothing is the 1.1 shape")
    }
}
private extension NetworkPublicGame {
    func with(gameID:NetworkGameID)->NetworkPublicGame {var copy=self;copy.gameID=gameID;return copy}
}
