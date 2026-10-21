import SwiftUI
import AppKit
import CheckmateCore
/// The game selected in the review workspace's library, as its inspector previews it (R-26): who played, where and
/// when, the result, how long the game is, and its final position. A game that cannot be read says so instead.
struct LibraryPreview:Equatable {
    let id:String,title:String,details:[String],result:String,moves:Int,fen:String?,problem:String?
    static func of(_ row:LibraryRow,document:GameDocument)->LibraryPreview {
        func known(_ tag:String)->String? {guard let value=document.header(tag)?.trimmingCharacters(in:.whitespacesAndNewlines),value.contains(where:{$0 != "?" && $0 != "."}) else{return nil};return PGNImporter.bounded(value,scalars:120)}
        let last=document.mainline.last.map{document.nodes[$0]},plies=document.mainline.count
        let details=[known("Event"),known("Site"),known("Date").map{$0.replacingOccurrences(of:".??",with:"")},known("Round").map{"Round "+$0}].compactMap{$0}
        return LibraryPreview(id:row.id,title:row.title,details:details,result:document.result,moves:(plies+1)/2,fen:last?.afterFEN ?? document.startingFEN,problem:nil)
    }
    static func unreadable(_ row:LibraryRow,_ message:String)->LibraryPreview {LibraryPreview(id:row.id,title:row.title,details:[],result:row.result,moves:0,fen:nil,problem:message)}
    /// "1–0 · 23 moves", or the result alone for a position with no moves.
    var summary:String {moves==0 ? ReviewFormat.result(result):Plural.count(moves,one:"%2$@ · %1$d move",other:"%2$@ · %1$d moves",ReviewFormat.result(result))}
}
/// The review workspace's inspector: the selected game's preview, or what can be opened when nothing is selected.
struct WorkspaceInspector:View {
    @ObservedObject var library:ReviewLibraryController
    let theme:String
    var body:some View {
        if let preview=library.preview {
            VStack(alignment:.leading,spacing:Metrics.smallGap){
                Text(verbatim:preview.title).sectionHeading()
                ForEach(preview.details,id:\.self){Text(verbatim:$0).foregroundStyle(.secondary)}
                if let problem=preview.problem{Text(verbatim:problem).foregroundStyle(Color(nsColor:NativeColors.error))}
                else{
                    Text(preview.summary)
                    if let fen=preview.fen{PositionThumbnail(fen:fen,theme:theme).accessibilityLabel(preview.moves==0 ? "Position":"Final position")}
                    Text("Press Return or double-click the game to open it for review.").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children:.contain).accessibilityIdentifier("library-preview")
        } else {
            Text("PGN game records").sectionHeading()
            Text("Open a finished or unfinished game, including its recorded moves and variations.")
            Text("FEN positions").sectionHeading()
            Text("Explore a single board position. Earlier moves and repetition history are not included.").foregroundStyle(.secondary)
        }
    }
}
/// A small, fixed board of one position, White at the bottom, in the learner's board theme. VoiceOver reads it as one
/// image whose value lists the pieces.
struct PositionThumbnail:View {
    let fen:String,theme:String
    static let square:CGFloat=22
    /// The 64 squares from a8 to h1, each "wk"-style or nil.
    static func squares(_ fen:String)->[String?] {
        var result:[String?]=[]
        for character in fen.split(separator:" ").first ?? "" {
            if let empty=character.wholeNumberValue{result+=Array(repeating:nil,count:empty)}
            else if character != "/"{result.append((character.isUppercase ? "w":"b")+character.lowercased())}
        }
        return result.count==64 ? result:Array(repeating:nil,count:64)
    }
    /// "White: king g1, rook f1. Black: king g8."
    static func description(_ fen:String)->String {
        let order=["k","q","r","b","n","p"],names=["king","queen","rook","bishop","knight","pawn"],files=["a","b","c","d","e","f","g","h"],board=squares(fen)
        func side(_ color:String,_ title:String)->String? {
            // Kings first, pawns last; within a kind, from a8 towards h1.
            let pieces=board.indices.compactMap{index -> (kind:Int,text:String)? in
                guard let piece=board[index],piece.hasPrefix(color),let kind=order.firstIndex(of:String(piece.suffix(1))) else{return nil}
                return (kind,"\(names[kind]) \(files[index%8])\(8-index/8)")
            }
            return pieces.isEmpty ? nil:title+": "+pieces.sorted{$0.kind<$1.kind}.map(\.text).joined(separator:", ")
        }
        return [side("w","White"),side("b","Black")].compactMap{$0}.map{$0+"."}.joined(separator:" ")
    }
    var body:some View {
        let board=Self.squares(fen),palette=BoardPalette.theme(theme),symbols=["k":"♚","q":"♛","r":"♜","b":"♝","n":"♞","p":"♟"]
        Grid(horizontalSpacing:0,verticalSpacing:0){
            ForEach(0..<8,id:\.self){rank in GridRow{ForEach(0..<8,id:\.self){file in
                let piece=board[rank*8+file]
                ZStack{
                    Rectangle().fill(Color(nsColor:(rank+file)%2==0 ? palette.lightSquare:palette.darkSquare))
                    if let piece{Text(symbols[String(piece.suffix(1)),default:"♟"]).font(.system(size:Self.square*0.8)).foregroundStyle(Color(nsColor:piece.hasPrefix("w") ? BoardPalette.lightPiece:BoardPalette.darkPiece)).shadow(color:piece.hasPrefix("w") ? .black:.clear,radius:0.6)}
                }.frame(width:Self.square,height:Self.square)
            }}}
        }.fixedSize().accessibilityElement(children:.ignore).accessibilityAddTraits(.isImage).accessibilityValue(Self.description(fen))
    }
}
