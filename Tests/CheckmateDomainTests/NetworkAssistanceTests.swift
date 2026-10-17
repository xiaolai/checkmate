import XCTest
@testable import CheckmateDomain

/// Assistance plan A2–A4, A7 and A11 in the domain: the terms, admission under them, the guest's own check, protocol
/// 1.1 against 1.0, and the assisted flags.
final class NetworkAssistanceTests:XCTestCase {
    private let hints=NetworkAssistance(both:.hints)
    private func isSeated(_ message:NetworkMessage)->Bool {if case .seated=message {return true};return false}
    /// A5: every network hint searches at one fixed profile, the same on every Mac.
    func testTheHintProfileIsPinned(){XCTAssertEqual(NetworkAssistance.hintSkill,20);XCTAssertEqual(NetworkAssistance.hintNodes,400_000)}
    func testTheTermsHaveOrderedLevelsAndOneLetterEach(){
        XCTAssertEqual(NetworkAssistanceLevel.allCases,[.off,.insight,.hints,.guided])
        XCTAssertTrue(NetworkAssistanceLevel.off < .insight && NetworkAssistanceLevel.insight < .hints && NetworkAssistanceLevel.hints < .guided)
        XCTAssertEqual(NetworkAssistanceLevel.allCases.map(\.title),["Off","Board insight","Hints on request","Guided"])
        // The letters are wire values other Macs read: pinned literally, both ways.
        let letters:[(NetworkAssistanceLevel,Character)]=[(.off,"o"),(.insight,"i"),(.hints,"h"),(.guided,"g")]
        for (level,letter) in letters {XCTAssertEqual(level.letter,letter,"\(level)");XCTAssertEqual(NetworkAssistanceLevel(letter:letter),level,"\(letter)")}
        XCTAssertNil(NetworkAssistanceLevel(letter:"x"))
        let handicap=NetworkAssistance(white:.hints,black:.off)
        XCTAssertEqual(handicap.txt,"ho");XCTAssertEqual(NetworkAssistance(txt:"ho"),handicap);XCTAssertEqual(NetworkAssistance.off.txt,"oo")
        for bad in ["","h","hhh","hx","HO"] {XCTAssertNil(NetworkAssistance(txt:bad),bad)}
        XCTAssertTrue(handicap.handicap);XCTAssertFalse(hints.handicap);XCTAssertTrue(hints.symmetric)
        XCTAssertEqual(handicap.level(.white),.hints);XCTAssertEqual(handicap.level(.black),.off)
        XCTAssertEqual(handicap.recordValue,"White: Hints on request; Black: Off")
        XCTAssertEqual(String(decoding:try! JSONEncoder().encode(handicap),as:UTF8.self).contains(#""white":"hints""#),true)
    }
    // MARK: A3, the host's admission table
    /// The same terms are admitted, seated and acknowledged as before.
    func testAGuestWithTheSameTermsIsSeated()throws {
        let net=try TestNetwork(assistance:hints)
        let guest=net.client(.seat,accepting:hints);try net.connect(guest)
        XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(guest.receiver.installed?.assistance,hints);XCTAssertNil(guest.closedWith)
        XCTAssertEqual(guest.received.first,.seated(credential:try XCTUnwrap(guest.receiver.credential)))
    }
    /// Other terms, `off` included, are refused before the seat is reserved: no `seated`, and the seat stays free.
    func testAGuestWithOtherTermsIsRefusedBeforeTheSeatIsReserved()throws {
        for accepted in [NetworkAssistance.off,NetworkAssistance(both:.guided),NetworkAssistance(white:.hints,black:.off)] {
            let net=try TestNetwork(assistance:hints)
            let guest=net.client(.seat,accepting:accepted);try net.connect(guest)
            XCTAssertEqual(guest.closedWith,.assistanceChanged,"\(accepted)");XCTAssertFalse(guest.received.contains(where:isSeated))
            XCTAssertEqual(net.host.phase,.waiting);XCTAssertNil(net.host.guestName)
            // The seat is still there for a guest who accepted the real terms.
            let second=net.client(.seat,accepting:hints);try net.connect(second);XCTAssertEqual(net.host.phase,.running)
        }
    }
    /// A 1.0 guest states no terms: refused as another version from a game with assistance, admitted to one without.
    func testAGuestStatingNoTermsIsAdmittedOnlyWithoutAssistance()throws {
        let random=TestRandom(seed:3)
        for (terms,expected) in [(hints,NetworkByeReason.protocolVersion),(NetworkAssistance.off,nil)] {
            let net=try TestNetwork(assistance:terms)
            let id=try net.open(.seat)
            try net.send(.hello(name:"Old",appVersion:"0.8.1",claimID:.random(using:random.source),assistance:nil),on:id)
            XCTAssertEqual(net.closes[id],expected)
            XCTAssertEqual(net.host.phase,expected==nil ? .reserved:.waiting)
            XCTAssertEqual(net.messages(id).contains(where:isSeated),expected==nil)
        }
    }
    /// A claim resent while reserved is checked too; a refusal there leaves the reservation as it was.
    func testAResentClaimWithOtherTermsLeavesTheReservation()throws {
        let net=try TestNetwork(assistance:hints),claimID=NetworkSecret.random(using:net.random.source)
        let first=try net.open(.seat)
        try net.send(.hello(name:"Ben",appVersion:"0.8.1",claimID:claimID,assistance:hints),on:first)
        XCTAssertEqual(net.host.phase,.reserved)
        let second=try net.open(.seat)
        try net.send(.hello(name:"Ben",appVersion:"0.8.1",claimID:claimID,assistance:.off),on:second)
        XCTAssertEqual(net.closes[second],.assistanceChanged);XCTAssertEqual(net.host.phase,.reserved);XCTAssertNil(net.closes[first])
        let third=try net.open(.seat)
        try net.send(.hello(name:"Ben",appVersion:"0.8.1",claimID:claimID,assistance:hints),on:third)
        XCTAssertTrue(net.messages(third).contains(where:isSeated),"the same claim under the same terms is answered again")
    }
    /// Spectators may state anything or nothing: they never get assistance, so terms do not admit or refuse them.
    func testSpectatorsAreAdmittedWhateverTheyState()throws {
        let net=try TestNetwork(assistance:NetworkAssistance(both:.guided))
        for stated in [nil,NetworkAssistance.off,hints] {
            let id=try net.open(.watch)
            try net.send(.hello(name:"Cy",appVersion:"0.8.1",claimID:nil,assistance:stated),on:id)
            XCTAssertNil(net.closes[id]);XCTAssertEqual(net.messages(id).first,.watching)
        }
        let watcher=net.client(.watch,name:"Dee");try net.connect(watcher)
        XCTAssertEqual(watcher.receiver.installed?.assistance,NetworkAssistance(both:.guided),"spectators see the terms")
    }
    // MARK: A3, the guest's own check
    /// A host that seats a guest under other terms than it accepted (here: a hello claiming terms the receiver never
    /// accepted) is left before `seatedAck`: nothing installs, and the reservation lapses.
    func testTheGuestLeavesBeforeAcknowledgingOtherTerms()throws {
        let net=try TestNetwork(assistance:hints),claimID=NetworkSecret.random(using:net.random.source)
        let guest=net.client(.seat,claimID:claimID,accepting:.off)
        guest.connection=try net.open(.seat)
        try net.toHost(guest,.hello(name:"Ben",appVersion:"0.8.0",claimID:claimID,assistance:hints));try net.settle()
        XCTAssertEqual(guest.closedWith,.assistanceChanged);XCTAssertNil(guest.receiver.installed)
        XCTAssertEqual(net.host.phase,.reserved,"never acknowledged")
        try net.advance(31);XCTAssertEqual(net.host.phase,.waiting,"the reservation lapsed (D4)")
    }
    /// On `resumed`, and on any later snapshot, the terms are checked again.
    func testAResumedSnapshotUnderOtherTermsIsRefused()throws {
        let random=TestRandom(seed:5),script=FakeScript(),factory=NetworkRulesFactory{FakeRules(script:script)}
        let gameID=NetworkGameID.random(using:random.source),credential=NetworkSecret.random(using:random.source)
        let receiver=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"0.8.0",rules:factory,hashing:testHashing,random:random.source,accepting:hints)
        func game(_ terms:NetworkAssistance)->NetworkPublicGame {NetworkPublicGame(gameID:gameID,revision:0,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"[Fake]\n",clocks:nil,openOffer:nil,outcome:nil,assistance:terms)}
        func deliver(_ messages:[NetworkMessage])throws -> NetworkReceiverOutput {
            var last=NetworkReceiverOutput()
            for message in messages {last=try receiver.receive(message:message,at:.origin);if last.close != nil {break}}
            return last
        }
        func snapshot(_ terms:NetworkAssistance)throws -> [NetworkMessage] {try NetworkSnapshot.capture(game(terms),fen:"start w - - 0 1",hashing:testHashing,random:random.source).messages}
        let first=try deliver([.seated(credential:credential)]+snapshot(hints))
        XCTAssertNil(first.close);XCTAssertEqual(first.send,[.seatedAck])
        receiver.connectionLost()
        let resumed=try deliver([.resumed]+snapshot(.off))
        XCTAssertEqual(resumed.close,.assistanceChanged);XCTAssertEqual(receiver.installed?.assistance,hints,"the other terms were never installed")
        let spectator=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"0.8.0",rules:factory,hashing:testHashing,random:random.source)
        var output=try spectator.receive(message:.watching,at:.origin)
        for message in try snapshot(NetworkAssistance(both:.guided)) {output=try spectator.receive(message:message,at:.origin)}
        XCTAssertNil(output.close,"a spectator accepts nothing and checks nothing");XCTAssertEqual(spectator.installed?.assistance,NetworkAssistance(both:.guided))
    }
    // MARK: A4, protocol 1.1 against 1.0
    /// Every 1.0 message decodes under 1.1, and re-encodes to the same bytes but for the minor version: a 1.1 message
    /// that says nothing about assistance has the 1.0 shape.
    func testEveryLegacyMessageDecodesAndKeepsItsShape()throws {
        XCTAssertEqual(Set(try LegacyFixtures.messages.map{try NetworkCodec.decode(Data($0.utf8)).type}).count,24,"every message type")
        for text in LegacyFixtures.messages {
            let message=try NetworkCodec.decode(Data(text.utf8))
            switch message {
            case .hello(_,_,_,let assistance):XCTAssertNil(assistance,"a 1.0 guest states no terms")
            case .move(_,_,_,_,let assisted):XCTAssertFalse(assisted)
            case .moved(let moved):XCTAssertFalse(moved.assisted)
            default:break
            }
            let reencoded=String(decoding:try NetworkCodec.encode(message),as:UTF8.self)
            XCTAssertEqual(reencoded,text.replacingOccurrences(of:#""minor":0"#,with:#""minor":1"#))
        }
    }
    /// The 1.0 record reads as a game without assistance, and a game without assistance writes the 1.0 bytes.
    func testTheLegacyRecordReadsAsUnassistedAndRoundTrips()throws {
        let game=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(LegacyFixtures.record.utf8))
        XCTAssertEqual(game.assistance,.off);XCTAssertEqual(game.assistedPlies,[])
        XCTAssertEqual(String(decoding:try game.encoded(),as:UTF8.self),LegacyFixtures.record)
    }
    /// What 1.1 adds still decodes under the frozen 1.0 rules: the new keys are ignored and every 1.0 field reads the
    /// same. The new bye reason is `unknown` to 1.0.
    func testA11MessageAndRecordDecodeUnderTheFrozen10Rules()throws {
        let random=TestRandom(seed:9),game=NetworkGameID.random(using:random.source),command=NetworkID.random(using:random.source),claim=NetworkSecret.random(using:random.source)
        let clocks=NetworkClocks(white:1000,black:2000,active:.white)
        let messages:[NetworkMessage]=[.hello(name:"Ben",appVersion:"0.9.0",claimID:claim,assistance:NetworkAssistance(white:.guided,black:.insight)),.move(gameID:game,commandID:command,revision:3,uci:"e2e4",assisted:true),
                                       .moved(NetworkMoved(revision:4,uci:"e2e4",san:"e4",hash:"ab",clocks:clocks,receiptFor:command,assisted:true)),.bye(.assistanceChanged)]
        for message in messages {
            let data=try NetworkCodec.encode(message)
            let legacy=try Legacy10Wire.decode(data)
            XCTAssertEqual(legacy.protocol.major,1);XCTAssertEqual(legacy.type,message.type)
            switch message {
            case .hello:XCTAssertEqual(legacy.name,"Ben");XCTAssertEqual(legacy.claimID,claim);XCTAssertTrue(String(decoding:data,as:UTF8.self).contains(#""assistance":{"black":"insight","white":"guided"}"#))
            case .move:XCTAssertEqual(legacy.uci,"e2e4");XCTAssertEqual(legacy.revision,3);XCTAssertEqual(legacy.commandID,command)
            case .moved:XCTAssertEqual(legacy.san,"e4");XCTAssertEqual(legacy.receiptFor,command);XCTAssertEqual(legacy.clocks,clocks)
            case .bye:XCTAssertFalse(Legacy10Wire.byeReasons.contains(legacy.reason!),"1.0 reads it as unknown")
            default:break
            }
        }
        // The frozen rules are 1.0's whole decoder, not only its field types: every 1.0 fixture passes them, and a
        // message missing a field 1.0 required does not.
        for text in LegacyFixtures.messages {XCTAssertNoThrow(try Legacy10Wire.decode(Data(text.utf8)),text)}
        for text in [#"{"commandID":"\#(command.text)","protocol":{"major":1,"minor":1},"revision":3,"type":"move","uci":"e2e4","assisted":true}"#,
                     #"{"protocol":{"major":1,"minor":1},"revision":4,"san":"e4","type":"moved","uci":"e2e4","assisted":true}"#,
                     #"{"protocol":{"major":1,"minor":1},"type":"teleport"}"#] {XCTAssertThrowsError(try Legacy10Wire.decode(Data(text.utf8)),text)}
        // Its value checks too: each of these breaks one rule the 1.0 decoder enforced, and 1.1 refuses it as well.
        let gameText=game.text,commandText=command.text
        for text in [#"{"appVersion":"0.8.1","name":"","protocol":{"major":1,"minor":0},"type":"hello"}"#,
                     #"{"commandID":"\#(commandText)","gameID":"\#(gameText)","protocol":{"major":1,"minor":0},"revision":-1,"type":"move","uci":"e2e4"}"#,
                     #"{"commandID":"\#(commandText)","gameID":"\#(gameText)","protocol":{"major":1,"minor":0},"revision":3,"type":"move","uci":"e2e9"}"#,
                     #"{"hash":"","protocol":{"major":1,"minor":0},"revision":6,"san":"Nc6","type":"moved","uci":"b8c6"}"#,
                     #"{"clocks":{"active":"b","black":-1,"white":180000},"protocol":{"major":1,"minor":0},"type":"clock"}"#,
                     #"{"hash":"abc","parts":2,"protocol":{"major":1,"minor":0},"revision":2,"snapshotID":"\#(commandText)","totalBytes":10,"type":"snapshotBegin"}"#,
                     #"{"data":"","index":0,"protocol":{"major":1,"minor":0},"snapshotID":"\#(commandText)","type":"snapshotPart"}"#] {
            XCTAssertThrowsError(try Legacy10Wire.decode(Data(text.utf8)),"1.0 refused \(text)");XCTAssertThrowsError(try NetworkCodec.decode(Data(text.utf8)),"1.1 refuses \(text)")
        }
        XCTAssertThrowsError(try Legacy10Wire.decode(Data(repeating:0x20,count:Legacy10Wire.maximumMessageBytes+1)),"over 1.0's 16 KiB")
        var record=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(LegacyFixtures.record.utf8))
        record.assistance=NetworkAssistance(white:.hints,black:.off);record.assistedPlies=[1]
        let encoded=try record.encoded()
        XCTAssertNotEqual(String(decoding:encoded,as:UTF8.self),LegacyFixtures.record)
        XCTAssertEqual(try JSONDecoder().decode(Legacy10PublicGame.self,from:encoded),try JSONDecoder().decode(Legacy10PublicGame.self,from:Data(LegacyFixtures.record.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(NetworkPublicGame.self,from:encoded),record)
    }
    /// Assisted plies must be increasing and within the record; anything else is not a public game.
    func testAssistedPliesOutsideTheRecordAreRefused()throws {
        var record=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(LegacyFixtures.record.utf8))
        for plies in [[0],[3],[2,1],[1,1],[-1]] {
            record.assistedPlies=plies
            XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try record.encoded()),"\(plies)")
        }
        record.revision=0;record.assistedPlies=[]
        XCTAssertNoThrow(try JSONDecoder().decode(NetworkPublicGame.self,from:try record.encoded()),"revision 0 has no plies to check")
        // A finished game: `ended` advanced the revision without a move, so two moves end at revision 3.
        record.revision=3;record.outcome=NetworkOutcome(result:.whiteWins,termination:.resignation);record.assistedPlies=[2]
        XCTAssertNoThrow(try JSONDecoder().decode(NetworkPublicGame.self,from:try record.encoded()),"the last move of a finished game")
        record.assistedPlies=[3]
        XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try record.encoded()),"the end itself is no move")
    }
    // MARK: A7, the assisted flags
    func testAssistedMovesReachTheGuestSpectatorsAndTheRecord()throws {
        let net=try TestNetwork(assistance:NetworkAssistance(white:.hints,black:.guided))
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4",assisted:true);try net.play(guest,"e7e5",assisted:true)
        try net.hostPlays("g1f3");try net.play(guest,"b8c6",assisted:true)
        XCTAssertEqual(net.host.assistedPlies,[1,2,4])
        let host=try net.host.publicGame(at:net.now)
        XCTAssertEqual(host.assistedPlies,[1,2,4]);XCTAssertEqual(host.assistedMoves(by:.white),1);XCTAssertEqual(host.assistedMoves(by:.black),2)
        for client in [guest]+watchers {XCTAssertEqual(try client.receiver.publicGame(at:net.now)?.assistedPlies,[1,2,4])}
        let spectatorMoves=watchers[0].received.compactMap{message->NetworkMoved? in if case .moved(let moved)=message {return moved};return nil}
        XCTAssertEqual(spectatorMoves.map(\.assisted),[true,true,false,true]);XCTAssertTrue(spectatorMoves.allSatisfy{$0.receiptFor==nil},"spectators never see a receipt")
        // A late spectator gets the plies in its snapshot.
        let late=net.client(.watch,name:"Late");try net.connect(late)
        XCTAssertEqual(late.receiver.installed?.assistedPlies,[1,2,4])
        // A duplicate receipt counts nothing twice.
        try net.hostPlays("d2d4")
        let move=try XCTUnwrap(try guest.receiver.submitMove(uci:"d7d6",assisted:true))
        try net.toHost(guest,move);try net.settle()
        try net.toHost(guest,move);try net.settle()
        XCTAssertEqual(try guest.receiver.publicGame(at:net.now)?.assistedPlies,[1,2,4,6]);XCTAssertEqual(net.host.assistedPlies,[1,2,4,6])
    }
    // MARK: A11
    func testTheRecordHeadersNameTheTermsOnlyWhenThereAreAny()throws {
        var record=try JSONDecoder().decode(NetworkPublicGame.self,from:Data(LegacyFixtures.record.utf8))
        XCTAssertFalse(record.recordHeaders(date:"2026.10.17").contains{$0.name=="Assistance"})
        record.assistance=NetworkAssistance(white:.hints,black:.off);record.outcome=NetworkOutcome(result:.whiteWins,termination:.checkmate);record.clocks=nil;record.timeControl = .untimed
        let headers=record.recordHeaders(date:"2026.10.17")
        XCTAssertEqual(headers.map(\.name),["Event","Site","Date","Round","White","Black","Result","TimeControl","Assistance","Termination"])
        XCTAssertEqual(headers.first{$0.name=="Assistance"}?.value,"White: Hints on request; Black: Off")
    }
}
