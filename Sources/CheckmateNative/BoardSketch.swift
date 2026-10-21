import AppKit
import CheckmateCore

/// The learner's own arrows and circles on the board (B-11), on their own layer: a right-drag draws an arrow, a
/// right-click a circle. They belong to the board shown and only to the learner: nothing reads them, they are never
/// saved, and a move or another board clears them.
struct BoardSketch:Equatable {
    /// The colour, chosen by the modifiers held as on Lichess: none green, Shift or Control red, Option or Command blue,
    /// both groups yellow.
    enum Brush:CaseIterable {case green,red,blue,yellow
        init(modifiers:NSEvent.ModifierFlags){let a = !modifiers.intersection([.shift,.control]).isEmpty,b = !modifiers.intersection([.option,.command]).isEmpty;self=a && b ? .yellow:a ? .red:b ? .blue:.green}
        /// Bright fills read inside the dark casing every mark is drawn with (BoardPalette.sketchCasing).
        var color:NSColor {switch self{case .green:return BoardPalette.sketchGreen;case .red:return BoardPalette.sketchRed;case .blue:return BoardPalette.sketchBlue;case .yellow:return BoardPalette.sketchYellow}}
    }
    /// An arrow, or a circle when `from` and `to` are the same square.
    struct Mark:Equatable {let from:String,to:String,brush:Brush;var circle:Bool {from==to}}
    private(set) var marks:[Mark]=[]
    /// Drawing a mark that is already there removes it; drawing it in another colour recolours it.
    mutating func toggle(_ mark:Mark){
        if let index=marks.firstIndex(where:{$0.from==mark.from && $0.to==mark.to}){let old=marks.remove(at:index);if old.brush==mark.brush{return};marks.insert(mark,at:index)}else{marks.append(mark)}
    }
    mutating func clear(){if !marks.isEmpty{marks=[]}}
    /// The board's marks: arrows use the board's arrow geometry, so they clear the pieces they join as its arrows do.
    static func draw(_ marks:[Mark],on board:BoardView,side s:CGFloat){
        for mark in marks {
            let casing=s*BoardOverlay.sketchWidth+s*BoardOverlay.sketchCasing*2
            if mark.circle {
                let ring=NSBezierPath(ovalIn:board.squareRect(mark.from).insetBy(dx:s*BoardOverlay.sketchCircleInset,dy:s*BoardOverlay.sketchCircleInset))
                ring.lineWidth=casing;BoardPalette.sketchCasing.setStroke();ring.stroke();ring.lineWidth=s*BoardOverlay.sketchWidth;mark.brush.color.setStroke();ring.stroke()
            } else if let arrow=BoardArrow(from:mark.from,to:mark.to,board:board) {
                for (width,color) in [(casing,BoardPalette.sketchCasing),(s*BoardOverlay.sketchWidth,mark.brush.color)] {arrow.shaft.lineWidth=width;arrow.head.lineWidth=width;color.setStroke();color.setFill();arrow.shaft.stroke();arrow.head.fill();arrow.head.stroke()}
            }
        }
    }
}
