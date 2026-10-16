import CheckmateDomain
import CheckmateSupport
import CheckmateAssets
import Foundation
public struct LibraryOpening:Codable,Equatable,Sendable {public let eco:String,name:String}
/// A World Championship event of the roster (`Content/game-library/roster.json`).
public struct LibraryEvent:Codable,Equatable,Sendable,Identifiable {
    public let id:String,name:String,years:[Int],format:String,players:[String]
    /// "World Championship 1886" or, for an event spanning the new year, "World Championship 1890–91".
    public var title:String {guard let first=years.first else{return name};guard let last=years.last,last != first else{return "\(name) \(first)"};return "\(name) \(first)–\(String(last).suffix(2))"}
}
/// One bundled historical game: where its record lies in its category file and the facts the library shows. `kind` is
/// `game` (a played score), `traditional` (a familiar finish that may not be the proven played ending) or `illustrative`.
public struct LibraryGame:Codable,Equatable,Sendable,Identifiable {
    public let id:String,category:String,event:String?,kind:String,white:String,black:String,site:String,date:String,year:Int?,round:String,roundLabel:String?,result:String,title:String
    public let opening:LibraryOpening?,plies:Int,finalSAN:String,ending:String,uciSHA256:String,file:String,offset:Int,length:Int,sha256:String
}
/// The bundled game library (`Resources/game-library`, built by `Tools/build-game-library.py`). The manifest is fixed
/// content, so any defect throws: it is reported, never shown as a shorter list. Opening a game reads exactly its byte
/// range and checks the record's hash.
public struct GameLibrary:Sendable,Equatable {
    public static let provenance="Library game"
    public static let categories=["world-championship","classic"],kinds:Set<String>=["game","traditional","illustrative"],endings:Set<String>=["checkmate","resignation","time","draw","unknown"],results:Set<String>=["1-0","0-1","1/2-1/2"]
    static let maximumText=200,maximumGames=5000
    public let events:[LibraryEvent],games:[LibraryGame]
    public let directory:URL
    private struct Manifest:Codable {let schemaVersion:Int,counts:[String:Int],events:[LibraryEvent],games:[LibraryGame]}
    public static var directory:URL {NativeResources.url("game-library")}
    public static func load(from directory:URL=directory)throws -> GameLibrary {
        let manifest:Manifest
        do{manifest=try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json")))}catch{throw CheckmateError.invalid("The game library manifest could not be read: \(error)")}
        guard manifest.schemaVersion==1,!manifest.games.isEmpty,manifest.games.count<=maximumGames,Set(manifest.games.map(\.id)).count==manifest.games.count,Set(manifest.events.map(\.id)).count==manifest.events.count else{throw CheckmateError.invalid("The game library manifest is invalid.")}
        func bounded(_ text:String,empty:Bool=false)->Bool {(empty || !text.isEmpty) && text.count<=maximumText && !text.contains(where:{$0.isNewline})}
        func identifier(_ text:String)->Bool {(1...64).contains(text.count) && text.allSatisfy{$0.isASCII && ($0.isLowercase || $0.isNumber || $0=="-")}}
        func hex(_ text:String)->Bool {text.count==64 && text.allSatisfy{"0123456789abcdef".contains($0)}}
        for event in manifest.events {
            guard identifier(event.id),bounded(event.name),!event.years.isEmpty,event.years.allSatisfy({(1800...2200).contains($0)}),["match","tournament"].contains(event.format),!event.players.isEmpty,event.players.allSatisfy({bounded($0)}) else{throw CheckmateError.invalid("The game library event \(event.id.prefix(64)) is invalid.")}
        }
        let events=Set(manifest.events.map(\.id))
        var sizes:[String:Int]=[:]
        for game in manifest.games {
            // A plain file name in this folder only, named by its category: never a path that could reach outside it.
            let eventValid=game.category=="classic" ? game.event==nil:(game.event.map{events.contains($0)} ?? false)
            let textValid=[game.white,game.black,game.site,game.date,game.round,game.title,game.finalSAN].allSatisfy({bounded($0)}) && (game.roundLabel.map{bounded($0)} ?? true) && (game.opening.map{bounded($0.eco) && bounded($0.name)} ?? true)
            guard identifier(game.id),categories.contains(game.category),game.file==game.category+".pgn",kinds.contains(game.kind),endings.contains(game.ending),results.contains(game.result),
                  eventValid,textValid,game.year.map({(1000...2200).contains($0)}) ?? true,
                  (1...ReviewPolicy.maximumMainlinePlies).contains(game.plies),hex(game.uciSHA256),hex(game.sha256),game.offset>=0,game.length>0 else{throw CheckmateError.invalid("The library game \(game.id.prefix(64)) has an invalid manifest entry.")}
            if sizes[game.file]==nil {
                let path=directory.appendingPathComponent(game.file).path
                guard let size=(try? FileManager.default.attributesOfItem(atPath:path))?[.size] as? Int else{throw CheckmateError.invalid("The game library file \(game.file) is missing.")};sizes[game.file]=size
            }
            // Within the file, compared without adding (an absurd offset is an error, not an overflow).
            guard let size=sizes[game.file],game.offset<=size,game.length<=size-game.offset else{throw CheckmateError.invalid("The library game \(game.id) lies outside its file.")}
        }
        // The manifest accounts for the whole bundle: the stated count per category, every event covered, and each
        // category file tiled exactly by its records (one newline between them), so an omitted or overlapping entry fails.
        guard Set(manifest.counts.keys)==Set(categories),categories.allSatisfy({category in (manifest.counts[category] ?? 0)>0 && manifest.games.filter{$0.category==category}.count==manifest.counts[category]}),
              events.isSubset(of:Set(manifest.games.compactMap(\.event))) else{throw CheckmateError.invalid("The game library manifest does not account for every game.")}
        // Every PGN in the bundle folder is a category file the manifest tiles: none is left unreferenced.
        let bundled=Set(((try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? []).filter{$0.hasSuffix(".pgn")})
        guard bundled==Set(categories.map{$0+".pgn"}),Set(sizes.keys)==bundled else{throw CheckmateError.invalid("The game library folder holds PGN files the manifest does not account for.")}
        for (file,size) in sizes {
            var end = -1
            for game in manifest.games.filter({$0.file==file}).sorted(by:{$0.offset<$1.offset}) {
                guard game.offset==end+1 else{throw CheckmateError.invalid("The game library file \(file) has bytes outside its records.")};end=game.offset+game.length
            }
            guard end==size else{throw CheckmateError.invalid("The game library file \(file) has bytes outside its records.")}
        }
        return GameLibrary(events:manifest.events,games:manifest.games,directory:directory)
    }
    /// Exactly the game's record, its hash checked; a mismatch is a defect in the bundle and fails loudly.
    public func data(_ game:LibraryGame)throws -> Data {
        let data:Data
        do{let handle=try FileHandle(forReadingFrom:directory.appendingPathComponent(game.file));defer{try? handle.close()};try handle.seek(toOffset:UInt64(game.offset));data=try handle.read(upToCount:game.length) ?? Data()}catch{throw CheckmateError.invalid("The library game \(game.title) could not be read.")}
        guard data.count==game.length,reviewHash(data)==game.sha256 else{throw CheckmateError.invalid("The library game \(game.title) is damaged: its record does not match the library.")}
        return data
    }
    /// Throws unless the parsed record is the manifest's game: its players, result, ply count and exact moves.
    public static func verify(_ document:GameDocument,matches game:LibraryGame)throws {
        let line=document.mainline,uci=line.compactMap{document.nodes[$0].uci}.joined(separator:" ")
        guard document.header("White")==game.white,document.header("Black")==game.black,document.result==game.result,line.count==game.plies,reviewHash(Data(uci.utf8))==game.uciSHA256 else{throw CheckmateError.invalid("The library game \(game.title) is damaged: its record does not match the library.")}
    }
    public func event(_ id:String?)->LibraryEvent? {id.flatMap{id in events.first{$0.id==id}}}
}
