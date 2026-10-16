import CheckmateDomain
import Foundation
/// Which part of the library the browser shows.
public enum LibraryScope:String,CaseIterable,Sendable,Identifiable {
    case all,worldChampionships,classics,myGames
    public var id:String {rawValue}
    public var title:String {switch self {case .all:"All";case .worldChampionships:"World Championships";case .classics:"Classics";case .myGames:"My games"}}
}
/// One game as the library browser lists it, bundled or imported, with its search key computed once.
public struct LibraryRow:Identifiable,Sendable,Equatable {
    public enum Source:Sendable,Equatable {case bundled(LibraryGame),collection(sha256:String,record:CollectionRecord)}
    public let id:String,source:Source,title:String,details:String,result:String,facts:String?,accessibilityLabel:String
    let searchKey:String
}
public struct LibrarySection:Identifiable,Sendable,Equatable {
    public enum Kind:Sendable,Equatable {case event,classics,collection(BrokenCollection?)}
    public let id:String,title:String,kind:Kind,rows:[LibraryRow]
}
/// The library's rows and sections, built off the main actor when the library loads; filtering then only compares
/// precomputed keys (budget: 50 ms a keystroke for 200 bundled and 5,000 imported rows).
public struct LibraryCatalog:Sendable,Equatable {
    public let events:[(LibraryEvent,[LibraryRow])],classics:[LibraryRow],collections:[(CollectionIndex,[LibraryRow])],broken:[BrokenCollection]
    /// Every event and collection compared with all its rows (titles, keys and sources), not only ids and counts.
    public static func == (a:LibraryCatalog,b:LibraryCatalog)->Bool {
        a.events.count==b.events.count && zip(a.events,b.events).allSatisfy{$0.0==$1.0 && $0.1==$1.1} && a.classics==b.classics
            && a.collections.count==b.collections.count && zip(a.collections,b.collections).allSatisfy{$0.0==$1.0 && $0.1==$1.1} && a.broken==b.broken
    }
    /// Case- and diacritic-insensitive text for matching: "Réti" and "reti" agree.
    public static func folded(_ text:String)->String {text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_GB"))}
    /// "White won · 46 moves · Slav Defense": generated facts only (plan WI-7). How a decisive game ended is named only
    /// when it is known (mate on the board, or a reviewed termination); otherwise only who won.
    public static func ending(_ game:LibraryGame)->String {
        switch game.ending {
        case "checkmate":"Checkmate";case "draw":"Draw";case "resignation":"Resignation";case "time":"Won on time"
        default:game.result=="1-0" ? "White won":game.result=="0-1" ? "Black won":"Result unknown"
        }
    }
    public static func facts(_ game:LibraryGame)->String {
        let moves=(game.plies+1)/2,ending=ending(game)
        return ([ending,"\(moves) move\(moves==1 ? "":"s")",game.opening?.name].compactMap{$0}).joined(separator:" · ")
    }
    static func bundledRow(_ game:LibraryGame,event:LibraryEvent?)->LibraryRow {
        // Under its event's section a championship game shows the players and game only; the full title is its label.
        let championship=game.category != "classic"
        let title=championship ? "\(game.white) – \(game.black), \(game.roundLabel ?? game.round)":game.title
        let details=championship ? "":([game.white=="?" ? nil:"\(game.white) – \(game.black)",game.year.map(String.init),game.kind=="traditional" ? "traditional finish":game.kind=="illustrative" ? "illustrative":nil].compactMap{$0}).joined(separator:" · ")
        let label=championship ? "\(game.title), \(game.result)":([game.white=="?" ? game.title:"\(game.white) – \(game.black)",game.white=="?" ? nil:game.title,game.year.map(String.init),game.result].compactMap{$0}).joined(separator:", ")
        // The event's whole year span is searchable: a match that ran into the next year is found by either year.
        let years=(event?.years ?? []).map(String.init)+[game.year.map(String.init) ?? ""]
        let key=folded(([game.white,game.black,event?.name ?? "",game.roundLabel ?? "",game.round,game.opening?.name ?? "",game.opening?.eco ?? "",game.title,game.site]+years).joined(separator:" "))
        return LibraryRow(id:"library:"+game.id,source:.bundled(game),title:title,details:details,result:game.result,facts:facts(game),accessibilityLabel:label,searchKey:key)
    }
    static func collectionRow(_ record:CollectionRecord,index:Int,collection:CollectionIndex)->LibraryRow {
        func known(_ name:String)->String? {guard let value=record.tags[name]?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value.contains(where:{$0 != "?" && $0 != "."}) else{return nil};return value}
        let white=known("White") ?? "White",black=known("Black") ?? "Black",year=known("Date").map{String($0.prefix(4))}.flatMap{$0.allSatisfy(\.isNumber) ? $0:nil}
        let round=known("Round").map{"Round "+$0},result=known("Result") ?? "*"
        let details=[known("Event"),year,round].compactMap{$0}.joined(separator:" · ")
        let key=folded([white,black,known("Event") ?? "",year ?? "",known("Round") ?? "",known("Opening") ?? "",known("ECO") ?? "",known("Site") ?? ""].joined(separator:" "))
        let label=["\(white) – \(black)",known("Event"),year,result].compactMap{$0}.joined(separator:", ")
        return LibraryRow(id:"collection:\(collection.sha256):\(index)",source:.collection(sha256:collection.sha256,record:record),title:"\(white) – \(black)",details:details.isEmpty ? collection.name:details,result:result,facts:known("Opening"),accessibilityLabel:label,searchKey:key)
    }
    public init(library:GameLibrary?,collections:[CollectionIndex],broken:[BrokenCollection]=[]) {
        let games=library?.games ?? []
        var byEvent:[String:[LibraryRow]]=[:]
        for game in games where game.category=="world-championship"{byEvent[game.event ?? "",default:[]].append(Self.bundledRow(game,event:library?.event(game.event)))}
        // Newest event first; within an event, the manifest's (match) order.
        events=(library?.events ?? []).reversed().compactMap{event in byEvent[event.id].map{(event,$0)}}
        classics=games.filter{$0.category=="classic"}.map{Self.bundledRow($0,event:nil)}
        self.collections=collections.map{collection in (collection,collection.records.enumerated().map{Self.collectionRow($0.element,index:$0.offset,collection:collection)})}
        self.broken=broken
    }
    /// Every whitespace-separated word of the query must occur in the row's key.
    public static func matches(_ row:LibraryRow,words:[String])->Bool {words.allSatisfy{row.searchKey.contains($0)}}
    public static func words(_ query:String)->[String] {folded(query).split(whereSeparator:\.isWhitespace).map(String.init)}
    /// The sections shown for a scope and query: World Championship events newest first (collapsible), then the
    /// classics, then each collection; a broken collection keeps its section, with its error, while searching.
    public func sections(scope:LibraryScope,query:String)->[LibrarySection] {
        let words=Self.words(query)
        func keep(_ rows:[LibraryRow])->[LibraryRow] {words.isEmpty ? rows:rows.filter{Self.matches($0,words:words)}}
        var result:[LibrarySection]=[]
        if scope == .all || scope == .worldChampionships {
            for (event,rows) in events {let kept=keep(rows);if !kept.isEmpty{result.append(LibrarySection(id:"event:"+event.id,title:event.title+" · "+event.players.joined(separator:" – "),kind:.event,rows:kept))}}
        }
        if scope == .all || scope == .classics {let kept=keep(classics);if !kept.isEmpty{result.append(LibrarySection(id:"classics",title:"Classics",kind:.classics,rows:kept))}}
        if scope == .all || scope == .myGames {
            for (collection,rows) in collections {let kept=keep(rows);if !kept.isEmpty || words.isEmpty{result.append(LibrarySection(id:"collection:"+collection.sha256,title:collection.name,kind:.collection(nil),rows:kept))}}
            for item in broken{result.append(LibrarySection(id:"collection:"+item.id,title:item.name,kind:.collection(item),rows:[]))}
        }
        return result
    }
    public var rowCount:Int {events.reduce(0){$0+$1.1.count}+classics.count+collections.reduce(0){$0+$1.1.count}}
}
