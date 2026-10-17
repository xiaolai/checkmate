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
