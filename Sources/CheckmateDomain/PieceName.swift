import CheckmateAssets
/// A piece's name inside a sentence ("the knight on f3"), from its letter (p n b r q k, either case), in the reader's
/// language. Shown text uses these; identifiers and stored data keep their own English names.
public enum PieceName {
    public static func of(_ letter:String?)->String {
        switch letter?.lowercased() {
        case "p"?:String(localized:"pawn",bundle:.checkmate,comment:"A piece's name inside a sentence")
        case "n"?:String(localized:"knight",bundle:.checkmate,comment:"A piece's name inside a sentence")
        case "b"?:String(localized:"bishop",bundle:.checkmate,comment:"A piece's name inside a sentence")
        case "r"?:String(localized:"rook",bundle:.checkmate,comment:"A piece's name inside a sentence")
        case "q"?:String(localized:"queen",bundle:.checkmate,comment:"A piece's name inside a sentence")
        case "k"?:String(localized:"king",bundle:.checkmate,comment:"A piece's name inside a sentence")
        default:String(localized:"piece",bundle:.checkmate,comment:"A piece's name inside a sentence, when its kind is unknown")
        }
    }
    /// The name of two or more pieces of one kind ("two knights").
    public static func plural(_ letter:String?)->String {
        switch letter?.lowercased() {
        case "p"?:String(localized:"pawns",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        case "n"?:String(localized:"knights",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        case "b"?:String(localized:"bishops",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        case "r"?:String(localized:"rooks",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        case "q"?:String(localized:"queens",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        case "k"?:String(localized:"kings",bundle:.checkmate,comment:"Two or more pieces of one kind, inside a sentence")
        default:String(localized:"pieces",bundle:.checkmate,comment:"Two or more pieces, inside a sentence, when their kind is unknown")
        }
    }
    /// A side's name inside a sentence: "White", "Black".
    public static func side(_ color:String?)->String {color?.lowercased()=="w" ? String(localized:"White",bundle:.checkmate):String(localized:"Black",bundle:.checkmate)}
    // A piece named by color and kind is one phrase with its own key for each color and kind, so a language can make the
    // color agree with the piece's gender, and the article with both. Shown text never puts a color beside a piece name.
    /// "the white knight": a piece by color and kind inside a sentence, as in "Move the white knight from b1 to c3".
    public static func the(_ color:String?,_ letter:String?)->String {
        let white=color?.lowercased()=="w"
        switch letter?.lowercased() {
        case "p"?:return white ? String(localized:"the white pawn",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white pawn from e2 to e4"):String(localized:"the black pawn",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black pawn from e7 to e5")
        case "n"?:return white ? String(localized:"the white knight",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white knight from b1 to c3"):String(localized:"the black knight",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black knight from b8 to c6")
        case "b"?:return white ? String(localized:"the white bishop",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white bishop from c1 to g5"):String(localized:"the black bishop",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black bishop from c8 to g4")
        case "r"?:return white ? String(localized:"the white rook",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white rook from a1 to a8"):String(localized:"the black rook",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black rook from a8 to a1")
        case "q"?:return white ? String(localized:"the white queen",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white queen from d1 to h5"):String(localized:"the black queen",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black queen from d8 to h4")
        case "k"?:return white ? String(localized:"the white king",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the white king from e1 to e2"):String(localized:"the black king",bundle:.checkmate,comment:"A piece by color and kind inside a sentence, as in: Move the black king from e8 to e7")
        default:return white ? String(localized:"the white piece",bundle:.checkmate,comment:"A piece by color inside a sentence, when its kind is unknown"):String(localized:"the black piece",bundle:.checkmate,comment:"A piece by color inside a sentence, when its kind is unknown")
        }
    }
    /// "White knight": a piece by its side and kind, opening a label, as in "White knight on f3".
    public static func named(_ color:String?,_ letter:String?)->String {
        let white=color?.lowercased()=="w"
        switch letter?.lowercased() {
        case "p"?:return white ? String(localized:"White pawn",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White pawn on e4"):String(localized:"Black pawn",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black pawn on e5")
        case "n"?:return white ? String(localized:"White knight",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White knight on f3"):String(localized:"Black knight",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black knight on f6")
        case "b"?:return white ? String(localized:"White bishop",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White bishop on c4"):String(localized:"Black bishop",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black bishop on c5")
        case "r"?:return white ? String(localized:"White rook",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White rook on a1"):String(localized:"Black rook",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black rook on a8")
        case "q"?:return white ? String(localized:"White queen",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White queen on d1"):String(localized:"Black queen",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black queen on d8")
        case "k"?:return white ? String(localized:"White king",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: White king on e1"):String(localized:"Black king",bundle:.checkmate,comment:"A piece by side and kind, opening a label, as in: Black king on e8")
        default:return white ? String(localized:"White piece",bundle:.checkmate,comment:"A piece by side, opening a label, when its kind is unknown"):String(localized:"Black piece",bundle:.checkmate,comment:"A piece by side, opening a label, when its kind is unknown")
        }
    }
    /// "White, knight": the piece on a board square in VoiceOver's description of the square, whose parts are listed with
    /// commas ("f3, White, knight, selected"). A language may name the piece as one phrase instead.
    public static func listed(_ color:String?,_ letter:String?)->String {
        let white=color?.lowercased()=="w"
        switch letter?.lowercased() {
        case "p"?:return white ? String(localized:"White, pawn",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, pawn",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        case "n"?:return white ? String(localized:"White, knight",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, knight",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        case "b"?:return white ? String(localized:"White, bishop",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, bishop",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        case "r"?:return white ? String(localized:"White, rook",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, rook",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        case "q"?:return white ? String(localized:"White, queen",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, queen",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        case "k"?:return white ? String(localized:"White, king",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind"):String(localized:"Black, king",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square: side, then kind")
        default:return white ? String(localized:"White, piece",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square, when its kind is unknown"):String(localized:"Black, piece",bundle:.checkmate,comment:"The piece on a board square, in VoiceOver's comma-separated description of the square, when its kind is unknown")
        }
    }
}
