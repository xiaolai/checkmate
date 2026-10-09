import Foundation
import CryptoKit
public enum ReviewPolicy {
    public static let maximumBytes=16*1024*1024,maximumRecords=1000,maximumMainlinePlies=2000,maximumNodes=10000,maximumDepth=32,pageSize=50,maximumPageSize=100,cacheBytes=256*1024*1024
    public static let quickBudget=500,deepBudget=3000,criticalMomentsToDeepen=1,maximumTitleScalars=256,maximumIndexBytes=2*1024*1024
    public static let maximumLexemes=200000,maximumTokenScalars=1024,maximumTextScalars=1048576,maximumBranches=100,maximumBranchPlies=2000,maximumSavedBytes=64*1024*1024,maximumSavedRecords=1000,maximumLibraryBytes=512*1024*1024
}
public func reviewHash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
public func reviewFileHash(_ url:URL)throws -> String {
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
    while let data=try file.read(upToCount:64*1024),!data.isEmpty{hash.update(data:data)}
    return hash.finalize().map{String(format:"%02x",$0)}.joined()
}
public struct PGNHeader:Codable,Equatable {public let name:String,value:String;public init(_ name:String,_ value:String){self.name=name;self.value=value}}
public struct GameNode:Codable,Equatable,Identifiable {
    public let id:Int,parent:Int?,children:[Int],uci:String?,san:String?,beforeFEN:String,afterFEN:String,ply:Int,fullmove:Int,side:String,commentsBefore:[String],commentsAfter:[String],nags:[Int]
}
public struct ReviewPositionStatus:Codable,Equatable {
    public let check:Bool,checkmate:Bool,stalemate:Bool,insufficientMaterial:Bool,claimableThreefold:Bool,claimableFiftyMove:Bool,automaticFivefold:Bool,automaticSeventyFiveMove:Bool
    public var terminal:Bool {checkmate || stalemate || insufficientMaterial || automaticFivefold || automaticSeventyFiveMove}
}
public struct GameDocument:Codable,Equatable,Identifiable {
    public let schemaVersion:Int,id:UUID,contentHash:String,importedAt:Date,provenance:String,original:Data,headers:[PGNHeader],startingFEN:String,result:String,termination:String?,historyAvailable:Bool,nodes:[GameNode]
    public var title:String {let white=header("White") ?? "White",black=header("Black") ?? "Black";return String(String.UnicodeScalarView((header("Event") ?? "\(white) – \(black)").unicodeScalars.prefix(ReviewPolicy.maximumTitleScalars)))}
    public func header(_ name:String)->String? {headers.first{$0.name==name}?.value}
    public var mainline:[Int] {var result:[Int]=[],node=0;while let next=nodes[node].children.first{result.append(next);node=next};return result}
    public func history(to id:Int)throws -> [String] {guard nodes.indices.contains(id) else{throw CheckmateError.invalid("Unknown review node.")};var route:[String]=[],cursor=id;while let parent=nodes[cursor].parent{guard let uci=nodes[cursor].uci else{throw CheckmateError.invalid("Missing move.")};route.append(uci);cursor=parent};return route.reversed()}
    public func historyHash(to id:Int)throws -> String {reviewHash(Data((startingFEN+"|"+(try history(to:id)).joined(separator:" ")).utf8))}
    public func rules(at id:Int)throws -> ChessRules {let rules=try ChessRules(fen:startingFEN);for move in try history(to:id){try rules.move(uci:move)};return rules}
    /// History is required for searches/forks; drawing and rule facts use immutable snapshots.
    public func snapshotRules(at id:Int)throws -> ChessRules {
        guard nodes.indices.contains(id) else{throw CheckmateError.invalid("Unknown review node.")}
        return try ChessRules(fen:nodes[id].afterFEN)
    }
    public func status(at id:Int,using snapshot:ChessRules?=nil)throws -> ReviewPositionStatus {
        guard nodes.indices.contains(id) else{throw CheckmateError.invalid("Unknown review node.")}
        let rules:ChessRules
        if let snapshot=snapshot,snapshot.fen==nodes[id].afterFEN{rules=snapshot}else{rules=try snapshotRules(at:id)}
        // chess.js emits an en-passant square only when a legal capture exists;
        // normalize external custom FENs the same way before comparing repetitions.
        func key(_ fen:String)->String {fen.split(separator:" ").prefix(4).joined(separator:" ")}
        let target=key(rules.fen);var repetitions=0,cursor:Int?=id
        while let current=cursor {if key(nodes[current].afterFEN)==target{repetitions+=1};cursor=nodes[current].parent}
        let clock=Int(rules.fen.split(separator:" ")[4]) ?? 0
        return ReviewPositionStatus(check:rules.check,checkmate:rules.checkmate,stalemate:rules.stalemate,insufficientMaterial:rules.insufficientMaterial,claimableThreefold:repetitions>=3,claimableFiftyMove:clock>=100,automaticFivefold:repetitions>=5,automaticSeventyFiveMove:clock>=150 && !rules.checkmate)
    }
    public func validate()throws {
        guard schemaVersion==1,original.count<=ReviewPolicy.maximumBytes,reviewHash(original)==contentHash,!nodes.isEmpty,nodes.count<=ReviewPolicy.maximumNodes,nodes[0].parent==nil,nodes[0].afterFEN==startingFEN else{throw CheckmateError.invalid("Review document integrity failed.")}
        let rebuilt=try PGNImporter.parse(original,provenance:provenance)
        guard rebuilt.count==1,let record=rebuilt.first,record.headers==headers,record.startingFEN==startingFEN,record.result==result,record.termination==termination,record.nodes==nodes,record.historyAvailable==historyAvailable else{throw CheckmateError.invalid("Review tree integrity failed.")}
    }
}
