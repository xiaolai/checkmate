import XCTest
@testable import CheckmateDomain

/// D5's chunked snapshots, the per-peer outbox (D7 outbound), the receiver's revision rules (R5-1) and privacy.
final class NetworkSnapshotTests:XCTestCase {
    private let random=TestRandom(seed:5)
    private var id:NetworkID {NetworkID.random(using:random.source)}
    private func snapshotMessages(_ list:[NetworkMessage])->[NetworkMessage] {list.filter{switch $0{case .snapshotBegin,.snapshotPart,.snapshotEnd:return true;default:return false}}}
    func testTheOutboxPacesASnapshotAndHoldsEverythingBehindIt()throws {
        let payload=Data((0..<(NetworkLimits.maximumSnapshotPartBytes*2+5)).map{UInt8(truncatingIfNeeded:$0)})
        let snapshot=NetworkSnapshot(snapshotID:id,revision:3,hash:"h3",payload:payload)
        XCTAssertEqual(snapshot.partCount,3)
        let before=try NetworkCodec.encode(.ping(nonce:id)),after=try NetworkCodec.encode(.clock(NetworkClocks(white:1,black:2,active:nil))),later=try NetworkCodec.encode(.resumed)
        var outbox=NetworkOutbox()
        XCTAssertEqual(outbox.enqueue(before),.queued);XCTAssertEqual(outbox.requestSnapshot(snapshot),.queued)
        XCTAssertEqual(outbox.enqueue(after),.held,"behind the snapshot")
        XCTAssertEqual(outbox.requestSnapshot(NetworkSnapshot(snapshotID:id,revision:4,hash:"h4",payload:Data([1]))),.coalesced,"one snapshot at a time")
        XCTAssertEqual(outbox.bytes,before.count+after.count)
        var sent:[Data]=[]
        XCTAssertEqual(try outbox.next(),before);XCTAssertNil(try outbox.next(),"one message in flight at a time")
        XCTAssertEqual(outbox.bytes,before.count+after.count,"handed but not completed still counts");outbox.completed();sent.append(before)
        while let next=try outbox.next() {
            sent.append(next)
            if sent.count==3 {XCTAssertEqual(outbox.enqueue(later),.held)}
            XCTAssertEqual(outbox.bytes,next.count+(sent.count<7 ? after.count:0)+(sent.count>=3 && sent.count<8 ? later.count:0),"the part in flight plus everything held")
            outbox.completed()
        }
        XCTAssertTrue(outbox.isIdle);XCTAssertEqual(outbox.bytes,0)
        let messages=decoded(sent)
        XCTAssertEqual(messages.count,8)
        guard case .snapshotBegin(_,3,"h3",payload.count,3)=messages[1],case .snapshotEnd=messages[5] else{return XCTFail("\(messages)")}
        let parts=messages[2...4].compactMap{message->Data? in if case .snapshotPart(_,_,let data)=message {return data};return nil}
        XCTAssertEqual(parts.reduce(Data(),+),payload)
        XCTAssertEqual(messages[0],try NetworkCodec.decode(before));XCTAssertEqual(messages[6],try NetworkCodec.decode(after));XCTAssertEqual(messages[7],.resumed,"held messages leave in order, right after snapshotEnd")
    }
    func testTheHeldListCountsTowardTheCap()throws {
        var outbox=NetworkOutbox(capacity:300)
        let message=try NetworkCodec.encode(.clock(NetworkClocks(white:1,black:2,active:.white)))
        _ = outbox.requestSnapshot(NetworkSnapshot(snapshotID:id,revision:0,hash:"h",payload:Data([1])))
        var held=0
        while outbox.enqueue(message) == .held {held+=1}
        XCTAssertEqual(held,300/message.count);XCTAssertEqual(outbox.enqueue(message),.overflow);XCTAssertLessThanOrEqual(outbox.bytes,300)
    }
    func testASlowSpectatorIsClosedWhileTheGuestKeepsPlaying()throws {
        var limits=NetworkHostLimits();limits.peerQueueBytes=2048
        let net=try TestNetwork(hostSide:.black,limits:limits)
        let (guest,watchers)=try net.startGame(spectators:2)
        let slow=try XCTUnwrap(watchers[0].connection);net.stalled=[slow]
        for _ in 0..<10 {try net.play(guest,"g1f3");try net.hostPlays("g8f6");try net.advance(0.1);try net.play(guest,"f3g1");try net.hostPlays("f6g8");try net.advance(0.1)}
        XCTAssertEqual(net.closes[slow],.slow);XCTAssertEqual(watchers[0].closedWith,.slow)
        XCTAssertEqual(guest.receiver.revision,40);XCTAssertEqual(watchers[1].receiver.revision,40);XCTAssertNil(watchers[1].closedWith);XCTAssertEqual(net.host.spectators.count,1)
    }
    func testAllSpectatorQueuesShareOneCap()throws {
        var limits=NetworkHostLimits();limits.peerQueueBytes=4096;limits.spectatorQueuesBytes=3000
        let net=try TestNetwork(hostSide:.black,limits:limits)
        let (guest,watchers)=try net.startGame(spectators:2)
        net.stalled=Set(watchers.compactMap(\.connection))
        for _ in 0..<5 {
            try net.play(guest,"g1f3");try net.hostPlays("g8f6");try net.advance(0.1);try net.play(guest,"f3g1");try net.hostPlays("f6g8");try net.advance(0.1)
            XCTAssertLessThanOrEqual(net.host.spectatorQueuedBytes,3000)
        }
        XCTAssertEqual(watchers.filter{$0.closedWith == .slow}.count,1,"closed by the shared cap, its own queue far below 4 KiB")
        XCTAssertEqual(guest.receiver.revision,20)
    }
    /// D7: a record held for snapshots still being sent is counted, once per capture; peers asking while the public
    /// game is unchanged share that capture, and the count returns to zero once every snapshot is sent.
    func testPendingSnapshotsAreCountedOnceAndShared()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4");try net.hostPlays("e7e5")
        XCTAssertEqual(net.host.snapshotBytes,0,"nothing pending")
        net.autoComplete=false
        let first=net.client(.watch,name:"Cy"),second=net.client(.watch,name:"Di")
        try net.connect(first);try net.connect(second)
        let payload=try net.host.publicGame(at:net.now).encoded().count
        XCTAssertEqual(net.host.snapshotBytes,payload,"two peers, one capture")
        net.autoComplete=true
        for _ in 0..<20 {for id in [first,second].compactMap(\.connection) {try net.completeSend(id)}}
        try net.settle()
        XCTAssertEqual(net.host.snapshotBytes,0);XCTAssertEqual(first.receiver.revision,net.host.revision);XCTAssertEqual(second.receiver.revision,net.host.revision)
    }
    /// D7: distinct records held for spectators are bounded together. A spectator whose new capture would pass the
    /// budget is closed as slow; one that shares a capture already held, and the guest, never are.
    func testDistinctPendingSnapshotsShareOneBudget()throws {
        let probe=try TestNetwork(hostSide:.black)
        let (probeGuest,_)=try probe.startGame()
        try probe.play(probeGuest,"e2e4")
        var limits=NetworkHostLimits();limits.retainedCaptureBytes=try probe.host.publicGame(at:probe.now).encoded().count+8
        let net=try TestNetwork(hostSide:.black,limits:limits)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4")
        net.autoComplete=false
        let first=net.client(.watch,name:"Cy"),sharing=net.client(.watch,name:"Di");try net.connect(first);try net.connect(sharing)
        XCTAssertNil(first.closedWith);XCTAssertNil(sharing.closedWith,"a shared capture costs nothing more")
        try net.hostPlays("e7e5")
        let late=net.client(.watch,name:"Ed");try net.connect(late)
        XCTAssertEqual(late.closedWith,.slow,"a second record would pass the budget")
        XCTAssertLessThanOrEqual(net.host.snapshotBytes,limits.retainedCaptureBytes)
        XCTAssertEqual(net.host.spectators.count,2);XCTAssertEqual(net.host.phase,.running)
    }
    /// A joiner while the guest is away is shown stopped clocks, even when a running-clock capture is still cached.
    func testASnapshotCapturedWhileClocksRunIsNotReusedOnceTheyStop()throws {
        let net=try TestNetwork(hostSide:.black,timeControl:.threePlusTwo)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4");try net.hostPlays("e7e5");try net.play(guest,"g1f3")
        XCTAssertEqual(try net.host.publicGame(at:net.now).clocks?.active,.black,"the clocks run")
        net.autoComplete=false
        let running=net.client(.watch,name:"Cy");try net.connect(running)
        try net.cut(guest);XCTAssertEqual(net.host.phase,.disconnected)
        let stopped=net.client(.watch,name:"Di");try net.connect(stopped)
        net.autoComplete=true
        for _ in 0..<20 {for id in [running,stopped].compactMap(\.connection) {try net.completeSend(id)}}
        try net.settle()
        XCTAssertNil(try XCTUnwrap(stopped.receiver.publicGame(at:net.now)).clocks?.active,"the stopped reading, not the cached running one")
        XCTAssertNil(try XCTUnwrap(running.receiver.publicGame(at:net.now)).clocks?.active,"the pause notice reached the earlier joiner too")
    }
    func testAGuestOverItsQueueIsClosedAndResumes()throws {
        var limits=NetworkHostLimits();limits.peerQueueBytes=1024
        let net=try TestNetwork(limits:limits)
        let (guest,_)=try net.startGame()
        let stuck=try XCTUnwrap(guest.connection);net.stalled=[stuck]
        for _ in 0..<12 {try net.toHost(guest,.move(gameID:net.gameID,commandID:id,revision:99,uci:"e7e5"))}
        XCTAssertEqual(net.closes[stuck],.slow);XCTAssertEqual(net.host.phase,.disconnected,"the guest simply resumes")
        net.stalled=[];try net.settle();XCTAssertEqual(guest.closedWith,.slow)
        try net.connect(guest);XCTAssertEqual(net.host.phase,.running);XCTAssertEqual(guest.receiver.revision,net.host.revision)
    }
    func testDuplicatesNeverMoveTheBoardAndGapsAskForASnapshot()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4");try net.hostPlays("e7e5")
        let late=net.client(.watch,name:"Late");try net.connect(late)
        let snapshot=snapshotMessages(late.received)
        try net.play(guest,"g1f3");try net.hostPlays("b8c6");try net.play(guest,"f1c4")
        let moves=late.received.compactMap{message->NetworkMoved? in if case .moved(let moved)=message {return moved};return nil}
        XCTAssertEqual(moves.map(\.revision),[3,4,5])
        func fresh()->NetworkReceiver {NetworkReceiver(gameID:net.gameID,role:.spectator,name:"Fresh",appVersion:"1",rules:net.factory,hashing:testHashing,random:net.random.source)}
        let receiver=fresh()
        var outputs:[NetworkReceiverOutput]=[]
        for message in [NetworkMessage.watching]+snapshot {outputs.append(try receiver.receive(message:message,at:net.now))}
        XCTAssertEqual(receiver.revision,2)
        for moved in [moves[0],moves[0],moves[1]] {outputs.append(try receiver.receive(message:.moved(moved),at:net.now))}
        XCTAssertEqual(outputs.flatMap(\.events).filter{if case .applied=$0 {return true};return false}.count,2,"exactly two applied")
        XCTAssertEqual(receiver.revision,4);XCTAssertEqual(testHashing.positionHash(fen:try XCTUnwrap(receiver.fen),revision:4),moves[1].hash)
        XCTAssertTrue(outputs.allSatisfy{$0.close==nil && $0.send.isEmpty},"no disconnect and no resync")
        let gapped=fresh()
        for message in [NetworkMessage.watching]+snapshot {_ = try gapped.receive(message:message,at:net.now)}
        _ = try gapped.receive(message:.moved(moves[0]),at:net.now)
        XCTAssertEqual(try gapped.receive(message:.moved(moves[2]),at:net.now).send,[.resync]);XCTAssertEqual(gapped.revision,3,"the gapped move is discarded")
        XCTAssertEqual(try gapped.receive(message:.moved(moves[2]),at:net.now).send,[],"one resync until a snapshot arrives")
    }
    /// D5: a move whose hash disagrees is never shown. The guest asks for a snapshot, keeps its last good position, plays
    /// nothing until the snapshot installs, and then plays on from the host's position.
    func testAMoveWithAWrongHashIsNeverShownAndTheGuestWaitsForTheSnapshot()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4")
        let fen=guest.receiver.fen
        let forged=NetworkMoved(revision:2,uci:"e7e5",san:"e5",hash:"not-the-hash",clocks:nil,receiptFor:nil)
        let output=try guest.receiver.receive(message:.moved(forged),at:net.now)
        XCTAssertEqual(output.send,[.resync]);XCTAssertFalse(output.events.contains{if case .applied=$0 {return true};return false},"nothing applied")
        XCTAssertEqual(guest.receiver.revision,1);XCTAssertEqual(guest.receiver.fen,fen,"the last good position stays")
        XCTAssertEqual(try guest.receiver.publicGame(at:net.now)?.pgn,"[Fake]\ne2e4","nor does the record keep the forged move")
        XCTAssertNil(try guest.receiver.submitMove(uci:"g1f3"),"no command against a position known to be wrong")
        try net.hostPlays("e7e5");XCTAssertEqual(guest.receiver.revision,1,"moves wait for the snapshot")
        try net.toHost(guest,.resync);try net.settle()
        XCTAssertEqual(guest.receiver.revision,2);XCTAssertEqual(guest.receiver.fen,net.host.fen)
        try net.play(guest,"g1f3");XCTAssertEqual(net.host.revision,3)
    }
    func testADuplicateOnlyClearsAPendingMoveWithItsReceipt()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        let move=try XCTUnwrap(try guest.receiver.submitMove(uci:"e2e4"))
        guard case .move(_,let commandID,_,_,_)=move else{return XCTFail()}
        let unrelated=NetworkMoved(revision:0,uci:"a2a3",san:"a3",hash:"0",clocks:nil,receiptFor:id)
        XCTAssertEqual(try guest.receiver.receive(message:.moved(unrelated),at:net.now),NetworkReceiverOutput());XCTAssertNotNil(guest.receiver.pendingMove)
        _ = try guest.receiver.receive(message:.moved(NetworkMoved(revision:0,uci:"a2a3",san:"a3",hash:"0",clocks:nil,receiptFor:commandID)),at:net.now)
        XCTAssertNil(guest.receiver.pendingMove,"its receipt clears the pending move");XCTAssertEqual(guest.receiver.revision,0);XCTAssertEqual(guest.receiver.fen,"start w - - 0 1","and the board never moves")
    }
    func testThePendingMoveBlocksPressesAndClearsOnEveryAnswer()throws {
        let net=try TestNetwork(hostSide:.black)
        let (guest,_)=try net.startGame()
        guest.lose=["move"]
        try net.toHost(guest,try XCTUnwrap(try guest.receiver.submitMove(uci:"e2e4")))
        XCTAssertEqual(guest.receiver.pendingMove?.from,"e2");XCTAssertEqual(guest.receiver.pendingMove?.to,"e4")
        XCTAssertNil(try guest.receiver.submitMove(uci:"d2d4"),"further presses are ignored")
        XCTAssertEqual(guest.receiver.revision,0);XCTAssertEqual(guest.receiver.fen,"start w - - 0 1","no optimistic board")
        try net.toHost(guest,.resync);try net.settle()
        XCTAssertNil(guest.receiver.pendingMove,"a snapshot clears it, and shows the move was not applied");XCTAssertEqual(guest.receiver.revision,0)
        XCTAssertNotNil(try guest.receiver.submitMove(uci:"e2e4"));try net.cut(guest);XCTAssertNil(guest.receiver.pendingMove,"so does a reconnect")
        try net.connect(guest);guest.lose=[]
        net.script.illegal=["e2e5"];try net.play(guest,"e2e5")
        XCTAssertNil(guest.receiver.pendingMove);XCTAssertTrue(guest.events.contains{if case .rejected(_,.illegal)=$0 {return true};return false})
        try net.play(guest,"e2e4");XCTAssertNil(guest.receiver.pendingMove,"moved with its receipt clears it");XCTAssertEqual(guest.receiver.revision,1)
        XCTAssertNil(try guest.receiver.submitMove(uci:"d2d4"),"not the guest's turn")
        XCTAssertNil(net.client(.watch).receiver.resign(),"a spectator has no commands")
    }
    func testAForgedOrBrokenSnapshotClosesWithBadSnapshotAndKeepsTheBoard()throws {
        let net=try TestNetwork()
        let (guest,watchers)=try net.startGame(spectators:1)
        try net.hostPlays("e2e4");try net.play(guest,"e7e5")
        let watcher=watchers[0].receiver,fen=watcher.fen,game=try net.host.publicGame(at:net.now),hash=net.host.positionHash
        func messages(_ game:NetworkPublicGame,hash:String)throws -> [NetworkMessage] {NetworkSnapshot(snapshotID:id,revision:game.revision,hash:hash,payload:try game.encoded()).messages}
        func close(_ list:[NetworkMessage])throws -> NetworkByeReason? {
            watcher.connectionLost()
            for message in [NetworkMessage.watching]+list {if let reason=try watcher.receive(message:message,at:net.now).close {return reason}}
            return nil
        }
        var forged=game;forged.pgn=game.pgn.replacingOccurrences(of:"e7e5",with:"e7e6")
        XCTAssertEqual(try close(try messages(forged,hash:hash)),.badSnapshot,"a record that does not reach its hash")
        var broken=try messages(game,hash:hash)
        if case .snapshotPart(let snapshotID,let index,var data)=broken[1],let range=data.range(of:Data("e7e5".utf8)) {data[range.lowerBound+3]=UInt8(ascii:"6");broken[1] = .snapshotPart(snapshotID:snapshotID,index:index,data:data)}else{XCTFail()}
        XCTAssertEqual(try close(broken),.badSnapshot,"a forged part")
        var long=game;long.pgn="[Fake]\n"+Array(repeating:"g1f3",count:4000).joined(separator:" ")
        // The long record's own hash, so each corruption below is the only thing wrong with it.
        let longRules=FakeRules(script:net.script);try longRules.networkLoad(pgn:long.pgn)
        let longHash=testHashing.positionHash(fen:try longRules.networkFEN(),revision:long.revision)
        let parts=try messages(long,hash:longHash);XCTAssertEqual(parts.count,5)
        var swapped=parts;swapped.swapAt(1,2)
        var missing=parts;missing.remove(at:2)
        var interrupted=parts;interrupted.insert(.ping(nonce:id),at:2)
        let foreign=NetworkSnapshot(snapshotID:NetworkID.random(using:net.random.source),revision:long.revision,hash:longHash,payload:try long.encoded()).messages
        var mixed=parts;mixed[2]=foreign[2]
        for list in [swapped,missing,interrupted,mixed] {XCTAssertEqual(try close(list),.badSnapshot)}
        XCTAssertEqual(watcher.fen,fen);XCTAssertEqual(watcher.revision,2,"every failure left the board as it was")
        XCTAssertNil(try close(parts),"the long record itself installs: only the corruptions failed")
        XCTAssertNil(try close(try messages(game,hash:hash)));XCTAssertEqual(watcher.revision,2)
        // One byte over the limit, with the part count those bytes need, so only the byte limit refuses it; and a part
        // count that does not match the bytes, on its own.
        let over=NetworkLimits.maximumSnapshotBytes+1,needed=(over+NetworkLimits.maximumSnapshotPartBytes-1)/NetworkLimits.maximumSnapshotPartBytes
        XCTAssertThrowsError(try NetworkSnapshotAssembler(snapshotID:id,revision:0,hash:"h",totalBytes:over,parts:needed),"over the byte limit")
        XCTAssertThrowsError(try NetworkSnapshotAssembler(snapshotID:id,revision:0,hash:"h",totalBytes:1000,parts:2),"a part count the bytes do not need")
        XCTAssertNoThrow(try NetworkSnapshotAssembler(snapshotID:id,revision:0,hash:"h",totalBytes:NetworkLimits.maximumSnapshotBytes,parts:NetworkLimits.maximumSnapshotParts))
    }
    func testLongRecordsTravelInPacedPartsAndRoundTrip()throws {
        for plies in [2_000,180_000] {
            let script=FakeScript(),moves=(0..<plies).map{$0%2==0 ? "g1f3":"g8f6"},random=TestRandom(seed:UInt64(plies))
            let hostRules=NetworkRulesFactory{let rules=FakeRules(script:script);try rules.networkLoad(pgn:"[Fake]\n"+moves.joined(separator:" "));return rules}
            let gameID=NetworkGameID.random(using:random.source)
            let host=try NetworkHost(gameID:gameID,runEpoch:NetworkID.random(using:random.source),settings:NetworkHostSettings(hostName:"Ana",hostSide:.white),rules:hostRules,hashing:testHashing,random:random.source,at:.origin)
            let receiver=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"1",rules:NetworkRulesFactory{FakeRules(script:script)},hashing:testHashing,random:random.source)
            let accepted=try host.accept(.watch,at:.origin)
            var effects=accepted.effects+(try host.receive(try NetworkCodec.encode(receiver.opening()),from:accepted.connection,at:.origin))
            var parts=0,installed=false
            while let index=effects.firstIndex(where:{if case .transmit=$0 {return true};return false}) {
                guard case .transmit(_,let data)=effects.remove(at:index) else{break}
                XCTAssertLessThanOrEqual(data.count,NetworkLimits.maximumMessageBytes)
                if case .snapshotPart=try NetworkCodec.decode(data) {parts+=1}
                let output=try receiver.receive(data,at:.origin)
                XCTAssertNil(output.close)
                installed=installed || output.events.contains(.installed(revision:0))
                effects+=try host.sendCompleted(accepted.connection,at:.origin)
            }
            XCTAssertTrue(installed);XCTAssertEqual(receiver.fen,host.fen)
            if plies>2_000 {XCTAssertGreaterThan(parts,90,"about a hundred parts, each sent when the last completed")}else{XCTAssertGreaterThanOrEqual(parts,1)}
        }
        // A record over 1 MiB cannot be captured: the host fails loudly rather than send it.
        let script=FakeScript(),huge=Array(repeating:"g1f3",count:220_000).joined(separator:" ")
        let host=try NetworkHost(gameID:NetworkGameID.random(using:random.source),runEpoch:id,settings:NetworkHostSettings(hostName:"Ana",hostSide:.white),rules:NetworkRulesFactory{let rules=FakeRules(script:script);try rules.networkLoad(pgn:"[Fake]\n"+huge);return rules},hashing:testHashing,random:random.source,at:.origin)
        let watcher=try host.accept(.watch,at:.origin).connection
        XCTAssertThrowsError(try host.receive(message:.hello(name:"Cy",appVersion:"1",claimID:nil),from:watcher,at:.origin))
    }
    func testNoSecretReachesASpectatorOrASnapshot()throws {
        let epoch=id
        let net=try TestNetwork(timeControl:.threePlusTwo,epoch:epoch)
        let claim=NetworkSecret.random(using:net.random.source)
        let guest=net.client(.seat,claimID:claim),watcher=net.client(.watch,name:"Cy")
        try net.connect(watcher);try net.connect(guest)
        let credential=try XCTUnwrap(guest.receiver.credential)
        let watcherConnections=[try XCTUnwrap(watcher.connection)]
        try net.hostPlays("e2e4");try net.play(guest,"e7e5")
        try net.cut(guest);try net.connect(guest)
        try net.toHost(guest,.move(gameID:net.gameID,commandID:id,revision:0,uci:"d7d5"));try net.settle()
        try net.perform(.resign);try net.settle()
        try net.toHost(watcher,.resync);try net.toHost(guest,.resync);try net.settle()
        let secrets=[claim.text,credential.text,epoch.text]
        func clean(_ text:String,_ what:String){for secret in secrets {XCTAssertFalse(text.contains(secret),what)}}
        var snapshots=0
        for client in [watcher,guest] {
            var payload=Data()
            for message in client.received {
                switch message {
                case .snapshotBegin:payload=Data()
                case .snapshotPart(_,_,let data):payload.append(data)
                case .snapshotEnd:snapshots+=1;clean(String(decoding:payload,as:UTF8.self),"a snapshot")
                default:break
                }
            }
        }
        XCTAssertEqual(snapshots,7,"watching, the guest's name and terminal for the spectator; seated, resumed, stale and terminal for the guest")
        for connection in watcherConnections {for frame in net.sent[connection] ?? [] {clean(String(decoding:frame,as:UTF8.self),"a spectator message")}}
        XCTAssertGreaterThanOrEqual(net.sent[watcherConnections[0]]?.count ?? 0,10,"watching, two snapshots, two moves, ended")
        let carrying=net.sent.values.joined().filter{String(decoding:$0,as:UTF8.self).contains(credential.text)}
        XCTAssertEqual(carrying.count,1,"the credential travels in seated only");XCTAssertEqual(try carrying.first.map(NetworkCodec.decode),.seated(credential:credential))
        XCTAssertFalse(net.sent.values.joined().contains{String(decoding:$0,as:UTF8.self).contains(claim.text)},"the host never sends the claim back")
        var dumped="";dump(net.host,to:&dumped);dump(guest.receiver,to:&dumped)
        for text in [dumped,"\(net.host!)",String(reflecting:net.host!),"\(guest.receiver.opening())"] {XCTAssertFalse(text.contains(claim.text));XCTAssertFalse(text.contains(credential.text))}
        clean(String(decoding:try JSONEncoder().encode(try net.host.publicGame(at:net.now)),as:UTF8.self),"the crash-file record")
    }
    func testThePublicRecordIsFieldByFieldAndNamesItsReviewHeaders()throws {
        var game=NetworkPublicGame(gameID:NetworkGameID.random(using:random.source),revision:41,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.tenPlusFive,pgn:"",clocks:NetworkClocks(white:1,black:0,active:nil),openOffer:nil,outcome:NetworkOutcome(result:.blackWins,termination:.time))
        XCTAssertEqual(Mirror(reflecting:game).children.compactMap(\.label),["gameID","revision","hostSide","whiteName","blackName","timeControl","pgn","clocks","openOffer","outcome","assistance","assistedPlies"],"no field could hold a credential, a claim or app state; the last two are the assistance terms and the assisted plies (assistance plan A2, A7)")
        let headers=game.recordHeaders(date:"2026.10.16")
        XCTAssertEqual(headers.map(\.name),["Event","Site","Date","Round","White","Black","Result","TimeControl","Termination"])
        XCTAssertEqual(headers.map(\.value),["Checkmate network game","?","2026.10.16","?","Ana","Ben","0-1","600+5","Time forfeit"])
        XCTAssertEqual(try JSONDecoder().decode(NetworkPublicGame.self,from:try game.encoded()),game)
        game.outcome=nil;game.timeControl = .untimed;game.clocks=nil;game.blackName=nil
        let interrupted=game.recordHeaders(date:"2026.10.16")
        XCTAssertEqual(interrupted.first{$0.name=="Result"}?.value,"*");XCTAssertFalse(interrupted.contains{$0.name=="Termination"});XCTAssertEqual(interrupted.first{$0.name=="TimeControl"}?.value,"-");XCTAssertEqual(interrupted.first{$0.name=="Black"}?.value,"?")
        var invalid=game;invalid.whiteName=String(repeating:"x",count:65)
        XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try invalid.encoded()))
        invalid=game;invalid.clocks=NetworkClocks(white:1,black:1,active:nil)
        XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try invalid.encoded()),"an untimed game has no clocks")
    }
    /// A record at `revision` over `moves`, on the fake rules, as a snapshot a host would send.
    private func snapshot(_ gameID:NetworkGameID,revision:Int,moves:[String],hostSide:NetworkSide = .white,script:FakeScript)throws -> [NetworkMessage] {
        let rules=FakeRules(script:script),pgn="[Fake]\n"+moves.joined(separator:" ");try rules.networkLoad(pgn:pgn)
        let game=NetworkPublicGame(gameID:gameID,revision:revision,hostSide:hostSide,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:pgn,clocks:nil,openOffer:nil,outcome:nil)
        return try NetworkSnapshot.capture(game,fen:try rules.networkFEN(),hashing:testHashing,random:random.source).messages
    }
    private func deliver(_ receiver:NetworkReceiver,_ messages:[NetworkMessage])throws -> NetworkByeReason? {
        for message in messages {if let reason=try receiver.receive(message:message,at:.origin).close {return reason}};return nil
    }
    /// D5: a snapshot comes only after `seated`, `resumed` or `watching`. One before them would let a connection
    /// count as live, and its game be shown, without the admission that begins participation (D8).
    func testASnapshotBeforeAdmissionBreaksTheProtocol()throws {
        let script=FakeScript(),gameID=NetworkGameID.random(using:random.source),factory=NetworkRulesFactory{FakeRules(script:script)}
        let guest=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        let watcher=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        for receiver in [guest,watcher] {
            XCTAssertEqual(try deliver(receiver,try snapshot(gameID,revision:0,moves:[],script:script)),.malformed);XCTAssertNil(receiver.installed)
        }
        XCTAssertNil(try deliver(watcher,[.watching]+(try snapshot(gameID,revision:0,moves:[],script:script))));XCTAssertNotNil(watcher.installed)
        watcher.connectionLost()
        XCTAssertEqual(try deliver(watcher,try snapshot(gameID,revision:0,moves:[],script:script)),.malformed,"a new connection is admitted again first")
    }
    /// The seats and the moves already shown never change: a later snapshot that swaps the host's side, or goes back
    /// to an earlier revision, is not this game. One at the same revision, as a refresh brings, still installs.
    func testALaterSnapshotCannotSwapSidesOrGoBack()throws {
        let script=FakeScript(),gameID=NetworkGameID.random(using:random.source),factory=NetworkRulesFactory{FakeRules(script:script)}
        let guest=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        XCTAssertNil(try deliver(guest,[.seated(credential:.random(using:random.source))]+(try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],script:script))))
        XCTAssertEqual(guest.side,.black)
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],hostSide:.black,script:script)),.malformed)
        XCTAssertEqual(guest.side,.black,"the guest keeps its seat");XCTAssertEqual(guest.installed?.hostSide,.white)
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:1,moves:["e2e4"],script:script)),.malformed)
        XCTAssertEqual(guest.revision,2,"no move already shown is taken back");XCTAssertEqual(try guest.publicGame(at:.origin)?.pgn,"[Fake]\ne2e4 e7e5")
        XCTAssertNil(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],script:script)),"the same revision again installs")
        guest.connectionLost()
        XCTAssertEqual(try deliver(guest,[.resumed]+(try snapshot(gameID,revision:1,moves:["e2e4"],script:script))),.malformed,"nor after reconnecting")
    }
}
