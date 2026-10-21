import CheckmateAssets
/// A piece's name from its letter (p n b r q k, either case), in the reader's language. A sentence names a piece with
/// `phrase`, or by color with `the`, `bracketed`, `named` or `listed`, never by joining words to a bare name. Shown text
/// uses these; identifiers and stored data keep their own English names.
public enum PieceName {
    /// A piece's bare name, as in the list label "knight e4".
    public static func of(_ letter:String?)->String {
        switch letter?.lowercased() {
        case "p"?:String(localized:"pawn",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        case "n"?:String(localized:"knight",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        case "b"?:String(localized:"bishop",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        case "r"?:String(localized:"rook",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        case "q"?:String(localized:"queen",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        case "k"?:String(localized:"king",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4")
        default:String(localized:"piece",bundle:.checkmate,comment:"A piece's bare name, as in the list label: knight e4, when its kind is unknown")
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
    /// "the white knight": a piece by color and kind as the object of a verb, as in "Move the white knight from b1 to c3".
    public static func the(_ color:String?,_ letter:String?)->String {
        let white=color?.lowercased()=="w"
        switch letter?.lowercased() {
        case "p"?:return white ? String(localized:"the white pawn",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white pawn from e2 to e4"):String(localized:"the black pawn",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black pawn from e7 to e5")
        case "n"?:return white ? String(localized:"the white knight",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white knight from b1 to c3"):String(localized:"the black knight",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black knight from b8 to c6")
        case "b"?:return white ? String(localized:"the white bishop",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white bishop from c1 to g5"):String(localized:"the black bishop",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black bishop from c8 to g4")
        case "r"?:return white ? String(localized:"the white rook",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white rook from a1 to a8"):String(localized:"the black rook",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black rook from a8 to a1")
        case "q"?:return white ? String(localized:"the white queen",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white queen from d1 to h5"):String(localized:"the black queen",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black queen from d8 to h4")
        case "k"?:return white ? String(localized:"the white king",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the white king from e1 to e2"):String(localized:"the black king",bundle:.checkmate,comment:"A piece by color and kind, as the object of a verb, as in: Move the black king from e8 to e7")
        default:return white ? String(localized:"the white piece",bundle:.checkmate,comment:"A piece by color, as the object of a verb, when its kind is unknown"):String(localized:"the black piece",bundle:.checkmate,comment:"A piece by color, as the object of a verb, when its kind is unknown")
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
    /// One use of a piece's name in a sentence. Each use is its own key for each kind, with its article or possessive, so a
    /// language can make the article agree with the piece's gender and put the phrase in the case its use needs.
    public enum Use:CaseIterable {
        /// "the knight" doing something in the middle of a sentence: "after the knight on e4 plays Nxf6".
        case subject
        /// "The knight" opening a sentence about it: "The knight on f3 covers e5."
        case opening
        /// "the knight" as the object of a verb: "White moved the knight from g1 to f3."
        case object
        /// "A knight", any of its kind, opening a sentence: "A knight cannot move from b1 to b3."
        case anyOpening
        /// "a knight", any of its kind, as the object of a verb: "capturing a knight".
        case anyObject
        /// "a queen", what a pawn became: "The pawn became a queen."
        case became
        /// "a queen", what a pawn promotes to: "Promotes to a queen.", "promoting to a queen".
        case promotedTo
        /// "your knight" as the subject: "Worth reviewing: your knight on f3 can be taken."
        case yoursSubject
        /// "your knight" as the object of a verb: "Try moving your knight on g1."
        case yoursObject
        /// "no queen" as the object of "have": "You have no queen."
        case noneOwned
        /// "No knight" opening a sentence: "No knight of yours can move to f6."
        case noneOpening
        /// "Knight" opening a move told by its squares: "Knight g1 to f3."
        case moveOpening
        /// "knight" after "played" in a move announcement: "Ben played knight to f3".
        case played
    }
    /// A piece by its kind (p n b r q k, either case) as one phrase for `use`: "the knight", "a queen", "your rook".
    public static func phrase(_ letter:String?,_ use:Use)->String {
        switch (use,letter?.lowercased()) {
        case (.subject,"p"?):return String(localized:"piece.subject.pawn",defaultValue:"the pawn",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,"n"?):return String(localized:"piece.subject.knight",defaultValue:"the knight",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,"b"?):return String(localized:"piece.subject.bishop",defaultValue:"the bishop",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,"r"?):return String(localized:"piece.subject.rook",defaultValue:"the rook",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,"q"?):return String(localized:"piece.subject.queen",defaultValue:"the queen",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,"k"?):return String(localized:"piece.subject.king",defaultValue:"the king",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5")
        case (.subject,_):return String(localized:"piece.subject.piece",defaultValue:"the piece",bundle:.checkmate,comment:"A piece by its kind, as the subject in the middle of a sentence, as in: after the knight on e4 plays Nxf6; From f3, the knight controls e5, when its kind is unknown")
        case (.opening,"p"?):return String(localized:"piece.opening.pawn",defaultValue:"The pawn",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,"n"?):return String(localized:"piece.opening.knight",defaultValue:"The knight",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,"b"?):return String(localized:"piece.opening.bishop",defaultValue:"The bishop",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,"r"?):return String(localized:"piece.opening.rook",defaultValue:"The rook",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,"q"?):return String(localized:"piece.opening.queen",defaultValue:"The queen",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,"k"?):return String(localized:"piece.opening.king",defaultValue:"The king",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here")
        case (.opening,_):return String(localized:"piece.opening.piece",defaultValue:"The piece",bundle:.checkmate,comment:"A piece by its kind, opening a sentence as its subject, as in: The knight on f3 covers e5; The knight cannot move from b1 to b3 here, when its kind is unknown")
        case (.object,"p"?):return String(localized:"piece.object.pawn",defaultValue:"the pawn",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,"n"?):return String(localized:"piece.object.knight",defaultValue:"the knight",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,"b"?):return String(localized:"piece.object.bishop",defaultValue:"the bishop",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,"r"?):return String(localized:"piece.object.rook",defaultValue:"the rook",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,"q"?):return String(localized:"piece.object.queen",defaultValue:"the queen",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,"k"?):return String(localized:"piece.object.king",defaultValue:"the king",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6")
        case (.object,_):return String(localized:"piece.object.piece",defaultValue:"the piece",bundle:.checkmate,comment:"A piece by its kind, as the object of a verb, as in: White moved the knight from g1 to f3; This captures the knight on f6, when its kind is unknown")
        case (.anyOpening,"p"?):return String(localized:"piece.anyOpening.pawn",defaultValue:"A pawn",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,"n"?):return String(localized:"piece.anyOpening.knight",defaultValue:"A knight",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,"b"?):return String(localized:"piece.anyOpening.bishop",defaultValue:"A bishop",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,"r"?):return String(localized:"piece.anyOpening.rook",defaultValue:"A rook",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,"q"?):return String(localized:"piece.anyOpening.queen",defaultValue:"A queen",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,"k"?):return String(localized:"piece.anyOpening.king",defaultValue:"A king",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3.")
        case (.anyOpening,_):return String(localized:"piece.anyOpening.piece",defaultValue:"A piece",bundle:.checkmate,comment:"Any piece of this kind, opening a sentence as its subject, as in: A knight cannot move from b1 to b3., when its kind is unknown")
        case (.anyObject,"p"?):return String(localized:"piece.anyObject.pawn",defaultValue:"a pawn",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,"n"?):return String(localized:"piece.anyObject.knight",defaultValue:"a knight",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,"b"?):return String(localized:"piece.anyObject.bishop",defaultValue:"a bishop",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,"r"?):return String(localized:"piece.anyObject.rook",defaultValue:"a rook",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,"q"?):return String(localized:"piece.anyObject.queen",defaultValue:"a queen",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,"k"?):return String(localized:"piece.anyObject.king",defaultValue:"a king",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight")
        case (.anyObject,_):return String(localized:"piece.anyObject.piece",defaultValue:"a piece",bundle:.checkmate,comment:"Any piece of this kind, as the object of a verb, as in: Ben played pawn to d5, capturing a knight, when its kind is unknown")
        case (.became,"p"?):return String(localized:"piece.became.pawn",defaultValue:"a pawn",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,"n"?):return String(localized:"piece.became.knight",defaultValue:"a knight",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,"b"?):return String(localized:"piece.became.bishop",defaultValue:"a bishop",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,"r"?):return String(localized:"piece.became.rook",defaultValue:"a rook",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,"q"?):return String(localized:"piece.became.queen",defaultValue:"a queen",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,"k"?):return String(localized:"piece.became.king",defaultValue:"a king",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen.")
        case (.became,_):return String(localized:"piece.became.piece",defaultValue:"a piece",bundle:.checkmate,comment:"What a pawn became when it promoted, after the verb, as in: The pawn became a queen., when its kind is unknown")
        case (.promotedTo,"p"?):return String(localized:"piece.promotedTo.pawn",defaultValue:"a pawn",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,"n"?):return String(localized:"piece.promotedTo.knight",defaultValue:"a knight",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,"b"?):return String(localized:"piece.promotedTo.bishop",defaultValue:"a bishop",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,"r"?):return String(localized:"piece.promotedTo.rook",defaultValue:"a rook",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,"q"?):return String(localized:"piece.promotedTo.queen",defaultValue:"a queen",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,"k"?):return String(localized:"piece.promotedTo.king",defaultValue:"a king",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen")
        case (.promotedTo,_):return String(localized:"piece.promotedTo.piece",defaultValue:"a piece",bundle:.checkmate,comment:"What a pawn promotes to, after the word to, as in: Promotes to a queen. Ben played pawn to e8, promoting to a queen, when its kind is unknown")
        case (.yoursSubject,"p"?):return String(localized:"piece.yoursSubject.pawn",defaultValue:"your pawn",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,"n"?):return String(localized:"piece.yoursSubject.knight",defaultValue:"your knight",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,"b"?):return String(localized:"piece.yoursSubject.bishop",defaultValue:"your bishop",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,"r"?):return String(localized:"piece.yoursSubject.rook",defaultValue:"your rook",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,"q"?):return String(localized:"piece.yoursSubject.queen",defaultValue:"your queen",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,"k"?):return String(localized:"piece.yoursSubject.king",defaultValue:"your king",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken.")
        case (.yoursSubject,_):return String(localized:"piece.yoursSubject.piece",defaultValue:"your piece",bundle:.checkmate,comment:"The learner's own piece, as the subject, as in: Worth reviewing: your knight on f3 can be taken., when its kind is unknown")
        case (.yoursObject,"p"?):return String(localized:"piece.yoursObject.pawn",defaultValue:"your pawn",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,"n"?):return String(localized:"piece.yoursObject.knight",defaultValue:"your knight",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,"b"?):return String(localized:"piece.yoursObject.bishop",defaultValue:"your bishop",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,"r"?):return String(localized:"piece.yoursObject.rook",defaultValue:"your rook",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,"q"?):return String(localized:"piece.yoursObject.queen",defaultValue:"your queen",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,"k"?):return String(localized:"piece.yoursObject.king",defaultValue:"your king",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook.")
        case (.yoursObject,_):return String(localized:"piece.yoursObject.piece",defaultValue:"your piece",bundle:.checkmate,comment:"The learner's own piece, as the object of a verb, as in: Try moving your knight on g1. The defender captured your rook., when its kind is unknown")
        case (.noneOwned,"p"?):return String(localized:"piece.noneOwned.pawn",defaultValue:"no pawn",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,"n"?):return String(localized:"piece.noneOwned.knight",defaultValue:"no knight",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,"b"?):return String(localized:"piece.noneOwned.bishop",defaultValue:"no bishop",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,"r"?):return String(localized:"piece.noneOwned.rook",defaultValue:"no rook",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,"q"?):return String(localized:"piece.noneOwned.queen",defaultValue:"no queen",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,"k"?):return String(localized:"piece.noneOwned.king",defaultValue:"no king",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there.")
        case (.noneOwned,_):return String(localized:"piece.noneOwned.piece",defaultValue:"no piece",bundle:.checkmate,comment:"No piece of this kind, as the object of the verb have, as in: You have no queen there., when its kind is unknown")
        case (.noneOpening,"p"?):return String(localized:"piece.noneOpening.pawn",defaultValue:"No pawn",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,"n"?):return String(localized:"piece.noneOpening.knight",defaultValue:"No knight",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,"b"?):return String(localized:"piece.noneOpening.bishop",defaultValue:"No bishop",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,"r"?):return String(localized:"piece.noneOpening.rook",defaultValue:"No rook",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,"q"?):return String(localized:"piece.noneOpening.queen",defaultValue:"No queen",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,"k"?):return String(localized:"piece.noneOpening.king",defaultValue:"No king",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6.")
        case (.noneOpening,_):return String(localized:"piece.noneOpening.piece",defaultValue:"No piece",bundle:.checkmate,comment:"No piece of this kind, opening a sentence as its subject, as in: No knight of yours can move to f6., when its kind is unknown")
        case (.moveOpening,"p"?):return String(localized:"piece.moveOpening.pawn",defaultValue:"Pawn",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,"n"?):return String(localized:"piece.moveOpening.knight",defaultValue:"Knight",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,"b"?):return String(localized:"piece.moveOpening.bishop",defaultValue:"Bishop",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,"r"?):return String(localized:"piece.moveOpening.rook",defaultValue:"Rook",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,"q"?):return String(localized:"piece.moveOpening.queen",defaultValue:"Queen",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,"k"?):return String(localized:"piece.moveOpening.king",defaultValue:"King",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3.")
        case (.moveOpening,_):return String(localized:"piece.moveOpening.piece",defaultValue:"Piece",bundle:.checkmate,comment:"A piece's name opening a move told by its squares, as in: Knight g1 to f3., when its kind is unknown")
        case (.played,"p"?):return String(localized:"piece.played.pawn",defaultValue:"pawn",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,"n"?):return String(localized:"piece.played.knight",defaultValue:"knight",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,"b"?):return String(localized:"piece.played.bishop",defaultValue:"bishop",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,"r"?):return String(localized:"piece.played.rook",defaultValue:"rook",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,"q"?):return String(localized:"piece.played.queen",defaultValue:"queen",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,"k"?):return String(localized:"piece.played.king",defaultValue:"king",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3")
        case (.played,_):return String(localized:"piece.played.piece",defaultValue:"piece",bundle:.checkmate,comment:"A piece's name after the verb played, in a move announcement, as in: Ben played knight to f3, when its kind is unknown")
        }
    }
    /// "the white knight" in brackets after the square it stands on, as in "the piece on e4 (the white knight)": its own key
    /// for each color and kind, apart from `the`'s object use, so a language can put each in the case its place needs.
    public static func bracketed(_ color:String?,_ letter:String?)->String {
        let white=color?.lowercased()=="w"
        switch letter?.lowercased() {
        case "p"?:return white ? String(localized:"piece.bracketed.white.pawn",defaultValue:"the white pawn",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.pawn",defaultValue:"the black pawn",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        case "n"?:return white ? String(localized:"piece.bracketed.white.knight",defaultValue:"the white knight",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.knight",defaultValue:"the black knight",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        case "b"?:return white ? String(localized:"piece.bracketed.white.bishop",defaultValue:"the white bishop",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.bishop",defaultValue:"the black bishop",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        case "r"?:return white ? String(localized:"piece.bracketed.white.rook",defaultValue:"the white rook",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.rook",defaultValue:"the black rook",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        case "q"?:return white ? String(localized:"piece.bracketed.white.queen",defaultValue:"the white queen",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.queen",defaultValue:"the black queen",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        case "k"?:return white ? String(localized:"piece.bracketed.white.king",defaultValue:"the white king",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight)."):String(localized:"piece.bracketed.black.king",defaultValue:"the black king",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight).")
        default:return white ? String(localized:"piece.bracketed.white.piece",defaultValue:"the white piece",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight). The kind is unknown."):String(localized:"piece.bracketed.black.piece",defaultValue:"the black piece",bundle:.checkmate,comment:"A piece by color and kind, in brackets after the square it stands on, as in: Select every Black piece that protects the piece on e4 (the white knight). The kind is unknown.")
        }
    }
}
