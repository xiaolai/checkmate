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
    /// D7: the guest's snapshot is never refused. Spectators still sending another record are closed to make room.
    func testTheGuestsSnapshotClosesSpectatorsHoldingAnotherRecord()throws {
        let probe=try TestNetwork(hostSide:.black)
        let (probeGuest,_)=try probe.startGame()
        try probe.play(probeGuest,"e2e4")
        var limits=NetworkHostLimits();limits.retainedCaptureBytes=try probe.host.publicGame(at:probe.now).encoded().count+8
        let net=try TestNetwork(hostSide:.black,limits:limits)
        let (guest,_)=try net.startGame()
        try net.play(guest,"e2e4")
        net.autoComplete=false
        let first=net.client(.watch,name:"Cy"),second=net.client(.watch,name:"Di");try net.connect(first);try net.connect(second)
        try net.hostPlays("e7e5")
        try net.cut(guest);try net.connect(guest)
        XCTAssertNil(guest.closedWith,"the guest is never refused its snapshot")
        XCTAssertEqual(first.closedWith,.slow);XCTAssertEqual(second.closedWith,.slow,"both held the other record")
        XCTAssertEqual(net.host.snapshotBytes,try net.host.publicGame(at:net.now).encoded().count,"only the guest's record is held")
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
        // A long record that extends the moves shown, at the revision that counts them.
        var long=game;long.pgn=game.pgn+" "+Array(repeating:"g1f3",count:3998).joined(separator:" ");long.revision=4000
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
        XCTAssertNil(try close(try messages(game,hash:hash)));XCTAssertEqual(watcher.revision,2)
        XCTAssertNil(try close(parts),"the long record itself installs: only the corruptions failed");XCTAssertEqual(watcher.revision,4000)
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
            // Pacing, not D7's capture budget, is under test: a spectator's record this long would pass the budget.
            var limits=NetworkHostLimits();limits.retainedCaptureBytes=NetworkLimits.maximumSnapshotBytes
            let host=try NetworkHost(gameID:gameID,runEpoch:NetworkID.random(using:random.source),settings:NetworkHostSettings(hostName:"Ana",hostSide:.white),rules:hostRules,hashing:testHashing,random:random.source,limits:limits,at:.origin)
            // The receiver's games start where the host's do: the preloaded moves are the start, not moves of the game.
            let receiver=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"1",rules:hostRules,hashing:testHashing,random:random.source)
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
        XCTAssertEqual(Mirror(reflecting:game).children.compactMap(\.label),["gameID","revision","hostSide","whiteName","blackName","timeControl","pgn","clocks","openOffer","outcome","assistance","assistedPlies","startFEN","ruleset"],"no field could hold a credential, a claim or app state; the last four are the assistance terms, the assisted plies (assistance plan A2, A7), the declared start (mini-games plan D7) and the mini-game ruleset (protocol 1.3)")
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
    private func snapshot(_ gameID:NetworkGameID,revision:Int,moves:[String],hostSide:NetworkSide = .white,assisted:[Int]=[],outcome:NetworkOutcome?=nil,timeControl:NetworkTimeControl = .untimed,assistance:NetworkAssistance = .off,pgn record:String?=nil,script:FakeScript)throws -> [NetworkMessage] {
        let rules=FakeRules(script:script),pgn=record ?? "[Fake]\n"+moves.joined(separator:" ");try rules.networkLoad(pgn:"[Fake]\n"+moves.joined(separator:" "))
        let clocks=timeControl == .untimed ? nil:NetworkClocks(white:60_000,black:60_000,active:nil)
        let game=NetworkPublicGame(gameID:gameID,revision:revision,hostSide:hostSide,whiteName:"Ana",blackName:"Ben",timeControl:timeControl,pgn:pgn,clocks:clocks,openOffer:nil,outcome:outcome,assistance:assistance,assistedPlies:assisted)
        return try NetworkSnapshot.capture(game,fen:try rules.networkFEN(),hashing:testHashing,random:random.source).messages
    }
    private func deliver(_ receiver:NetworkReceiver,_ messages:[NetworkMessage],at now:NetworkInstant = .origin)throws -> NetworkByeReason? {
        for message in messages {if let reason=try receiver.receive(message:message,at:now).close {return reason}};return nil
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
    /// A guest seated on the fake rules with `moves` shown, at the revision that counts them.
    private func seated(_ moves:[String],assisted:[Int]=[])throws -> (NetworkReceiver,NetworkGameID,FakeScript) {
        let script=FakeScript(),gameID=NetworkGameID.random(using:random.source),factory=NetworkRulesFactory{FakeRules(script:script)}
        let guest=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        XCTAssertNil(try deliver(guest,[.seated(credential:.random(using:random.source))]+(try snapshot(gameID,revision:moves.count,moves:moves,assisted:assisted,script:script))))
        return (guest,gameID,script)
    }
    /// What this Mac verified stays: a later snapshot extends the moves shown and keeps their assisted flags. One that
    /// replaces a move, at the same revision or a later one, or drops or adds a flag on a move already shown, is not
    /// this game. A record whose revision does not count its moves is not a snapshot at all.
    func testALaterSnapshotExtendsWhatWasVerified()throws {
        let (guest,gameID,script)=try seated(["e2e4","e7e5"],assisted:[1])
        // The forged histories keep the assisted flag, so only the history differs. Ten seconds apart: snapshots
        // nobody asked for are bounded by rate too.
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["d2d4","d7d5"],assisted:[1],script:script),at:instant(10)),.malformed,"another history at the same revision")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:3,moves:["d2d4","d7d5","g1f3"],assisted:[1],script:script),at:instant(20)),.malformed,"another history at a later revision")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],assisted:[],script:script),at:instant(30)),.malformed,"an assisted flag removed")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],assisted:[1,2],script:script),at:instant(40)),.malformed,"an assisted flag added to a move shown")
        XCTAssertEqual(try guest.publicGame(at:.origin)?.pgn,"[Fake]\ne2e4 e7e5");XCTAssertEqual(guest.assistedPlies,[1])
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4"],script:script),at:instant(50)),.badSnapshot,"a revision that does not count its moves")
        XCTAssertNil(try deliver(guest,try snapshot(gameID,revision:3,moves:["e2e4","e7e5","g1f3"],assisted:[1,3],script:script),at:instant(60)),"an extension with its own new flag")
        XCTAssertEqual(guest.assistedPlies,[1,3])
    }
    /// Game news before this connection's snapshot is refused: after a reconnect the board is only remembered, and a
    /// move or a result could otherwise be applied to it before the host's own record arrives.
    func testNewsBeforeTheConnectionsSnapshotIsRefused()throws {
        let (guest,_,_)=try seated(["e2e4"])
        guest.connectionLost()
        let news:[NetworkMessage]=[.moved(NetworkMoved(revision:2,uci:"e7e5",san:"e5",hash:"x",clocks:nil,receiptFor:nil)),.ended(NetworkEnded(outcome:NetworkOutcome(result:.whiteWins,termination:.resignation),revision:2,clocks:nil)),.clock(NetworkClocks(white:1,black:1,active:nil)),.drawOffered(NetworkDrawOffer(offerID:.random(using:random.source),by:.white))]
        for message in news {
            XCTAssertEqual(try guest.receive(message:message,at:.origin).close,.malformed,"\(message.type) before the snapshot")
            guest.connectionLost()
        }
        XCTAssertEqual(guest.revision,1);XCTAssertNil(guest.outcome);XCTAssertNil(try guest.submitMove(uci:"e7e5"),"no command before the snapshot either")
    }
    /// A game ends once, and clocks only belong to a timed game.
    func testAGameEndsOnceAndAnUntimedGameHasNoClocks()throws {
        let (guest,_,_)=try seated(["e2e4"])
        let result=NetworkOutcome(result:.whiteWins,termination:.resignation)
        XCTAssertNil(try guest.receive(message:.ended(NetworkEnded(outcome:result,revision:2,clocks:nil)),at:.origin).close);XCTAssertEqual(guest.outcome,result)
        XCTAssertNil(try guest.receive(message:.ended(NetworkEnded(outcome:result,revision:2,clocks:nil)),at:.origin).close,"the same result again is a duplicate")
        XCTAssertEqual(try guest.receive(message:.ended(NetworkEnded(outcome:NetworkOutcome(result:.draw,termination:.agreement),revision:3,clocks:nil)),at:.origin).close,.malformed,"a second result")
        XCTAssertEqual(guest.outcome,result);XCTAssertEqual(guest.revision,2)
        let (untimed,_,_)=try seated(["e2e4"])
        XCTAssertEqual(try untimed.receive(message:.clock(NetworkClocks(white:1,black:1,active:.black)),at:.origin).close,.malformed,"a clock in an untimed game")
        let (moving,_,_)=try seated(["e2e4"])
        XCTAssertEqual(try moving.receive(message:.moved(NetworkMoved(revision:2,uci:"e7e5",san:"e5",hash:"x",clocks:NetworkClocks(white:1,black:1,active:.white),receiptFor:nil)),at:.origin).close,.malformed,"a move carrying clocks in an untimed game")
        XCTAssertNil(untimed.clocks(at:.origin))
    }
    /// D7's rate on the host's own messages: a flood of valid frames is cut off at 20 a second; snapshot parts, which
    /// a long record legitimately sends in a burst, do not count.
    func testAFloodFromTheHostIsCutOff()throws {
        let (guest,_,_)=try seated(["e2e4"])
        var closed:NetworkByeReason?,sent=0
        // Past the window of the seating messages, so the count starts from nothing.
        for _ in 0..<100 where closed==nil {sent+=1;closed=try guest.receive(message:.ping(nonce:.random(using:random.source)),at:.origin+(.seconds(10))).close}
        XCTAssertEqual(closed,.rateLimited);XCTAssertEqual(sent,NetworkLimits.inboundMessagesPerWindow+1)
        let (paced,_,_)=try seated(["e2e4"])
        for second in 0..<5 {for _ in 0..<10 {XCTAssertNil(try paced.receive(message:.ping(nonce:.random(using:random.source)),at:.origin+(.seconds(second))).close)}}
    }
    /// A revision is a peer's number: an out-of-range one is refused when decoded, before any arithmetic on it, so an
    /// `Int.min` with a result cannot trap, nor an `Int.max` make `revision+1` overflow later.
    func testAnOutOfRangeRevisionIsRefusedBeforeAnyArithmetic()throws {
        let game=NetworkPublicGame(gameID:NetworkGameID.random(using:random.source),revision:0,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"[Fake]\n",clocks:nil,openOffer:nil,outcome:NetworkOutcome(result:.whiteWins,termination:.resignation))
        for revision in [Int.min,-1,0,NetworkLimits.maximumRevision+1,Int.max] {
            var invalid=game;invalid.revision=revision
            XCTAssertThrowsError(try JSONDecoder().decode(NetworkPublicGame.self,from:try JSONEncoder().encode(invalid)),"revision \(revision) with a result")
        }
        var valid=game;valid.revision=1;XCTAssertNoThrow(try JSONDecoder().decode(NetworkPublicGame.self,from:try JSONEncoder().encode(valid)))
        // Every message that carries one refuses it at the codec, and the receiver's board is untouched.
        let (guest,_,_)=try seated(["e2e4"])
        let carriers:[NetworkMessage]=[.snapshotBegin(snapshotID:.random(using:random.source),revision:2,hash:"abc",totalBytes:10,parts:1),.moved(NetworkMoved(revision:2,uci:"e7e5",san:"e5",hash:"abc",clocks:nil,receiptFor:nil)),.ended(NetworkEnded(outcome:NetworkOutcome(result:.whiteWins,termination:.resignation),revision:2,clocks:nil))]
        for message in carriers {
            for revision in [Int.min,-1,NetworkLimits.maximumRevision+1,Int.max] {
                var object=try XCTUnwrap(JSONSerialization.jsonObject(with:try NetworkCodec.encode(message)) as? [String:Any]);object["revision"]=revision
                let wire=try JSONSerialization.data(withJSONObject:object)
                XCTAssertThrowsError(try NetworkCodec.decode(wire),"\(message.type) at \(revision)")
                XCTAssertNotNil(try guest.receive(wire,at:.origin).close,"\(message.type) at \(revision) closes the connection")
            }
        }
        XCTAssertEqual(guest.revision,1);XCTAssertNil(guest.outcome)
    }
    /// A name is one line: control characters and Unicode's line and paragraph separators are refused.
    func testANameCannotBreakALine(){
        for name in ["Ben\u{2028}Smith","Ben\u{2029}Smith","Ben\nSmith","Ben\u{85}Smith"] {XCTAssertFalse(NetworkText.valid(name),name.debugDescription)}
        XCTAssertTrue(NetworkText.valid("Ben Smith"));XCTAssertTrue(NetworkText.valid("Zoë"))
    }
    /// An admission comes once per connection: a second `seated`, `resumed` or `watching` on it breaks the protocol.
    func testAnAdmissionComesOncePerConnection()throws {
        let (guest,_,_)=try seated(["e2e4"])
        XCTAssertEqual(try guest.receive(message:.resumed,at:.origin).close,.malformed)
        let script=FakeScript(),gameID=NetworkGameID.random(using:random.source),factory=NetworkRulesFactory{FakeRules(script:script)}
        let watcher=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        XCTAssertNil(try watcher.receive(message:.watching,at:.origin).close)
        XCTAssertEqual(try watcher.receive(message:.watching,at:.origin).close,.malformed,"a second watching")
        let credential=NetworkSecret.random(using:random.source),seat=NetworkReceiver(gameID:gameID,role:.guest(claimID:.random(using:random.source)),name:"Ben",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        XCTAssertNil(try seat.receive(message:.seated(credential:credential),at:.origin).close)
        XCTAssertEqual(try seat.receive(message:.seated(credential:credential),at:.origin).close,.malformed,"the same seated again on one connection")
        seat.connectionLost()
        XCTAssertNil(try seat.receive(message:.seated(credential:credential),at:.origin).close,"a new connection is admitted afresh")
    }
    /// Each snapshot costs a full replay, so those this Mac did not ask for are few: a host repeating valid snapshots
    /// is cut off. One this Mac asked for, by `resync`, still installs, whatever came before it.
    func testSnapshotsNobodyAskedForAreBounded()throws {
        let (guest,gameID,script)=try seated(["e2e4"])
        let later=NetworkInstant.origin+(.seconds(60))
        var closed:NetworkByeReason?,installed=0
        for _ in 0..<10 where closed==nil {closed=try deliver(guest,try snapshot(gameID,revision:1,moves:["e2e4"],script:script),at:later);if closed==nil{installed+=1}}
        XCTAssertEqual(closed,.rateLimited);XCTAssertEqual(installed,NetworkLimits.unsolicitedSnapshotsPerWindow)
        let (asking,askingID,askingScript)=try seated(["e2e4"])
        for _ in 0..<NetworkLimits.unsolicitedSnapshotsPerWindow {XCTAssertNil(try deliver(asking,try snapshot(askingID,revision:1,moves:["e2e4"],script:askingScript),at:later))}
        let gap=try asking.receive(message:.moved(NetworkMoved(revision:3,uci:"g1f3",san:"Nf3",hash:"x",clocks:nil,receiptFor:nil)),at:later)
        XCTAssertEqual(gap.send,[.resync],"a gap asks for a snapshot")
        XCTAssertNil(try deliver(asking,try snapshot(askingID,revision:3,moves:["e2e4","e7e5","g1f3"],script:askingScript),at:later),"the snapshot it asked for installs")
        XCTAssertEqual(asking.revision,3)
    }
    /// Only a move that can advance the board is exempt from the rate: while a resync is awaited, a stream of
    /// "next" moves is discarded, and counted.
    func testMovesThatCannotAdvanceCount()throws {
        let (guest,_,_)=try seated(["e2e4"])
        let later=NetworkInstant.origin+(.seconds(60))
        _ = try guest.receive(message:.moved(NetworkMoved(revision:3,uci:"g1f3",san:"Nf3",hash:"x",clocks:nil,receiptFor:nil)),at:later)
        var closed:NetworkByeReason?,sent=0
        for _ in 0..<100 where closed==nil {sent+=1;closed=try guest.receive(message:.moved(NetworkMoved(revision:2,uci:"e7e5",san:"e5",hash:"x",clocks:nil,receiptFor:nil)),at:later).close}
        XCTAssertEqual(closed,.rateLimited);XCTAssertLessThanOrEqual(sent,NetworkLimits.inboundMessagesPerWindow+1)
    }
    /// A game ends once. After its result, a result at the same revision must be that result, and a snapshot must
    /// repeat the ended game exactly: no other result, and no further move that would reopen it.
    func testAfterTheEndNothingRewritesTheResult()throws {
        let result=NetworkOutcome(result:.whiteWins,termination:.resignation),other=NetworkOutcome(result:.draw,termination:.agreement)
        let (guest,gameID,script)=try seated(["e2e4"])
        XCTAssertNil(try guest.receive(message:.ended(NetworkEnded(outcome:result,revision:2,clocks:nil)),at:.origin).close)
        XCTAssertEqual(try guest.receive(message:.ended(NetworkEnded(outcome:other,revision:2,clocks:nil)),at:.origin).close,.malformed,"another result at the same revision")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4"],outcome:other,script:script)),.malformed,"a snapshot with another result")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4","e7e5"],script:script)),.malformed,"a snapshot that reopens the game with a move")
        XCTAssertEqual(guest.outcome,result);XCTAssertEqual(guest.revision,2)
        XCTAssertNil(try deliver(guest,try snapshot(gameID,revision:2,moves:["e2e4"],outcome:result,script:script)),"the ended game itself installs")
        XCTAssertEqual(guest.outcome,result)
    }
    /// The terms (A2) and the time control are fixed when the game is hosted, for a spectator as for a guest.
    func testTheTermsAndTheTimeControlNeverChange()throws {
        let script=FakeScript(),gameID=NetworkGameID.random(using:random.source),factory=NetworkRulesFactory{FakeRules(script:script)}
        let watcher=NetworkReceiver(gameID:gameID,role:.spectator,name:"Cy",appVersion:"1",rules:factory,hashing:testHashing,random:random.source)
        XCTAssertNil(try deliver(watcher,[.watching]+(try snapshot(gameID,revision:1,moves:["e2e4"],timeControl:.fivePlusThree,assistance:NetworkAssistance(both:.hints),script:script))))
        XCTAssertEqual(try deliver(watcher,try snapshot(gameID,revision:1,moves:["e2e4"],timeControl:.fivePlusThree,assistance:.off,script:script)),.malformed,"other terms")
        XCTAssertEqual(try deliver(watcher,try snapshot(gameID,revision:1,moves:["e2e4"],assistance:NetworkAssistance(both:.hints),script:script)),.malformed,"timed to untimed")
        XCTAssertEqual(try deliver(watcher,try snapshot(gameID,revision:1,moves:["e2e4"],timeControl:.tenPlusFive,assistance:NetworkAssistance(both:.hints),script:script)),.malformed,"another time control")
        XCTAssertEqual(watcher.installed?.assistance,NetworkAssistance(both:.hints));XCTAssertEqual(watcher.installed?.timeControl,.fivePlusThree)
        XCTAssertNil(try deliver(watcher,try snapshot(gameID,revision:1,moves:["e2e4"],timeControl:.fivePlusThree,assistance:NetworkAssistance(both:.hints),script:script)),"the same game installs")
    }
    /// D7: the work one snapshot costs is bounded before any is done. A record holding more moves than its revision
    /// counts, or a revision beyond any game the rules allow, is refused without being replayed.
    func testAnOverlongRecordIsRefusedUnread()throws {
        let (guest,gameID,script)=try seated(["e2e4"])
        let loads=script.loads
        let padded="[Fake]\n"+Array(repeating:"g1f3 g8f6 f3g1 f6g8",count:50).joined(separator:" ")
        XCTAssertEqual(try deliver(guest,try snapshot(gameID,revision:1,moves:["e2e4"],pgn:padded,script:script)),.badSnapshot)
        XCTAssertEqual(script.loads,loads+1,"only the test's own record was loaded, never the receiver's replay")
        XCTAssertEqual(guest.revision,1)
        let (long,longID,longScript)=try seated([])
        XCTAssertEqual(try deliver(long,try snapshot(longID,revision:NetworkLimits.maximumPlies+2,moves:[],pgn:"[Fake]\n",script:longScript)),.badSnapshot,"a revision past the longest game")
        // Movetext on a tag line escapes the token count, so the record's size bounds the work too.
        let (hidden,hiddenID,hiddenScript)=try seated(["e2e4"]),hiddenLoads=hiddenScript.loads
        let tagLine="[Event \"x\"] "+Array(repeating:"g1f3 g8f6 f3g1 f6g8",count:400).joined(separator:" ")
        XCTAssertEqual(NetworkSnapshotInstaller.moveTokens(tagLine,limit:10),0,"the token count does not see movetext on a tag line")
        XCTAssertEqual(try deliver(hidden,try snapshot(hiddenID,revision:1,moves:["e2e4"],pgn:tagLine,script:hiddenScript)),.badSnapshot,"a record larger than its moves allow")
        XCTAssertEqual(hiddenScript.loads,hiddenLoads+1,"only the test's own record was loaded, never the receiver's replay");XCTAssertEqual(hidden.revision,1)
    }
    /// The move count before replay reads only movetext: tag pairs, comments, variations, move numbers, results and
    /// annotations are not moves.
    func testMoveTokensCountOnlyMoves(){
        let pgn="[Event \"x\"]\n[White \"A b c\"]\n\n1. e4 {a comment with words} e5 2.Nf3 (2. f4 exf4) Nc6 $1 3... a6 ; rest of line\n4. Bb5 1-0"
        XCTAssertEqual(NetworkSnapshotInstaller.moveTokens(pgn,limit:100),6)
        XCTAssertEqual(NetworkSnapshotInstaller.moveTokens("[Fake]\n"+Array(repeating:"e2e4",count:50).joined(separator:" "),limit:10),11,"counting stops past the limit")
    }
    /// A valid envelope whose record states an out-of-range revision is refused when the record decodes, before any
    /// arithmetic on it, and the board stays as it was.
    func testARecordWithAnOutOfRangeRevisionInAValidEnvelopeIsRefused()throws {
        let (guest,gameID,_)=try seated(["e2e4"])
        for revision in [Int.min,-1,NetworkLimits.maximumRevision+1] {
            let game=NetworkPublicGame(gameID:gameID,revision:2,hostSide:.white,whiteName:"Ana",blackName:"Ben",timeControl:.untimed,pgn:"[Fake]\ne2e4",clocks:nil,openOffer:nil,outcome:NetworkOutcome(result:.whiteWins,termination:.resignation))
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:try JSONEncoder().encode(game)) as? [String:Any]);object["revision"]=revision
            let payload=try JSONSerialization.data(withJSONObject:object),snapshotID=NetworkID.random(using:random.source)
            let messages:[NetworkMessage]=[.snapshotBegin(snapshotID:snapshotID,revision:2,hash:testHashing.positionHash(fen:"e2e4 b - - 0 1",revision:2),totalBytes:payload.count,parts:1),.snapshotPart(snapshotID:snapshotID,index:0,data:payload),.snapshotEnd(snapshotID:snapshotID)]
            XCTAssertEqual(try deliver(guest,messages,at:.origin),.badSnapshot,"record revision \(revision)")
            guest.connectionLost();XCTAssertNil(try guest.receive(message:.resumed,at:.origin).close)
        }
        XCTAssertEqual(guest.revision,1);XCTAssertNil(guest.outcome)
    }
}
