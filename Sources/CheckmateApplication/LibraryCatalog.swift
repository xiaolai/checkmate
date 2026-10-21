import CheckmateAssets
import CheckmateDomain
import Foundation
/// Which part of the library the browser shows.
public enum LibraryScope:String,CaseIterable,Sendable,Identifiable {
    case all,worldChampionships,classics,myGames,saved
    public var id:String {rawValue}
    public var title:String {switch self {case .all:String(localized:"All",bundle:.checkmate);case .worldChampionships:String(localized:"World Championships",bundle:.checkmate);case .classics:String(localized:"Classics",bundle:.checkmate);case .myGames:String(localized:"My games",bundle:.checkmate);case .saved:String(localized:"Saved",bundle:.checkmate)}}
}
/// The order of the games within each section (R-21): the library's own order, or by players, date (newest first) or
/// event; a game without the detail goes last.
public enum LibrarySort:String,CaseIterable,Sendable,Identifiable {
    case standard,players,date,event
    public var id:String {rawValue}
    public var title:String {switch self {case .standard:String(localized:"Default Order",bundle:.checkmate);case .players:String(localized:"Players",bundle:.checkmate);case .date:String(localized:"Date",bundle:.checkmate);case .event:String(localized:"Event",bundle:.checkmate)}}
}
/// One game as the library browser lists it, bundled or imported, with its search key computed once.
public struct LibraryRow:Identifiable,Sendable,Equatable {
    public enum Source:Sendable,Equatable {case bundled(LibraryGame),collection(sha256:String,record:CollectionRecord),saved(UUID)}
    public let id:String,source:Source,title:String,details:String,result:String,facts:String?,accessibilityLabel:String
    let searchKey:String
    /// Folded players, the date as written (year first) and the folded event, for `LibrarySort`; empty when unknown.
    var sortPlayers="",sortDate="",sortEvent=""
}
public struct LibrarySection:Identifiable,Sendable,Equatable {
    public enum Kind:Sendable,Equatable {case event,classics,collection(BrokenCollection?),saved}
    public let id:String,title:String,kind:Kind,rows:[LibraryRow]
}
/// The library's rows and sections, built off the main actor when the library loads; filtering then only compares
/// precomputed keys (budget: 50 ms a keystroke for 200 bundled and 5,000 imported rows).
public struct LibraryCatalog:Sendable,Equatable {
    public let events:[(LibraryEvent,[LibraryRow])],classics:[LibraryRow],collections:[(CollectionIndex,[LibraryRow])],broken:[BrokenCollection]
    public private(set) var saved:[LibraryRow]
    /// Every event and collection compared with all its rows (titles, keys and sources), not only ids and counts.
    public static func == (a:LibraryCatalog,b:LibraryCatalog)->Bool {
        a.events.count==b.events.count && zip(a.events,b.events).allSatisfy{$0.0==$1.0 && $0.1==$1.1} && a.classics==b.classics
            && a.collections.count==b.collections.count && zip(a.collections,b.collections).allSatisfy{$0.0==$1.0 && $0.1==$1.1} && a.broken==b.broken && a.saved==b.saved
    }
    /// Case- and diacritic-insensitive text for matching: "Réti" and "reti" agree.
    public static func folded(_ text:String)->String {text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_GB"))}
    /// "White won · 46 moves · Slav Defense": generated facts only (plan WI-7). How a decisive game ended is named only
    /// when it is known (mate on the board, or a reviewed termination); otherwise only who won.
    public static func ending(_ game:LibraryGame)->String {
        switch game.ending {
        case "checkmate":String(localized:"Checkmate",bundle:.checkmate);case "draw":String(localized:"Draw",bundle:.checkmate,comment:"A game result: neither side wins");case "resignation":String(localized:"Resignation",bundle:.checkmate);case "time":String(localized:"Won on time",bundle:.checkmate)
        default:game.result=="1-0" ? String(localized:"White won",bundle:.checkmate):game.result=="0-1" ? String(localized:"Black won",bundle:.checkmate):String(localized:"Result unknown",bundle:.checkmate)
        }
    }
    public static func facts(_ game:LibraryGame)->String {
        let moves=(game.plies+1)/2,ending=ending(game)
        return ([ending,String(localized:"\(moves) moves",bundle:.checkmate),game.opening?.name].compactMap{$0}).joined(separator:" · ")
    }
    static func bundledRow(_ game:LibraryGame,event:LibraryEvent?)->LibraryRow {
        // Under its event's section a championship game shows the players and game only; the full title is its label.
        let championship=game.category != "classic"
        let title=championship ? "\(game.white) – \(game.black), \(game.roundLabel ?? game.round)":game.title
        let details=championship ? "":([game.white=="?" ? nil:"\(game.white) – \(game.black)",game.year.map(String.init),game.kind=="traditional" ? String(localized:"traditional finish",bundle:.checkmate,comment:"A library game's kind"):game.kind=="illustrative" ? String(localized:"illustrative",bundle:.checkmate,comment:"A library game's kind"):nil].compactMap{$0}).joined(separator:" · ")
        let label=championship ? "\(game.title), \(game.result)":([game.white=="?" ? game.title:"\(game.white) – \(game.black)",game.white=="?" ? nil:game.title,game.year.map(String.init),game.result].compactMap{$0}).joined(separator:", ")
        // The event's whole year span is searchable: a match that ran into the next year is found by either year.
        let years=(event?.years ?? []).map(String.init)+[game.year.map(String.init) ?? ""]
        let key=folded(([game.white,game.black,event?.name ?? "",game.roundLabel ?? "",game.round,game.opening?.name ?? "",game.opening?.eco ?? "",game.title,game.site]+years).joined(separator:" "))
        return LibraryRow(id:"library:"+game.id,source:.bundled(game),title:title,details:details,result:game.result,facts:facts(game),accessibilityLabel:label,searchKey:key,
                          sortPlayers:game.white=="?" ? "":folded(game.white+" "+game.black),sortDate:game.year.map(String.init) ?? "",sortEvent:folded(event?.name ?? game.title))
    }
    static func collectionRow(_ record:CollectionRecord,index:Int,collection:CollectionIndex)->LibraryRow {
        func known(_ name:String)->String? {guard let value=record.tags[name]?.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value.contains(where:{$0 != "?" && $0 != "."}) else{return nil};return value}
        let white=known("White") ?? String(localized:"White",bundle:.checkmate),black=known("Black") ?? String(localized:"Black",bundle:.checkmate),year=known("Date").map{String($0.prefix(4))}.flatMap{$0.allSatisfy(\.isNumber) ? $0:nil}
        let round=known("Round").map{String(localized:"Round \($0)",bundle:.checkmate,comment:"A tournament round and its number")},result=known("Result") ?? "*"
        let details=[known("Event"),year,round].compactMap{$0}.joined(separator:" · ")
        let key=folded([white,black,known("Event") ?? "",year ?? "",known("Round") ?? "",known("Opening") ?? "",known("ECO") ?? "",known("Site") ?? ""].joined(separator:" "))
        let label=["\(white) – \(black)",known("Event"),year,result].compactMap{$0}.joined(separator:", ")
        return LibraryRow(id:"collection:\(collection.sha256):\(index)",source:.collection(sha256:collection.sha256,record:record),title:"\(white) – \(black)",details:details.isEmpty ? collection.name:details,result:result,facts:known("Opening"),accessibilityLabel:label,searchKey:key,
                          sortPlayers:known("White") == nil && known("Black") == nil ? "":folded(white+" "+black),sortDate:known("Date") ?? "",sortEvent:folded(known("Event") ?? ""))
    }
    /// A saved review: its name (or its game's title), then the game's event and year; a renamed review also names its
    /// players, and every review says when it was last saved.
    static func savedRow(_ entry:ReviewIndexEntry)->LibraryRow {
        let white=entry.white ?? String(localized:"White",bundle:.checkmate),black=entry.black ?? String(localized:"Black",bundle:.checkmate),players=entry.white != nil || entry.black != nil ? "\(white) – \(black)":nil
        let year=entry.date.map{String($0.prefix(4))}.flatMap{$0.count==4 && $0.allSatisfy(\.isNumber) ? $0:nil}
        let details=[entry.name==nil ? nil:players,entry.event,year].compactMap{$0}.joined(separator:" · ")
        let saved=String(localized:"Saved \(entry.updatedAt.formatted(date:.abbreviated,time:.shortened))",bundle:.checkmate,comment:"When a review was last saved")
        let key=folded([entry.title,entry.white ?? "",entry.black ?? "",entry.event ?? "",entry.date ?? ""].joined(separator:" "))
        return LibraryRow(id:"saved:"+entry.id.uuidString,source:.saved(entry.id),title:entry.title,details:details,result:entry.result,facts:saved,accessibilityLabel:[entry.title,details.isEmpty ? nil:details,entry.result,saved].compactMap{$0}.joined(separator:", "),searchKey:key,
                          sortPlayers:players.map(folded) ?? "",sortDate:entry.date ?? "",sortEvent:folded(entry.event ?? ""))
    }
    /// `saved` is the saved reviews' index, most recent first.
    public init(library:GameLibrary?,collections:[CollectionIndex],broken:[BrokenCollection]=[],saved:[ReviewIndexEntry]=[]) {
        let games=library?.games ?? []
        var byEvent:[String:[LibraryRow]]=[:]
        for game in games where game.category=="world-championship"{byEvent[game.event ?? "",default:[]].append(Self.bundledRow(game,event:library?.event(game.event)))}
        // Newest event first; within an event, the manifest's (match) order.
        events=(library?.events ?? []).reversed().compactMap{event in byEvent[event.id].map{(event,$0)}}
        classics=games.filter{$0.category=="classic"}.map{Self.bundledRow($0,event:nil)}
        self.collections=collections.map{collection in (collection,collection.records.enumerated().map{Self.collectionRow($0.element,index:$0.offset,collection:collection)})}
        self.broken=broken
        self.saved=saved.map(Self.savedRow)
    }
    /// The same catalog with the saved reviews' rows replaced: the index changes far more often than the games do.
    public func with(saved entries:[ReviewIndexEntry])->LibraryCatalog {var copy=self;copy.saved=entries.map(Self.savedRow);return copy}
    /// Every whitespace-separated word of the query must occur in the row's key.
    public static func matches(_ row:LibraryRow,words:[String])->Bool {words.allSatisfy{row.searchKey.contains($0)}}
    public static func words(_ query:String)->[String] {folded(query).split(whereSeparator:\.isWhitespace).map(String.init)}
    /// The sections shown for a scope and query: World Championship events newest first (collapsible), then the
    /// classics, then each collection; a broken collection keeps its section, with its error, while searching.
    /// Saved reviews show only in their own scope, apart from the games to choose from.
    public func sections(scope:LibraryScope,query:String,sort:LibrarySort = .standard)->[LibrarySection] {
        let words=Self.words(query)
        func keep(_ rows:[LibraryRow])->[LibraryRow] {Self.sorted(words.isEmpty ? rows:rows.filter{Self.matches($0,words:words)},by:sort)}
        if scope == .saved {let kept=keep(saved);return kept.isEmpty ? []:[LibrarySection(id:"saved",title:String(localized:"Saved reviews",bundle:.checkmate),kind:.saved,rows:kept)]}
        var result:[LibrarySection]=[]
        if scope == .all || scope == .worldChampionships {
            for (event,rows) in events {let kept=keep(rows);if !kept.isEmpty{result.append(LibrarySection(id:"event:"+event.id,title:event.title+" · "+event.players.joined(separator:" – "),kind:.event,rows:kept))}}
        }
        if scope == .all || scope == .classics {let kept=keep(classics);if !kept.isEmpty{result.append(LibrarySection(id:"classics",title:String(localized:"Classics",bundle:.checkmate),kind:.classics,rows:kept))}}
        if scope == .all || scope == .myGames {
            for (collection,rows) in collections {let kept=keep(rows);if !kept.isEmpty || words.isEmpty{result.append(LibrarySection(id:"collection:"+collection.sha256,title:collection.name,kind:.collection(nil),rows:kept))}}
            for item in broken{result.append(LibrarySection(id:"collection:"+item.id,title:item.name,kind:.collection(item),rows:[]))}
        }
        return result
    }
    public var rowCount:Int {events.reduce(0){$0+$1.1.count}+classics.count+collections.reduce(0){$0+$1.1.count}}
    /// Rows in `sort` order; ties, and the default order, keep the library's own order.
    static func sorted(_ rows:[LibraryRow],by sort:LibrarySort)->[LibraryRow] {
        guard sort != .standard else{return rows}
        func key(_ row:LibraryRow)->String {switch sort {case .standard:"";case .players:row.sortPlayers;case .date:row.sortDate;case .event:row.sortEvent}}
        return rows.enumerated().sorted{a,b in
            let x=key(a.element),y=key(b.element)
            if x.isEmpty != y.isEmpty{return y.isEmpty}
            if x != y{return sort == .date ? x>y:x<y}
            return a.offset<b.offset
        }.map(\.element)
    }
}
