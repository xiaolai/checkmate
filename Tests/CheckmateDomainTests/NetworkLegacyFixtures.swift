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
/// Mini-games plan WI-023 (D7): protocol 1.2 against 1.1. The exact bytes the 1.1 codec wrote, captured from it at
/// e35e5ef before any 1.2 change: every message type, the 1.1 additions (terms in `hello`, `assisted`, the
/// `assistanceChanged` reason), and a hosted standard-start game's record with and without assistance, made by the host
/// on the real chess rules (e4 e5 Nf3, the host White). Do not regenerate them: they are what a 1.1 peer still sends.
enum Legacy11Fixtures {
    static let messages:[String]=[
        #"{"appVersion":"0.8.2","assistance":{"black":"guided","white":"hints"},"claimID":"EMR5N842M0R0SWP9F3YH957RSQXMTAF0YVAMQXEQTETM8C1E5GK0","name":"Ben","protocol":{"major":1,"minor":1},"type":"hello"}"#,
        #"{"appVersion":"0.8.2","assistance":{"black":"off","white":"off"},"claimID":"EMR5N842M0R0SWP9F3YH957RSQXMTAF0YVAMQXEQTETM8C1E5GK0","name":"Ben","protocol":{"major":1,"minor":1},"type":"hello"}"#,
        #"{"appVersion":"0.8.2","name":"Cy","protocol":{"major":1,"minor":1},"type":"hello"}"#,
        #"{"protocol":{"major":1,"minor":1},"type":"seatedAck"}"#,
        #"{"credential":"NCYQ0262J52F314B2RGBAB95CAYKZ900AEM490CMAS3MYSHJBFRG","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"type":"resume"}"#,
        #"{"protocol":{"major":1,"minor":1},"type":"resync"}"#,
        #"{"commandID":"GY7DBSCD94CDHYB1ABY0KJE78G","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"revision":3,"type":"move","uci":"e2e4"}"#,
        #"{"assisted":true,"commandID":"3PGQBZPCB9NSQX6FVVD5PGGPFR","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"revision":4,"type":"move","uci":"e7e8q"}"#,
        #"{"commandID":"MDWZQVM5TFWPJXBP8QD1H52C7M","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"type":"resign"}"#,
        #"{"commandID":"8QWB6NG9AG9PZMPJ2V7FC8VEGR","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"revision":3,"type":"drawOffer"}"#,
        #"{"accept":false,"commandID":"D9XYCKGZ99EBVMPYX8DYYN5M8M","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","offerID":"CGYE7ASRAPN14CHJ77KJ60TKQW","protocol":{"major":1,"minor":1},"type":"drawAnswer"}"#,
        #"{"commandID":"HTYG133KWYJZ8SK0NR148V08C0","gameID":"HSVGS8Y61V7W3A3DFXX1NTV2AG","protocol":{"major":1,"minor":1},"revision":4,"type":"claimDraw"}"#,
        #"{"nonce":"TSBPV8YVKT82MNYBJSV050KGBC","protocol":{"major":1,"minor":1},"type":"pong"}"#,
        #"{"protocol":{"major":1,"minor":1},"reason":"seatTaken","type":"bye"}"#,
        #"{"protocol":{"major":1,"minor":1},"reason":"assistanceChanged","type":"bye"}"#,
        #"{"credential":"NCYQ0262J52F314B2RGBAB95CAYKZ900AEM490CMAS3MYSHJBFRG","protocol":{"major":1,"minor":1},"type":"seated"}"#,
        #"{"protocol":{"major":1,"minor":1},"type":"resumed"}"#,
        #"{"protocol":{"major":1,"minor":1},"type":"watching"}"#,
        #"{"hash":"abc123","parts":1,"protocol":{"major":1,"minor":1},"revision":2,"snapshotID":"3TMN8K5GW5KWBFY8NJG3QR6PDG","totalBytes":10,"type":"snapshotBegin"}"#,
        #"{"data":"MDEyMzQ1Njc4OQ==","index":0,"protocol":{"major":1,"minor":1},"snapshotID":"QBTTNEC908BWA8GK2HFKFWJNW4","type":"snapshotPart"}"#,
        #"{"protocol":{"major":1,"minor":1},"snapshotID":"JAQXF3YXDCYM8GC9599S2MHJXR","type":"snapshotEnd"}"#,
        #"{"assisted":true,"clocks":{"active":"b","black":179000,"white":180000},"hash":"abc123","protocol":{"major":1,"minor":1},"receiptFor":"891R0H8QX36PEEPJ2HF1HBYPGW","revision":5,"san":"Nf3","type":"moved","uci":"g1f3"}"#,
        #"{"hash":"def456","protocol":{"major":1,"minor":1},"revision":6,"san":"Nc6","type":"moved","uci":"b8c6"}"#,
        #"{"commandID":"TPDVYHZFA17R17B2SQ7X9SKQQM","protocol":{"major":1,"minor":1},"reason":"stale","type":"rejected"}"#,
        #"{"by":"w","offerID":"SMYZK37X59HDWTET9E2ZJDHKHW","protocol":{"major":1,"minor":1},"type":"drawOffered"}"#,
        #"{"offerID":"BMB9BWFKYSW569RB48TD8ETFHM","protocol":{"major":1,"minor":1},"type":"drawDeclined"}"#,
        #"{"clocks":{"active":"b","black":179000,"white":180000},"protocol":{"major":1,"minor":1},"type":"clock"}"#,
        #"{"clocks":{"active":"b","black":179000,"white":180000},"protocol":{"major":1,"minor":1},"result":"0-1","revision":7,"termination":"resignation","type":"ended"}"#,
        #"{"nonce":"M374AKWV9PQBX6WCEQJF642TTR","protocol":{"major":1,"minor":1},"type":"ping"}"#,
    ]
    /// White had hints and used one on 1. e4.
    static let assistedRecord=#"{"assistance":{"black":"off","white":"hints"},"assistedPlies":[1],"blackName":"Ben","gameID":"5QVHHR37H3BVYSNN9EN96BYBBC","hostSide":"w","pgn":"[Event \"?\"]\n[Site \"?\"]\n[Date \"????.??.??\"]\n[Round \"?\"]\n[White \"?\"]\n[Black \"?\"]\n[Result \"*\"]\n\n1. e4 e5 2. Nf3 *","revision":3,"timeControl":"untimed","whiteName":"Ana"}"#
    static let record=#"{"blackName":"Ben","gameID":"27BTBDZ9A8Z6WAJ8Z3YB46856C","hostSide":"w","pgn":"[Event \"?\"]\n[Site \"?\"]\n[Date \"????.??.??\"]\n[Round \"?\"]\n[White \"?\"]\n[Black \"?\"]\n[Result \"*\"]\n\n1. e4 e5 2. Nf3 *","revision":3,"timeControl":"untimed","whiteName":"Ana"}"#
    /// Both records' position after 1. e4 e5 2. Nf3, and its revision-3 hash (SHA-256), as the 1.1 host computed them.
    static let fen="rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
    static let hash="88c1e1ddcf759d87542e375e9cdc89930d39ffc93f7fb66062f3fbbf2749b62b"
}
/// The 1.1 decode rules, frozen: `NetworkCodec`'s flat wire object and its checks as they were at 6f51c94, the last 1.1
/// commit before 1.2. Its limits, its free-string rule and its terminations are written out, so a later change to
/// `NetworkLimits`, `NetworkText` or `NetworkTermination` cannot move the oracle; the identifier, clock and assistance
/// types are used as they are, unchanged since 1.1. Synthesised decoding ignores keys it does not know, which is the
/// whole of 1.1's tolerance for 1.2's `capabilities`. A message it reads is returned as this build's, stating no
/// capabilities, as 1.1 knew none.
struct Legacy11Wire:Decodable {
    struct Version:Decodable {let major:Int,minor:Int}
    struct Refusal:Error {let field:String}
    var type:String
    var `protocol`:Version
    var name,appVersion,uci,san,hash,data:String?
    var claimID,credential:NetworkSecret?
    var gameID:NetworkGameID?
    var commandID,offerID,snapshotID,nonce,receiptFor:NetworkID?
    var revision,totalBytes,parts,index:Int?
    var accept:Bool?
    var assistance:NetworkAssistance?
    var assisted:Bool?
    var by:NetworkSide?
    var clocks:NetworkClocks?
    var reason:String?
    var result:NetworkGameResult?
    var termination:String?
    static let maximumMessageBytes=16*1024,maximumNameBytes=64,maximumSANBytes=16,maximumHashBytes=128,maximumRevision=1_000_000
    static let maximumSnapshotBytes=1024*1024,maximumSnapshotPartBytes=9*1024
    static var maximumSnapshotParts:Int {(maximumSnapshotBytes+maximumSnapshotPartBytes-1)/maximumSnapshotPartBytes}
    static let terminations:Set<String>=["checkmate","stalemate","resignation","time","agreement","repetition","fiftyMoves","seventyFiveMoves","fivefold","insufficientMaterial","abandoned"]
    /// 1.1's free-string rule: 1 to `maximumBytes` bytes of UTF-8 with no control character and no line or paragraph separator.
    static func text(_ value:String,_ maximumBytes:Int=maximumNameBytes)->Bool {!value.isEmpty && value.utf8.count<=maximumBytes && !value.unicodeScalars.contains{[.control,.lineSeparator,.paragraphSeparator].contains($0.properties.generalCategory)}}
    static func decode(_ data:Data)throws -> NetworkMessage {
        guard data.count<=maximumMessageBytes else{throw Refusal(field:"size")}
        let wire=try JSONDecoder().decode(Legacy11Wire.self,from:data)
        guard wire.protocol.major==1 else{throw Refusal(field:"protocol")}
        return try wire.message()
    }
    private func need<T>(_ value:T?,_ field:String)throws -> T {guard let value else{throw Refusal(field:field)};return value}
    private func check(_ condition:Bool,_ field:String)throws {guard condition else{throw Refusal(field:field)}}
    private func revisionValue()throws -> Int {let value=try need(revision,"revision");try check((0...Self.maximumRevision).contains(value),"revision");return value}
    private func uciValue()throws -> String {let value=try need(uci,"uci");try check(Legacy10Wire.uci(value),"uci");return value}
    private func clocksValue()throws -> NetworkClocks? {try check(clocks?.valid ?? true,"clocks");return clocks}
    private func hashValue()throws -> String {let value=try need(hash,"hash");try check(!value.isEmpty && value.utf8.count<=Self.maximumHashBytes && value.utf8.allSatisfy{(0x21...0x7E).contains($0)},"hash");return value}
    private func message()throws -> NetworkMessage {
        switch type {
        case "hello":
            let name=try need(self.name,"name"),appVersion=try need(self.appVersion,"appVersion");try check(Self.text(name),"name");try check(Self.text(appVersion),"appVersion")
            return .hello(name:name,appVersion:appVersion,claimID:claimID,assistance:assistance)
        case "seatedAck":return .seatedAck
        case "resume":return .resume(gameID:try need(gameID,"gameID"),credential:try need(credential,"credential"))
        case "resync":return .resync
        case "move":return .move(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue(),uci:try uciValue(),assisted:assisted ?? false)
        case "resign":return .resign(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"))
        case "drawOffer":return .drawOffer(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue())
        case "drawAnswer":return .drawAnswer(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),offerID:try need(offerID,"offerID"),accept:try need(accept,"accept"))
        case "claimDraw":return .claimDraw(gameID:try need(gameID,"gameID"),commandID:try need(commandID,"commandID"),revision:try revisionValue())
        case "pong":return .pong(nonce:try need(nonce,"nonce"))
        case "bye":return .bye(NetworkByeReason(rawValue:try need(reason,"reason")) ?? .unknown)
        case "seated":return .seated(credential:try need(credential,"credential"))
        case "resumed":return .resumed
        case "watching":return .watching
        case "snapshotBegin":
            let total=try need(totalBytes,"totalBytes"),count=try need(parts,"parts")
            try check((1...Self.maximumSnapshotBytes).contains(total),"totalBytes");try check(count==(total+Self.maximumSnapshotPartBytes-1)/Self.maximumSnapshotPartBytes,"parts")
            return .snapshotBegin(snapshotID:try need(snapshotID,"snapshotID"),revision:try revisionValue(),hash:try hashValue(),totalBytes:total,parts:count)
        case "snapshotPart":
            let position=try need(index,"index"),text=try need(data,"data")
            try check((0..<Self.maximumSnapshotParts).contains(position),"index")
            guard let bytes=Data(base64Encoded:text),!bytes.isEmpty,bytes.count<=Self.maximumSnapshotPartBytes else{throw Refusal(field:"data")}
            return .snapshotPart(snapshotID:try need(snapshotID,"snapshotID"),index:position,data:bytes)
        case "snapshotEnd":return .snapshotEnd(snapshotID:try need(snapshotID,"snapshotID"))
        case "moved":
            let san=try need(self.san,"san");try check(Self.text(san,Self.maximumSANBytes),"san")
            return .moved(NetworkMoved(revision:try revisionValue(),uci:try uciValue(),san:san,hash:try hashValue(),clocks:try clocksValue(),receiptFor:receiptFor,assisted:assisted ?? false))
        case "rejected":return .rejected(commandID:try need(commandID,"commandID"),reason:NetworkRejectReason(rawValue:try need(reason,"reason")) ?? .unknown)
        case "drawOffered":return .drawOffered(NetworkDrawOffer(offerID:try need(offerID,"offerID"),by:try need(by,"by")))
        case "drawDeclined":return .drawDeclined(offerID:try need(offerID,"offerID"))
        case "clock":guard let clocks=try clocksValue() else{throw Refusal(field:"clocks")};return .clock(clocks)
        case "ended":
            let termination=try need(self.termination,"termination");try check(Self.terminations.contains(termination),"termination")
            return .ended(NetworkEnded(outcome:NetworkOutcome(result:try need(result,"result"),termination:NetworkTermination(rawValue:termination)!),revision:try revisionValue(),clocks:try clocksValue()))
        case "ping":return .ping(nonce:try need(nonce,"nonce"))
        default:throw Refusal(field:"type")
        }
    }
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
    /// 1.0's UCI rule, as `ChessNotation.validUCI` read at 1.0: four characters naming two squares, or five ending in
    /// a promotion piece. Written out so a later change to the production rule cannot move the oracle.
    static func uci(_ s:String)->Bool {
        func square(_ text:Substring)->Bool {text.count==2 && "abcdefgh".contains(text.first!) && "12345678".contains(text.last!)}
        return (s.count==4 || s.count==5) && square(s.prefix(2)) && square(s.dropFirst(2).prefix(2)) && (s.count==4 || "qrbn".contains(s.last!))
    }
    /// 1.0's free-string rule: 1 to `maximumBytes` bytes of UTF-8 with no control character.
    static func text(_ value:String,_ maximumBytes:Int=maximumNameBytes)->Bool {!value.isEmpty && value.utf8.count<=maximumBytes && !value.unicodeScalars.contains{$0.properties.generalCategory == .control}}
    private func validate()throws {
        func check(_ condition:Bool,_ field:String)throws {guard condition else{throw Refusal.invalid(field)}}
        func clocksValid(_ clocks:NetworkClocks?)->Bool {clocks.map{(0...Self.maximumClockMilliseconds).contains($0.white) && (0...Self.maximumClockMilliseconds).contains($0.black)} ?? true}
        func hashValid(_ hash:String?)->Bool {hash.map{!$0.isEmpty && $0.utf8.count<=Self.maximumHashBytes && $0.utf8.allSatisfy{(0x21...0x7E).contains($0)}} ?? false}
        switch type {
        case "hello":try check(Self.text(name!),"name");try check(Self.text(appVersion!),"appVersion")
        case "move":try check(revision!>=0,"revision");try check(Self.uci(uci!),"uci")
        case "drawOffer","claimDraw":try check(revision!>=0,"revision")
        case "snapshotBegin":
            try check(revision!>=0,"revision");try check(hashValid(hash),"hash")
            try check((1...Self.maximumSnapshotBytes).contains(totalBytes!),"totalBytes");try check(parts!==(totalBytes!+Self.maximumSnapshotPartBytes-1)/Self.maximumSnapshotPartBytes,"parts")
        case "snapshotPart":
            try check((0..<Self.maximumSnapshotParts).contains(index!),"index")
            guard let bytes=Data(base64Encoded:data!),!bytes.isEmpty,bytes.count<=Self.maximumSnapshotPartBytes else{throw Refusal.invalid("data")}
        case "moved":try check(Self.text(san!,Self.maximumSANBytes),"san");try check(revision!>=0,"revision");try check(Self.uci(uci!),"uci");try check(hashValid(hash),"hash");try check(clocksValid(clocks),"clocks")
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
        guard revision>=0,[whiteName,blackName].allSatisfy({$0.map{Legacy10Wire.text($0)} ?? true}),clocks?.valid ?? true,(clocks==nil)==(timeControl == .untimed) else{throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Invalid public game."))}
    }
}
/// Mini-games plan WI-024 (D7, L2): protocol 1.3 against 1.2. The exact bytes the 1.2 codec wrote, captured from it
/// at bf7c181 before any 1.3 change: `hello` with and without terms and a spectator's, each stating 1.2's capabilities,
/// `resume`, `move`, `moved`, `ended` and `bye`, and a hosted game's record from a declared start (the Game of the
/// Century after 40. Kb1, the host Black, 40... Nc3+ 41. Kc1 on the real chess rules), with its position and hash. Do
/// not regenerate them: they are what a 1.2 peer still sends.
enum Legacy12Fixtures {
    static let messages:[String]=[
        #"{"appVersion":"0.8.3","assistance":{"black":"hints","white":"hints"},"capabilities":["start"],"claimID":"ZJ8T55DJHWM81E63X4ARZJW9QDQ2FPBGBS8TW1JZXE2ZKEY5VZA0","name":"Ben","protocol":{"major":1,"minor":2},"type":"hello"}"#,
        #"{"appVersion":"0.8.3","assistance":{"black":"off","white":"off"},"capabilities":["start"],"claimID":"ZJ8T55DJHWM81E63X4ARZJW9QDQ2FPBGBS8TW1JZXE2ZKEY5VZA0","name":"Ben","protocol":{"major":1,"minor":2},"type":"hello"}"#,
        #"{"appVersion":"0.8.3","capabilities":["start"],"name":"Cy","protocol":{"major":1,"minor":2},"type":"hello"}"#,
        #"{"capabilities":["start"],"credential":"NC72YK32R2ACBCAHKJ0M3RAKTJGKFZ7FZ577XM62JHW6VKMZ0M00","gameID":"9HZF8WCHXP8XZ1PFNQ7ZJWA96C","protocol":{"major":1,"minor":2},"type":"resume"}"#,
        #"{"commandID":"9TZYQ9YVAYY2TESD6MAB0JB088","gameID":"9HZF8WCHXP8XZ1PFNQ7ZJWA96C","protocol":{"major":1,"minor":2},"revision":3,"type":"move","uci":"e2e4"}"#,
        #"{"hash":"abc123","protocol":{"major":1,"minor":2},"receiptFor":"A59T0XHYRX64W7C7YVRZ18WWRR","revision":5,"san":"Nf3","type":"moved","uci":"g1f3"}"#,
        #"{"protocol":{"major":1,"minor":2},"result":"0-1","revision":7,"termination":"checkmate","type":"ended"}"#,
        #"{"protocol":{"major":1,"minor":2},"reason":"protocolVersion","type":"bye"}"#,
    ]
    static let record=#"{"blackName":"Ana","gameID":"41K5PPY6VDQ7TASTDE538YB37M","hostSide":"b","pgn":"[Event \"?\"]\n[Site \"?\"]\n[Date \"????.??.??\"]\n[Round \"?\"]\n[White \"?\"]\n[Black \"?\"]\n[Result \"*\"]\n[SetUp \"1\"]\n[FEN \"1Q6/5pk1/2p3p1/1p2N2p/1b5P/1b6/r3n1P1/1K6 b - - 13 40\"]\n\n40. ... Nc3+ 41. Kc1 *","revision":2,"startFEN":"1Q6/5pk1/2p3p1/1p2N2p/1b5P/1b6/r3n1P1/1K6 b - - 13 40","timeControl":"untimed","whiteName":"Ben"}"#
    static let fen="1Q6/5pk1/2p3p1/1p2N2p/1b5P/1bn5/r5P1/2K5 b - - 15 41"
    static let hash="1a09ee4aed8ed96d49f7e22b6acefa420cf8ded2598ae418fbec56c5a34e01dc"
    /// 1.2's terminations, written out so a later case cannot move them: an `ended` naming any other is malformed to a
    /// 1.2 decoder (its `NetworkTermination` has no such case).
    static let terminations:Set<String>=["checkmate","stalemate","resignation","time","agreement","repetition","fiftyMoves","seventyFiveMoves","fivefold","insufficientMaterial","abandoned"]
}
