import AppKit

// App chrome follows macOS appearance, accent and accessibility preferences.
enum NativeColors {
    static var windowBackground:NSColor { .windowBackgroundColor }
    static var secondaryText:NSColor { .secondaryLabelColor }
    static var error:NSColor { .systemRed }
    static var success:NSColor { .systemGreen }
}

// The board is a themed surface, so its marks need contrast against both squares,
// independent of the system accent or the surrounding light/dark window.
struct BoardPalette {
    let lightSquare:NSColor,darkSquare:NSColor,ink:NSColor,protection:NSColor,danger:NSColor
    static let lightPiece=NSColor.white,darkPiece=NSColor.black,pieceOutline=NSColor.black
    /// Check's glow, its ring and the last move's tint are the same in every theme; BoardPlayTests checks their
    /// contrast against each theme's squares (B-15).
    static let check=rgb(1.0,0.15,0.10),checkRing=rgb(0.30,0.02,0.02),lastMove=rgb(1.0,0.84,0.18)
    private static func rgb(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->NSColor {NSColor(srgbRed:r,green:g,blue:b,alpha:1)}
    /// `dark` dims the bright squares for a dark window; marks keep their contrast on both squares (D-36).
    static func theme(_ name:String,dark:Bool=false)->BoardPalette {
        let p=light(name);guard dark else{return p}
        let dim=p.lightSquare.usingColorSpace(.sRGB)!
        return BoardPalette(lightSquare:rgb(dim.redComponent*0.85,dim.greenComponent*0.85,dim.blueComponent*0.85),darkSquare:p.darkSquare,ink:p.ink,protection:p.protection,danger:p.danger)
    }
    private static func light(_ name:String)->BoardPalette {
        switch name {
        case "green":return BoardPalette(lightSquare:rgb(0.933,0.933,0.824),darkSquare:rgb(0.463,0.588,0.337),ink:rgb(0.14,0.23,0.12),protection:rgb(0.08,0.23,0.17),danger:rgb(0.35,0.10,0.09))
        case "blue":return BoardPalette(lightSquare:rgb(0.871,0.89,0.902),darkSquare:rgb(0.471,0.561,0.616),ink:rgb(0.15,0.22,0.27),protection:rgb(0.08,0.23,0.21),danger:rgb(0.35,0.10,0.15))
        case "neutral":return BoardPalette(lightSquare:rgb(0.898,0.898,0.898),darkSquare:rgb(0.549,0.549,0.549),ink:rgb(0.20,0.20,0.20),protection:rgb(0.10,0.23,0.18),danger:rgb(0.35,0.12,0.12))
        default:return BoardPalette(lightSquare:rgb(0.91,0.824,0.682),darkSquare:rgb(0.647,0.467,0.314),ink:rgb(0.23,0.14,0.08),protection:rgb(0.10,0.23,0.15),danger:rgb(0.35,0.10,0.08))
        }
    }
}
