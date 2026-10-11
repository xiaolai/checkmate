import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
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
    public var title:String {
        func known(_ name:String)->String? {guard let value=header(name)?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value != "?" else{return nil};return value}
        let fallback:String
        if provenance=="Current game" || provenance=="Previous game"{fallback=provenance}
        else if known("White") != nil || known("Black") != nil{fallback="\(known("White") ?? "White") – \(known("Black") ?? "Black")"}
        else{fallback=historyAvailable ? "Imported game":"Imported position"}
        return String(String.UnicodeScalarView((known("Event") ?? fallback).unicodeScalars.prefix(ReviewPolicy.maximumTitleScalars)))
    }
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
    private func checkEnvelope()throws {
        guard schemaVersion==1,original.count<=ReviewPolicy.maximumBytes,reviewHash(original)==contentHash,!nodes.isEmpty,nodes.count<=ReviewPolicy.maximumNodes,nodes[0].parent==nil,nodes[0].afterFEN==startingFEN else{throw CheckmateError.invalid("Review document integrity failed.")}
    }
    /// This record as the current importer reads its hash-verified original bytes, keeping its identity. A saved
    /// review whose stored tree came from an older importer or chess.js is read this way instead of being refused.
    public func rederived()throws -> GameDocument {
        try checkEnvelope();let report=try PGNImporter.parseReport(original,provenance:provenance)
        guard report.documents.count==1,report.skipped.isEmpty,let record=report.documents.first else{throw CheckmateError.invalid("Review tree integrity failed.")}
        return GameDocument(schemaVersion:1,id:id,contentHash:contentHash,importedAt:importedAt,provenance:provenance,original:original,headers:record.headers,startingFEN:record.startingFEN,result:record.result,termination:record.termination,historyAvailable:record.historyAvailable,nodes:record.nodes)
    }
    /// A document this process built from text is valid by construction; any other must equal a fresh re-parse.
    public func validate()throws {
        try checkEnvelope();if ImportedDocuments.shared.built(self){return}
        guard try rederived()==self else{throw CheckmateError.invalid("Review tree integrity failed.")}
    }
}
/// Fingerprints of the documents `PGNImporter` built in this process. Saving one of them skips the full re-parse a
/// decoded document needs, which for a long game blocked a synchronous save for seconds. Only fingerprints are
/// kept, never documents; an evicted or unknown document falls back to the re-parse.
final class ImportedDocuments:@unchecked Sendable {
    static let shared=ImportedDocuments()
    private static let capacity=4096
    private let lock=NSLock()
    private var fingerprints:[UUID:String]=[:],order:[UUID]=[]
    /// Canonical encoding of every field, so two documents share a fingerprint only when they are equal.
    private static func fingerprint(_ document:GameDocument)->String? {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return (try? encoder.encode(document)).map(reviewHash)}
    func record(_ document:GameDocument){
        guard let fingerprint=Self.fingerprint(document) else{return};lock.lock();defer{lock.unlock()}
        if fingerprints.updateValue(fingerprint,forKey:document.id)==nil{order.append(document.id)};if order.count>Self.capacity{fingerprints[order.removeFirst()]=nil}
    }
    func built(_ document:GameDocument)->Bool {lock.lock();let known=fingerprints[document.id];lock.unlock();guard let known else{return false};return Self.fingerprint(document)==known}
}
