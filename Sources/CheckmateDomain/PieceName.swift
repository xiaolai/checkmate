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
    /// A piece's color inside a sentence: "the white rook". It is its own key, so no language is handed a lowercased
    /// copy of the side's name.
    public static func color(_ color:String?)->String {color?.lowercased()=="w" ? String(localized:"white",bundle:.checkmate,comment:"A piece's color inside a sentence, as in the white rook"):String(localized:"black",bundle:.checkmate,comment:"A piece's color inside a sentence, as in the black rook")}
}
