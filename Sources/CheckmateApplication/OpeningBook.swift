import CheckmateAssets
import CheckmateDomain
import CheckmateSupport
import Foundation
/// A named opening line: its ECO code and name, from Lichess chess-openings (CC0; `Content/openings/SOURCE.md`).
public struct OpeningName:Equatable,Sendable {public let eco:String,name:String}
/// Where a game's recorded moves stand against the opening book. `opening` is the deepest named position the mainline
/// reaches (at `openingNode`); `leavesTheory` is the first move after the last book position, nil while still in it.
public struct OpeningClassification:Equatable,Sendable {public let opening:OpeningName?,openingNode:Int?,leavesTheory:Int?}
/// Every position of every named opening line, keyed by placement, side to move and castling rights, so a game that
/// reaches a line by another move order still finds it. Built by `Tools/build-openings.py`.
public final class OpeningBook:Sendable {
    private let positions:[String:OpeningName?]
    private static let loaded=Result{try OpeningBook(text:String(contentsOf:NativeResources.url("openings.tsv"),encoding:.utf8))}
    /// The bundled book, read once; a damaged resource throws to every caller rather than naming nothing.
    public static func bundled()throws -> OpeningBook {try loaded.get()}
    public init(text:String)throws {
        var lines=text.split(separator:"\n",omittingEmptySubsequences:false);if lines.last?.isEmpty==true{lines.removeLast()}
        guard lines.first=="epd\teco\tname" else{throw CheckmateError.invalid("The opening book has unexpected columns.")} // not localized: the bundled book's own check, logged and never shown
        var positions:[String:OpeningName?]=[:]
        for line in lines.dropFirst() {
            let fields=line.split(separator:"\t",omittingEmptySubsequences:false).map(String.init)
            guard fields.count==3,fields[0].split(separator:" ").count==3,fields[1].isEmpty==fields[2].isEmpty else{throw CheckmateError.invalid("The opening book has an unreadable row.")} // not localized: the bundled book's own check, logged and never shown
            positions[fields[0]]=fields[1].isEmpty ? .some(nil):OpeningName(eco:fields[1],name:fields[2])
        }
        guard !positions.isEmpty else{throw CheckmateError.invalid("The opening book is empty.")} // not localized: the bundled book's own check, logged and never shown
        self.positions=positions
    }
    /// The book key of a FEN: its first three fields. The en-passant square is left out, as the book leaves it out.
    public static func key(_ fen:String)->String {fen.split(separator:" ").prefix(3).joined(separator:" ")}
    public func contains(fen:String)->Bool {positions[Self.key(fen)] != nil}
    public func name(fen:String)->OpeningName? {positions[Self.key(fen)] ?? nil}
    /// The mainline against the book, or nil when not even the starting position is a book position.
    public func classify(_ document:GameDocument)->OpeningClassification? {
        let route=[0]+document.mainline
        guard let last=route.lastIndex(where:{contains(fen:document.nodes[$0].afterFEN)}) else{return nil}
        let named=route[...last].last{name(fen:document.nodes[$0].afterFEN) != nil}
        return OpeningClassification(opening:named.flatMap{name(fen:document.nodes[$0].afterFEN)},openingNode:named,leavesTheory:last+1<route.count ? route[last+1]:nil)
    }
}
