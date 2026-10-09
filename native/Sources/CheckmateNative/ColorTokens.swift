import AppKit

// App chrome follows macOS appearance, accent and accessibility preferences.
enum NativeColors {
    static var windowBackground:NSColor { .windowBackgroundColor }
    static var secondaryText:NSColor { .secondaryLabelColor }
    static var error:NSColor { .systemRed }
    static var success:NSColor { .systemGreen }
    static var playbackAccents:[NSColor] { [.systemTeal,.systemGreen,.systemOrange,.systemPurple] }
}

// The board is a themed surface, so its marks need contrast against both squares,
// independent of the system accent or the surrounding light/dark window.
struct BoardPalette {
    let lightSquare:NSColor,darkSquare:NSColor,ink:NSColor,protection:NSColor,danger:NSColor
    static let lightPiece=NSColor.white,darkPiece=NSColor.black,pieceOutline=NSColor.black
    private static func rgb(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->NSColor {NSColor(srgbRed:r,green:g,blue:b,alpha:1)}
    static func theme(_ name:String)->BoardPalette {
        switch name {
        case "green":return BoardPalette(lightSquare:rgb(0.933,0.933,0.824),darkSquare:rgb(0.463,0.588,0.337),ink:rgb(0.14,0.23,0.12),protection:rgb(0.08,0.23,0.17),danger:rgb(0.35,0.10,0.09))
        case "blue":return BoardPalette(lightSquare:rgb(0.871,0.89,0.902),darkSquare:rgb(0.471,0.561,0.616),ink:rgb(0.15,0.22,0.27),protection:rgb(0.08,0.23,0.21),danger:rgb(0.35,0.10,0.15))
        case "neutral":return BoardPalette(lightSquare:rgb(0.898,0.898,0.898),darkSquare:rgb(0.549,0.549,0.549),ink:rgb(0.20,0.20,0.20),protection:rgb(0.10,0.23,0.18),danger:rgb(0.35,0.12,0.12))
        default:return BoardPalette(lightSquare:rgb(0.91,0.824,0.682),darkSquare:rgb(0.647,0.467,0.314),ink:rgb(0.23,0.14,0.08),protection:rgb(0.10,0.23,0.15),danger:rgb(0.35,0.10,0.08))
        }
    }
}
