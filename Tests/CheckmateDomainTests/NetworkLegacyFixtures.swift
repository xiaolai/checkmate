import XCTest
@testable import CheckmateDomain

/// Assistance plan A4: protocol 1.1 against 1.0. The fixtures are the exact bytes the 1.0 codec wrote (captured from it
/// before 1.1 existed), one per message type, and the 1.0 public game record. Do not regenerate them: they are what a
/// 1.0 peer still sends.
enum LegacyFixtures {
    static let messages:[String]=[
        #"{"appVersion":"0.8.1","claimID":"AHD8DNJ09T5A42GQF2HNH1R9PTW1VWDDG1XZW5FXT9HV9RX33AW0","name":"Ben","protocol":{"major":1,"minor":0},"type":"hello"}"#,
        #"{"appVersion":"0.8.1","name":"Cy","protocol":{"major":1,"minor":0},"type":"hello"}"#,
        #"{"protocol":{"major":1,"minor":0},"type":"seatedAck"}"#,
        #"{"credential":"HHTKG8KZZNNFR9K94GW0CCQ8H7AN7BKNDAVVZJ3YNF9ZD6QZR33G","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","protocol":{"major":1,"minor":0},"type":"resume"}"#,
        #"{"protocol":{"major":1,"minor":0},"type":"resync"}"#,
        #"{"commandID":"26H27KQ93541VA1ZC1EFFCC18G","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","protocol":{"major":1,"minor":0},"revision":3,"type":"move","uci":"e2e4"}"#,
        #"{"commandID":"Z3R919C5DJ31CB8DVMP3ZE0WYC","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","protocol":{"major":1,"minor":0},"type":"resign"}"#,
        #"{"commandID":"6Q0V9Z9A4AV2JAA4CBFQRN80RR","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","protocol":{"major":1,"minor":0},"revision":3,"type":"drawOffer"}"#,
        #"{"accept":true,"commandID":"8EGSD77633JS3BX2FRZT8FGVC4","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","offerID":"06VT7BX838P2SNF6H2Q7SHFJER","protocol":{"major":1,"minor":0},"type":"drawAnswer"}"#,
        #"{"commandID":"3P5B64NSVRJ060TFMENX23RJXR","gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","protocol":{"major":1,"minor":0},"revision":4,"type":"claimDraw"}"#,
        #"{"nonce":"5J4HWYFMZ57ER1TQPR4CBVA6YC","protocol":{"major":1,"minor":0},"type":"pong"}"#,
        #"{"protocol":{"major":1,"minor":0},"reason":"seatTaken","type":"bye"}"#,
        #"{"credential":"CGTH3Z0PQQ99099RRTKV19W42WN5EPPH7Q01B3H9YCCV7HX8KXNG","protocol":{"major":1,"minor":0},"type":"seated"}"#,
        #"{"protocol":{"major":1,"minor":0},"type":"resumed"}"#,
        #"{"protocol":{"major":1,"minor":0},"type":"watching"}"#,
        #"{"hash":"abc123","parts":1,"protocol":{"major":1,"minor":0},"revision":2,"snapshotID":"D5EKHT4QN90VQTAZ5Y6STM8NWW","totalBytes":10,"type":"snapshotBegin"}"#,
        #"{"data":"MDEyMzQ1Njc4OQ==","index":0,"protocol":{"major":1,"minor":0},"snapshotID":"VPPGD2X41RYSBH9YT25X9D010W","type":"snapshotPart"}"#,
        #"{"protocol":{"major":1,"minor":0},"snapshotID":"G450P850BEGEW6BDCNVSXSGBV0","type":"snapshotEnd"}"#,
        #"{"clocks":{"active":"b","black":179000,"white":180000},"hash":"abc123","protocol":{"major":1,"minor":0},"receiptFor":"X5VTR476969MJFJVXTHRVXZXB8","revision":5,"san":"Nf3","type":"moved","uci":"g1f3"}"#,
        #"{"hash":"def456","protocol":{"major":1,"minor":0},"revision":6,"san":"Nc6","type":"moved","uci":"b8c6"}"#,
        #"{"commandID":"1BNEYT4V4BEVRSNAZB2Y3C02RW","protocol":{"major":1,"minor":0},"reason":"stale","type":"rejected"}"#,
        #"{"by":"w","offerID":"K6J055E2FH5Z8R75BE4KCJG9ZW","protocol":{"major":1,"minor":0},"type":"drawOffered"}"#,
        #"{"offerID":"TPV94967V7JJQMPYDP2YX9Q57C","protocol":{"major":1,"minor":0},"type":"drawDeclined"}"#,
        #"{"clocks":{"active":"b","black":179000,"white":180000},"protocol":{"major":1,"minor":0},"type":"clock"}"#,
        #"{"clocks":{"active":"b","black":179000,"white":180000},"protocol":{"major":1,"minor":0},"result":"0-1","revision":7,"termination":"resignation","type":"ended"}"#,
        #"{"nonce":"TGPJA2MY0NBSR9JMDY0GSG9MHM","protocol":{"major":1,"minor":0},"type":"ping"}"#,
    ]
    static let record=#"{"blackName":"Ben","clocks":{"active":"b","black":179000,"white":180000},"gameID":"J734ZR3TJN1BFYNH4ABKMKSBX8","hostSide":"w","openOffer":{"by":"b","offerID":"P9MA2RYD4AMBEHW1QYH3YAW6XR"},"pgn":"[Fake]\ne2e4 e7e5","revision":2,"timeControl":"3+2","whiteName":"Ana"}"#
}
/// The 1.0 decode rules, frozen: the flat wire object as 1.0 declared it, and the 1.0 public game decoder. Synthesised
/// decoding ignores keys it does not know, which is the whole of 1.0's tolerance for 1.1's additions.
struct Legacy10Wire:Decodable {
    struct Version:Decodable {let major:Int,minor:Int}
    var type:String
    var `protocol`:Version
    var name,appVersion,uci,san,hash,data:String?
    var claimID,credential:NetworkSecret?
    var gameID:NetworkGameID?
    var commandID,offerID,snapshotID,nonce,receiptFor:NetworkID?
    var revision,totalBytes,parts,index:Int?
    var accept:Bool?
    var by:NetworkSide?
    var clocks:NetworkClocks?
    var reason:String?
    var result:NetworkGameResult?
    var termination:NetworkTermination?
    /// The fields 1.0's decoder required for each message type: a message missing one was malformed to it. Only what
    /// 1.0 declared; 1.1's optional additions are on no list.
    static let required:[String:Set<String>]=[
        "hello":["name","appVersion"],"seatedAck":[],"resume":["gameID","credential"],"resync":[],"move":["gameID","commandID","revision","uci"],
        "resign":["gameID","commandID"],"drawOffer":["gameID","commandID","revision"],"drawAnswer":["gameID","commandID","offerID","accept"],
        "claimDraw":["gameID","commandID","revision"],"pong":["nonce"],"bye":["reason"],"seated":["credential"],"resumed":[],"watching":[],
        "snapshotBegin":["snapshotID","revision","hash","totalBytes","parts"],"snapshotPart":["snapshotID","index","data"],"snapshotEnd":["snapshotID"],
        "moved":["revision","uci","san","hash"],"rejected":["commandID","reason"],"drawOffered":["offerID","by"],"drawDeclined":["offerID"],
        "clock":["clocks"],"ended":["result","termination","revision"],"ping":["nonce"]]
    enum Refusal:Error {case tooLarge,notOneZero,unknownType(String),missing(String,Set<String>),invalid(String)}
    /// 1.0's limits as 1.0 had them, written out here so that a later change to `NetworkLimits` cannot move them.
    static let maximumMessageBytes=16*1024,maximumNameBytes=64,maximumSANBytes=16,maximumHashBytes=128
    static let maximumSnapshotBytes=1024*1024,maximumSnapshotPartBytes=9*1024,maximumClockMilliseconds=1_000_000_000
    static var maximumSnapshotParts:Int {(maximumSnapshotBytes+maximumSnapshotPartBytes-1)/maximumSnapshotPartBytes}
    /// 1.0's decoding as a whole, as de55b54's `NetworkCodec.decode` did it: the 16 KiB limit, its major, a type it
    /// knew, every field that type required, each of its declared type, and every value check it made (names, UCI,
    /// SAN, hashes, revisions, clocks, snapshot sizes and parts).
    static func decode(_ data:Data)throws -> Legacy10Wire {
        guard data.count<=maximumMessageBytes else{throw Refusal.tooLarge}
        let wire=try JSONDecoder().decode(Legacy10Wire.self,from:data)
        guard wire.protocol.major==1 else{throw Refusal.notOneZero}
        guard let fields=required[wire.type] else{throw Refusal.unknownType(wire.type)}
        let present=Set(((try JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]).filter{!($0.value is NSNull)}.keys)
        guard fields.isSubset(of:present) else{throw Refusal.missing(wire.type,fields.subtracting(present))}
        try wire.validate()
        return wire
    }
    /// 1.0's free-string rule: 1 to `maximumBytes` bytes of UTF-8 with no control character.
    static func text(_ value:String,_ maximumBytes:Int=maximumNameBytes)->Bool {!value.isEmpty && value.utf8.count<=maximumBytes && !value.unicodeScalars.contains{$0.properties.generalCategory == .control}}
    private func validate()throws {
        func check(_ condition:Bool,_ field:String)throws {guard condition else{throw Refusal.invalid(field)}}
        func clocksValid(_ clocks:NetworkClocks?)->Bool {clocks.map{(0...Self.maximumClockMilliseconds).contains($0.white) && (0...Self.maximumClockMilliseconds).contains($0.black)} ?? true}
        func hashValid(_ hash:String?)->Bool {hash.map{!$0.isEmpty && $0.utf8.count<=Self.maximumHashBytes && $0.utf8.allSatisfy{(0x21...0x7E).contains($0)}} ?? false}
        switch type {
        case "hello":try check(Self.text(name!),"name");try check(Self.text(appVersion!),"appVersion")
        case "move":try check(revision!>=0,"revision");try check(ChessNotation.validUCI(uci!),"uci")
        case "drawOffer","claimDraw":try check(revision!>=0,"revision")
        case "snapshotBegin":
            try check(revision!>=0,"revision");try check(hashValid(hash),"hash")
            try check((1...Self.maximumSnapshotBytes).contains(totalBytes!),"totalBytes");try check(parts!==(totalBytes!+Self.maximumSnapshotPartBytes-1)/Self.maximumSnapshotPartBytes,"parts")
        case "snapshotPart":
            try check((0..<Self.maximumSnapshotParts).contains(index!),"index")
            guard let bytes=Data(base64Encoded:data!),!bytes.isEmpty,bytes.count<=Self.maximumSnapshotPartBytes else{throw Refusal.invalid("data")}
        case "moved":try check(Self.text(san!,Self.maximumSANBytes),"san");try check(revision!>=0,"revision");try check(ChessNotation.validUCI(uci!),"uci");try check(hashValid(hash),"hash");try check(clocksValid(clocks),"clocks")
        case "clock":try check(clocksValid(clocks),"clocks")
        case "ended":try check(revision!>=0,"revision");try check(clocksValid(clocks),"clocks")
        default:break
        }
    }
    /// 1.0's own reading of a `bye` reason: one it does not know is `unknown`.
    static let byeReasons:Set<String>=["seatTaken","badSnapshot","slow","protocolVersion","malformed","timeout","rateLimited","notAllowed","full","busy","replaced","badCredential","gameOver","hostLeft","leaving","unknown"]
}
struct Legacy10PublicGame:Decodable,Equatable {
    var gameID:NetworkGameID,revision:Int,hostSide:NetworkSide
    var whiteName:String?,blackName:String?
    var timeControl:NetworkTimeControl,pgn:String
    var clocks:NetworkClocks?,openOffer:NetworkDrawOffer?,outcome:NetworkOutcome?
    private enum CodingKeys:String,CodingKey {case gameID,revision,hostSide,whiteName,blackName,timeControl,pgn,clocks,openOffer,outcome}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        gameID=try c.decode(NetworkGameID.self,forKey:.gameID);revision=try c.decode(Int.self,forKey:.revision);hostSide=try c.decode(NetworkSide.self,forKey:.hostSide)
        whiteName=try c.decodeIfPresent(String.self,forKey:.whiteName);blackName=try c.decodeIfPresent(String.self,forKey:.blackName)
        timeControl=try c.decode(NetworkTimeControl.self,forKey:.timeControl);pgn=try c.decode(String.self,forKey:.pgn)
        clocks=try c.decodeIfPresent(NetworkClocks.self,forKey:.clocks);openOffer=try c.decodeIfPresent(NetworkDrawOffer.self,forKey:.openOffer);outcome=try c.decodeIfPresent(NetworkOutcome.self,forKey:.outcome)
        guard revision>=0,[whiteName,blackName].allSatisfy({$0.map{NetworkText.valid($0)} ?? true}),clocks?.valid ?? true,(clocks==nil)==(timeControl == .untimed) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game."))}
    }
}
