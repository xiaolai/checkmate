import CheckmateAssets
import CheckmateDomain
import Foundation
/// A start the host may choose (mini-games plan D7, Q2): the position after a chosen move of a bundled game-library
/// game. There is no free FEN entry, and D2's position-game starts are not offered yet. The game from it is ordinary
/// chess; the host still refuses one that is over (`NetworkHostError.startOver`).
public struct NetworkLibraryStart:Equatable {
    /// The library game's manifest ID and title.
    public let gameID:String,title:String
    /// The plies of the game played before the start, from 1 to the game's last.
    public let ply:Int
    /// The position after that ply, as the library record replays to it.
    public let fen:String
    /// "After 20... Nf6": the move the start follows.
    public let move:String
    public init(gameID:String,title:String,ply:Int,fen:String,move:String){self.gameID=gameID;self.title=title;self.ply=ply;self.fen=fen;self.move=move}
    /// Every start one library game offers, one per ply: its record is read and checked against the manifest, so a
    /// damaged bundle throws rather than offering a position the game never reached.
    public static func positions(of game:LibraryGame,in library:GameLibrary)throws -> [NetworkLibraryStart] {
        let documents=try PGNImporter.parse(try library.data(game),provenance:GameLibrary.provenance)
        guard documents.count==1 else{throw CheckmateError.invalid(String(localized:"The library game \(game.title) does not hold exactly one game.",bundle:.checkmate))}
        let document=documents[0];try GameLibrary.verify(document,matches:game)
        return document.mainline.map{id in
            let node=document.nodes[id]
            return NetworkLibraryStart(gameID:game.id,title:game.title,ply:node.ply,fen:node.afterFEN,move:String(localized:"After \(node.fullmove)\(node.side=="b" ? "...":".") \(node.san ?? "")",bundle:.checkmate))
        }
    }
}
