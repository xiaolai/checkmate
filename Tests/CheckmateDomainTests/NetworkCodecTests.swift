import XCTest
@testable import CheckmateDomain

/// D3 identifiers and D5's wire format: every message, the limits, framing, and a fuzzer.
final class NetworkCodecTests:XCTestCase {
    private let random=TestRandom(seed:11)
    private var id:NetworkID {NetworkID.random(using:random.source)}
    private var secret:NetworkSecret {NetworkSecret.random(using:random.source)}
    private lazy var game=NetworkGameID.random(using:random.source)
    func testIdentifiersAndCodesUseCrockfordBase32(){
        XCTAssertEqual(NetworkBase32.encode([UInt8](repeating:0,count:16)),String(repeating:"0",count:26))
        XCTAssertEqual(NetworkBase32.encode([UInt8](repeating:0xFF,count:16)),String(repeating:"Z",count:25)+"W","128 bits, then two zero padding bits")
        let id=NetworkGameID.random(using:random.source)
        XCTAssertEqual(id.text.count,26);XCTAssertEqual(NetworkGameID(id.text),id);XCTAssertEqual(id.displaySuffix,String(id.text.suffix(4)))
        XCTAssertNil(NetworkGameID(String(repeating:"Z",count:26)),"padding bits must be zero: one text per value")
        XCTAssertNil(NetworkGameID(String(repeating:"0",count:25)));XCTAssertNil(NetworkGameID("I"+String(repeating:"0",count:25)));XCTAssertNil(NetworkGameID(id.text.lowercased()))
        XCTAssertEqual(secret.text.count,52);XCTAssertEqual(self.id.text.count,26)
        let code=NetworkCode.random(using:random.source)
        XCTAssertEqual(code.text.count,8);XCTAssertEqual(NetworkCode(typed:code.grouped.lowercased()),code)
        XCTAssertEqual(NetworkCode(typed:" k7qd-2m9x ")?.text,"K7QD2M9X");XCTAssertEqual(NetworkCode(typed:"K7QD2M9X")?.grouped,"K7QD-2M9X")
        XCTAssertEqual(NetworkCode(typed:"oOiIlL01")?.text,"00111101","O reads as 0, I and L as 1")
        for typed in ["K7QD2M9U","K7QD2M9","K7QD2M9XX","K7QD2M9É","K7QD_2M9X",""] {XCTAssertNil(NetworkCode(typed:typed),typed)}
        XCTAssertEqual(NetworkSideChoice.white.resolved(using:random.source),.white)
        XCTAssertEqual(Set((0..<32).map{_ in NetworkSideChoice.random.resolved(using:random.source)}),[.white,.black])
    }
    func testSecretsAndCodesNeverDescribeThemselves(){
        let secret=self.secret,code=NetworkCode.random(using:random.source)
        var dumped="";dump(secret,to:&dumped);dump(code,to:&dumped);dump(NetworkMessage.seated(credential:secret),to:&dumped);dump(NetworkReceiverRole.guest(claimID:secret),to:&dumped)
        for text in ["\(secret)",String(reflecting:secret),"\(code)",String(reflecting:code),dumped,"\(NetworkMessage.seated(credential:secret))",String(reflecting:NetworkMessage.resume(gameID:game,credential:secret))] {
            XCTAssertFalse(text.contains(secret.text),text);XCTAssertFalse(text.contains(code.text),text)
        }
        XCTAssertTrue(secret.matches(NetworkSecret(secret.text)!));XCTAssertFalse(secret.matches(self.secret))
    }
    private var everyMessage:[NetworkMessage] {
        let clocks=NetworkClocks(white:180_000,black:179_500,active:.black)
        return [.hello(name:"Ben",appVersion:"0.8.0",claimID:secret),.hello(name:"Cy 观战",appVersion:"0.8.0",claimID:nil),.seatedAck,.resume(gameID:game,credential:secret),.resync,
                .move(gameID:game,commandID:id,revision:3,uci:"e7e8q"),.resign(gameID:game,commandID:id),.drawOffer(gameID:game,commandID:id,revision:4),.drawAnswer(gameID:game,commandID:id,offerID:id,accept:true),.claimDraw(gameID:game,commandID:id,revision:5),.pong(nonce:id),.bye(.slow),
                .seated(credential:secret),.resumed,.watching,.snapshotBegin(snapshotID:id,revision:9,hash:"ab12",totalBytes:9217,parts:2),.snapshotPart(snapshotID:id,index:1,data:Data([1,2,3])),.snapshotEnd(snapshotID:id),
                .moved(NetworkMoved(revision:6,uci:"g1f3",san:"Nf3",hash:"cd34",clocks:clocks,receiptFor:id)),.moved(NetworkMoved(revision:7,uci:"g8f6",san:"Nf6",hash:"ef56",clocks:nil,receiptFor:nil)),
                .rejected(commandID:id,reason:.stale),.drawOffered(NetworkDrawOffer(offerID:id,by:.white)),.drawDeclined(offerID:id),.clock(clocks),.ended(NetworkEnded(outcome:NetworkOutcome(result:.draw,termination:.agreement),revision:8,clocks:clocks)),.ping(nonce:id),
                // 1.1's additions (assistance plan A4), so the fuzzer mutates them too.
                .hello(name:"Dee",appVersion:"0.9.0",claimID:secret,assistance:NetworkAssistance(white:.hints,black:.off)),.move(gameID:game,commandID:id,revision:3,uci:"e2e4",assisted:true),
                .moved(NetworkMoved(revision:8,uci:"b1c3",san:"Nc3",hash:"ab90",clocks:nil,receiptFor:id,assisted:true))]
    }
    func testEveryMessageRoundTripsWithItsTypeAndProtocol()throws {
        let messages=everyMessage
        XCTAssertEqual(Set(messages.map(\.type)).count,24,"every message of D5's table")
        for message in messages {
            let data=try NetworkCodec.encode(message)
            XCTAssertEqual(try NetworkCodec.decode(data),message)
            let object=try XCTUnwrap(try JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual(object["type"] as? String,message.type);XCTAssertEqual(object["protocol"] as? [String:Int],["major":1,"minor":1])
        }
    }
    func testUnknownFieldsAreIgnoredAndAMajorMismatchIsReadable()throws {
        func json(_ text:String)->Data {Data(text.utf8)}
        XCTAssertEqual(try NetworkCodec.decode(json(#"{"type":"resync","protocol":{"major":1,"minor":7},"future":{"x":[1,2]}}"#)),.resync)
        XCTAssertThrowsError(try NetworkCodec.decode(json(#"{"type":"hello","protocol":{"major":2,"minor":0},"name":42}"#))){error in
            XCTAssertEqual(error as? NetworkCodecError,.protocolMismatch(peer:NetworkProtocolVersion(major:2,minor:0)))
            XCTAssertEqual((error as? NetworkCodecError)?.byeReason,.protocolVersion)
            XCTAssertTrue("\(error)".contains("2.0") && "\(error)".contains("1.1"),"\(error)")
        }
        let malformed=[#"{"type":"resync"}"#,#"{"type":"teleport","protocol":{"major":1,"minor":0}}"#,#"{"type":"move","protocol":{"major":1,"minor":0}}"#,"[]","not json",
                       #"{"type":"move","protocol":{"major":1,"minor":0},"gameID":"x","commandID":"y","revision":0,"uci":"e2e4"}"#,
                       #"{"type":"move","protocol":{"major":1,"minor":0},"gameID":"\#(game.text)","commandID":"\#(id.text)","revision":-1,"uci":"e2e4"}"#,
                       #"{"type":"move","protocol":{"major":1,"minor":0},"gameID":"\#(game.text)","commandID":"\#(id.text)","revision":1,"uci":"e2e9"}"#,
                       #"{"type":"clock","protocol":{"major":1,"minor":0},"clocks":{"white":-5,"black":0}}"#,
                       // 1.1's fields (A4): terms missing a side, an unknown level, and a flag that is not a Boolean.
                       #"{"type":"hello","protocol":{"major":1,"minor":1},"name":"Ben","appVersion":"1","assistance":{"white":"hints"}}"#,
                       #"{"type":"hello","protocol":{"major":1,"minor":1},"name":"Ben","appVersion":"1","assistance":{"white":"turbo","black":"off"}}"#,
                       #"{"type":"move","protocol":{"major":1,"minor":1},"gameID":"\#(game.text)","commandID":"\#(id.text)","revision":1,"uci":"e2e4","assisted":"yes"}"#,
                       #"{"type":"moved","protocol":{"major":1,"minor":1},"revision":1,"uci":"e2e4","san":"e4","hash":"ab","assisted":1}"#]
        for text in malformed {XCTAssertThrowsError(try NetworkCodec.decode(json(text)),text){XCTAssertEqual(($0 as? NetworkCodecError)?.byeReason,.malformed,text)}}
        let command=id
        XCTAssertEqual(try NetworkCodec.decode(json(#"{"type":"bye","protocol":{"major":1,"minor":3},"reason":"solarFlare"}"#)),.bye(.unknown))
        XCTAssertEqual(try NetworkCodec.decode(json(#"{"type":"rejected","protocol":{"major":1,"minor":3},"reason":"solarFlare","commandID":"\#(command.text)"}"#)),.rejected(commandID:command,reason:.unknown))
    }
    func testTheBoundsAreTheOnesThePlanFixes(){
        XCTAssertEqual(NetworkLimits.maximumMessageBytes,16_384);XCTAssertEqual(NetworkLimits.maximumNameBytes,64);XCTAssertEqual(NetworkLimits.maximumSnapshotPartBytes,9_216)
        XCTAssertEqual(NetworkLimits.maximumSnapshotBytes,1_048_576);XCTAssertEqual(NetworkLimits.maximumSnapshotParts,114)
        XCTAssertEqual(NetworkLimits.peerQueueBytes,65_536);XCTAssertEqual(NetworkLimits.spectatorQueuesBytes,524_288);XCTAssertEqual(NetworkLimits.maximumSpectators,8)
        XCTAssertEqual(NetworkLimits.handshakesPerListener,4);XCTAssertEqual(NetworkLimits.pendingConnectionsPerListener,4)
        XCTAssertEqual(NetworkLimits.handshakeDeadline,.seconds(5));XCTAssertEqual(NetworkLimits.admissionDeadline,.seconds(5));XCTAssertEqual(NetworkLimits.partialFrameDeadline,.seconds(5))
        XCTAssertEqual(NetworkLimits.failedHandshakesPerAddress,5);XCTAssertEqual(NetworkLimits.failedHandshakeWindow,.seconds(60))
        XCTAssertEqual(NetworkLimits.inboundMessagesPerWindow,20);XCTAssertEqual(NetworkLimits.inboundWindow,.seconds(1))
        XCTAssertEqual(NetworkLimits.pingInterval,.seconds(2));XCTAssertEqual(NetworkLimits.maximumOutstandingPings,2);XCTAssertEqual(NetworkLimits.pongDeadline,.seconds(6))
        XCTAssertEqual(NetworkLimits.storedReceipts,64);XCTAssertEqual(NetworkLimits.reservationDuration,.seconds(30));XCTAssertEqual(NetworkLimits.holdDuration,.seconds(120));XCTAssertEqual(NetworkLimits.clockMessageInterval,.seconds(1))
        XCTAssertEqual(NetworkTimeControl.allCases.map(\.rawValue),["untimed","3+2","5+3","10+5","15+10","30+0"])
        XCTAssertEqual(NetworkTimeControl.allCases.map(\.pgnValue),["-","180+2","300+3","600+5","900+10","1800+0"])
    }
    func testSixteenKiBIsTheLimitOnTheWholeEncodedMessage()throws {
        // Exactly 16 KiB, padded with an unknown field, decodes; one byte more is refused before parsing.
        func padded(_ total:Int)->Data {let head=#"{"type":"resync","protocol":{"major":1,"minor":0},"pad":""#,tail=#""}"#;return Data((head+String(repeating:"x",count:total-head.utf8.count-tail.utf8.count)+tail).utf8)}
        XCTAssertEqual(padded(16_384).count,16_384);XCTAssertEqual(try NetworkCodec.decode(padded(16_384)),.resync)
        XCTAssertThrowsError(try NetworkCodec.decode(padded(16_385))){XCTAssertEqual($0 as? NetworkCodecError,.tooLarge(16_385))}
        XCTAssertNoThrow(try NetworkFraming.frame(padded(16_384)))
        XCTAssertThrowsError(try NetworkFraming.frame(padded(16_385))){XCTAssertEqual($0 as? NetworkFramingError,.badLength(16_385))}
        var decoder=NetworkFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0,0,0x40,0x01]),at:.origin),"refused from the header alone"){XCTAssertEqual($0 as? NetworkFramingError,.badLength(16_385))}
        // Free strings: 64 bytes of UTF-8 at most, never empty, no control characters.
        let longest=String(repeating:"é",count:32)
        XCTAssertNoThrow(try NetworkCodec.encode(.hello(name:longest,appVersion:"1",claimID:nil)))
        for name in [longest+"a","","Ben\nSmith","Ben\u{0}"] {XCTAssertThrowsError(try NetworkCodec.encode(.hello(name:name,appVersion:"1",claimID:nil)),name.debugDescription)}
        // The largest part with the longest metadata still fits; one raw byte more is refused.
        let part=NetworkMessage.snapshotPart(snapshotID:id,index:NetworkLimits.maximumSnapshotParts-1,data:Data((0..<NetworkLimits.maximumSnapshotPartBytes).map{UInt8(truncatingIfNeeded:$0*7)}))
        let size=try NetworkCodec.encode(part).count
        XCTAssertLessThanOrEqual(size,NetworkLimits.maximumMessageBytes);XCTAssertGreaterThan(size,12*1024,"12 KiB of Base64, no slash escaping")
        XCTAssertThrowsError(try NetworkCodec.encode(.snapshotPart(snapshotID:id,index:0,data:Data(count:NetworkLimits.maximumSnapshotPartBytes+1))))
        let begin=NetworkMessage.snapshotBegin(snapshotID:id,revision:Int.max,hash:String(repeating:"f",count:NetworkLimits.maximumHashBytes),totalBytes:NetworkLimits.maximumSnapshotBytes,parts:NetworkLimits.maximumSnapshotParts)
        XCTAssertLessThanOrEqual(try NetworkCodec.encode(begin).count,NetworkLimits.maximumMessageBytes)
        XCTAssertThrowsError(try NetworkCodec.encode(.snapshotBegin(snapshotID:id,revision:0,hash:"h",totalBytes:NetworkLimits.maximumSnapshotBytes+1,parts:NetworkLimits.maximumSnapshotParts+1)))
        // Names that escape to the most JSON stay far below the limit.
        let quoted=String(repeating:"\"",count:64)
        XCTAssertLessThan(try NetworkCodec.encode(.hello(name:quoted,appVersion:quoted,claimID:secret)).count,1024)
    }
    func testFramesReassembleAcrossAnySplitAndAPartialFrameHasFiveSeconds()throws {
        let messages=everyMessage
        let stream=try messages.reduce(Data()){$0+(try NetworkFraming.frame(try NetworkCodec.encode($1)))}
        for chunk in [1,3,4,5,64,1000,stream.count] {
            var decoder=NetworkFrameDecoder(),frames:[Data]=[],offset=0
            while offset<stream.count {
                let end=min(offset+chunk,stream.count);frames+=try decoder.append(stream.subdata(in:offset..<end),at:.origin);offset=end
                XCTAssertLessThanOrEqual(decoder.bufferedBytes,NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes)
            }
            XCTAssertEqual(try frames.map(NetworkCodec.decode),messages);XCTAssertEqual(decoder.bufferedBytes,0);XCTAssertNil(decoder.partialSince)
        }
        var decoder=NetworkFrameDecoder()
        let frame=try NetworkFraming.frame(try NetworkCodec.encode(.resync))
        XCTAssertEqual(try decoder.append(frame.prefix(3),at:instant(1)),[])
        XCTAssertEqual(decoder.partialFrameDeadline,instant(6));XCTAssertFalse(decoder.partialFrameExpired(at:instant(5.999)));XCTAssertTrue(decoder.partialFrameExpired(at:instant(6)))
        XCTAssertEqual(try decoder.append(frame.dropFirst(3)+frame.prefix(2),at:instant(4)).count,1)
        XCTAssertEqual(decoder.partialSince,instant(4),"a new partial frame has its own five seconds")
        var empty=NetworkFrameDecoder()
        XCTAssertThrowsError(try empty.append(Data([0,0,0,0]),at:.origin)){XCTAssertEqual($0 as? NetworkFramingError,.badLength(0))}
    }
    func testTheCodecFuzzerNeverCrashesOrAcceptsPastALimit()throws {
        let seeds=try everyMessage.map(NetworkCodec.encode)
        var accepted=0
        for round in 0..<6000 {
            var bytes=[UInt8](seeds[round%seeds.count])
            switch round%4 {
            case 0:for _ in 0...Int(random.byte()%4) {bytes[Int(random.byte())*bytes.count/256]=random.byte()}
            case 1:bytes=Array(bytes.prefix(Int(random.byte())*bytes.count/256))
            case 2:bytes.insert(contentsOf:(0..<Int(random.byte()%16)).map{_ in random.byte()},at:Int(random.byte())*bytes.count/256)
            default:bytes=(0..<Int(random.byte())*80).map{_ in random.byte()}
            }
            do{let message=try NetworkCodec.decode(Data(bytes));accepted+=1;XCTAssertLessThanOrEqual(bytes.count,NetworkLimits.maximumMessageBytes);assertWithinLimits(message)}
            catch{XCTAssertTrue(error is NetworkCodecError,"\(error)")}
        }
        XCTAssertGreaterThan(accepted,100,"some mutations stay valid, so the checks after decoding run")
        // The frame decoder over noise: only bad lengths, and never more than one partial frame buffered.
        var decoder=NetworkFrameDecoder(),refusals=0
        for _ in 0..<3000 {
            do{_ = try decoder.append(Data((0..<Int(random.byte())).map{_ in random.byte()}),at:.origin)}catch{XCTAssertTrue(error is NetworkFramingError);refusals+=1;decoder=NetworkFrameDecoder()}
            XCTAssertLessThanOrEqual(decoder.bufferedBytes,NetworkFraming.headerBytes+NetworkLimits.maximumMessageBytes)
        }
        XCTAssertGreaterThan(refusals,0)
    }
    private func assertWithinLimits(_ message:NetworkMessage){
        switch message {
        case .hello(let name,let version,_,_):XCTAssertLessThanOrEqual(name.utf8.count,64);XCTAssertLessThanOrEqual(version.utf8.count,64)
        case .snapshotPart(_,let index,let data):XCTAssertLessThanOrEqual(data.count,NetworkLimits.maximumSnapshotPartBytes);XCTAssertLessThan(index,NetworkLimits.maximumSnapshotParts)
        case .snapshotBegin(_,_,let hash,let total,_):XCTAssertLessThanOrEqual(hash.utf8.count,NetworkLimits.maximumHashBytes);XCTAssertLessThanOrEqual(total,NetworkLimits.maximumSnapshotBytes)
        case .moved(let moved):XCTAssertLessThanOrEqual(moved.san.utf8.count,NetworkLimits.maximumSANBytes)
        default:break
        }
        XCTAssertNoThrow(try NetworkCodec.encode(message),"anything accepted can be sent back")
    }
}
/// D7's pure counters: the transport consults them, the host uses the rate window itself.
final class NetworkAdmissionTests:XCTestCase {
    func testTwentyMessagesInAnySecond(){
        var window=NetworkRateWindow()
        for index in 0..<20 {XCTAssertTrue(window.admit(at:instant(Double(index)*0.01)))}
        XCTAssertFalse(window.admit(at:instant(0.5)),"the 21st within a second");XCTAssertFalse(window.admit(at:instant(0.999)))
        XCTAssertTrue(window.admit(at:instant(1.0)),"the first has left the window");XCTAssertFalse(window.admit(at:instant(1.005)),"the second has not")
        XCTAssertTrue(window.admit(at:instant(1.01)))
    }
    func testHandshakeSlotsAndFailuresPerAddress(){
        var slots=NetworkSlots()
        XCTAssertEqual(slots.limit,4);for _ in 0..<4 {XCTAssertTrue(slots.acquire())};XCTAssertFalse(slots.acquire());slots.release();XCTAssertTrue(slots.acquire());XCTAssertEqual(slots.used,4)
        var failures=NetworkHandshakeFailures()
        for index in 0..<5 {XCTAssertTrue(failures.allows("peer-a",at:instant(Double(index))));failures.recordFailure(from:"peer-a",at:instant(Double(index)))}
        XCTAssertFalse(failures.allows("peer-a",at:instant(10)),"five failures within a minute");XCTAssertTrue(failures.allows("peer-b",at:instant(10)),"counted per address")
        XCTAssertTrue(failures.allows("peer-a",at:instant(60)),"the first failure has aged out")
        var many=NetworkHandshakeFailures(maximumAddresses:16)
        for index in 0..<1000 {many.recordFailure(from:"peer-\(index)",at:instant(Double(index)/100))}
        XCTAssertLessThanOrEqual(many.trackedAddresses,16,"memory stays bounded under a flood of sources")
    }
}
