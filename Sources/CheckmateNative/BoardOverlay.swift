import AppKit
import CheckmateCore

// Board-relative visual tokens keep overlays consistent as the board resizes.
enum BoardOverlay {
    static let relationshipWidth:CGFloat=0.025,relationshipOpacity:CGFloat=1
    static let relationshipCurve:CGFloat=0.12,relationshipInset:CGFloat=0.31
    static let relationshipDash:[CGFloat]=[0.08,0.06]
    static let breathPeriod:TimeInterval=2.8
    static let refreshInterval:TimeInterval=1.0/30
    static let haloInset:CGFloat=0.10,haloExpansion:CGFloat=0.025
    static let haloWidth:CGFloat=0.022
    static let haloFillLow:CGFloat=0.10,haloFillHigh:CGFloat=0.18
    static let haloStrokeLow:CGFloat=0.55,haloStrokeHigh:CGFloat=0.85
    static let annotationInset:CGFloat=0.08,annotationFill:CGFloat=0.14
    /// The check glow's strength at the king's square centre, and the last move's tint (B-15).
    static let checkGlow:CGFloat=0.5,lastMoveTint:CGFloat=0.45
    static let arrowDash:[CGFloat]=[0.12,0.09]
    static let arrowSpeed:TimeInterval=0.14 // Board squares per second.
    static func arrowDashPhase(at elapsed:TimeInterval,side:CGFloat)->CGFloat {
        let cycle=Double(arrowDash.reduce(0,+))
        // A decreasing phase moves marks from the path origin toward its tip.
        return CGFloat(cycle-(max(0,elapsed)*arrowSpeed).truncatingRemainder(dividingBy:cycle))*side
    }
    static let arrowWidth:CGFloat=haloWidth,arrowOpacity:CGFloat=haloStrokeHigh
    /// An arrow clears the pieces drawn over it: it leaves an occupied source square (0.52) and stops before an occupied
    /// target's piece (0.42). An empty source needs no clearance; on an empty target the tip reaches nearly to the centre.
    static let sourceClearance:CGFloat=0.52
    static let endpointInset:CGFloat=0.42,emptyTargetInset:CGFloat=0.15,headLength:CGFloat=0.11
    /// Clearances shrink, never below this visible length, so a one-square arrow keeps a shaft and a whole head.
    static let minimumArrowSpan:CGFloat=0.25
    static let headWingRatio:CGFloat=0.55
    static let cornerRadius:CGFloat=0.20
    static let coverageOpacity:CGFloat=0.5,destinationOpacity:CGFloat=0.75,dragOriginOpacity:CGFloat=0.3
    static let pieceOutlineWidth:CGFloat = -1.5
    /// The learner's own marks (B-11): a bold stroke inside a thin dark casing, and a circle just inside its square.
    static let sketchWidth:CGFloat=0.07,sketchCasing:CGFloat=0.012,sketchCircleInset:CGFloat=0.07
    static func breath(at elapsed:TimeInterval)->CGFloat {
        CGFloat((1-cos(2 * .pi * elapsed/breathPeriod))/2)
    }
}

struct BoardArrow {
    /// Empty squares where one arrow ends and another, not its reverse, starts: turns in a single route. An occupied
    /// square there is two relations meeting at a piece (an attack on it, a defence of it), drawn as separate arrows.
    static func joints(_ arrows:[[String]],position:[String:String])->Set<String> {
        Set(arrows.filter{$0.count==2}.compactMap{a in position[a[1]]==nil && arrows.contains{$0.count==2 && $0[0]==a[1] && $0[1] != a[0]} ? a[1]:nil})
    }
    let shaft:NSBezierPath,head:NSBezierPath,origin:NSPoint,tip:NSPoint
    /// `through`: the arrow is the first leg of a route that continues from its empty target square, so it runs into the
    /// square's centre with no head, and the next leg starts there.
    init?(from:String,to:String,board:BoardView,through:Bool=false) {
        guard ChessRules.validSquare(from),ChessRules.validSquare(to),from != to else{return nil}
        let a=board.squareRect(from),b=board.squareRect(to),side=a.width
        guard side>0 else{return nil}
        let source=NSPoint(x:a.midX,y:a.midY),destination=NSPoint(x:b.midX,y:b.midY)
        let dx=destination.x-source.x,dy=destination.y-source.y
        let knight=(abs(abs(dx/side)-1)<0.01 && abs(abs(dy/side)-2)<0.01) || (abs(abs(dx/side)-2)<0.01 && abs(abs(dy/side)-1)<0.01)
        let corner=abs(dx)>abs(dy) ? NSPoint(x:destination.x,y:source.y):NSPoint(x:source.x,y:destination.y)
        let first=knight ? corner:destination,last=knight ? corner:source
        let firstLength=hypot(first.x-source.x,first.y-source.y),lastLength=hypot(destination.x-last.x,destination.y-last.y)
        let ux=(first.x-source.x)/firstLength,uy=(first.y-source.y)/firstLength
        let vx=(destination.x-last.x)/lastLength,vy=(destination.y-last.y)/lastLength
        var start=board.position[from]==nil ? 0:BoardOverlay.sourceClearance
        var end=through ? 0:board.position[to]==nil ? BoardOverlay.emptyTargetInset:BoardOverlay.endpointInset
        // The straight run the clearances share: the whole arrow, or a knight route's final leg (its turn takes the rest).
        let run=knight ? lastLength/side-BoardOverlay.cornerRadius:hypot(dx,dy)/side,clear=(knight ? 0:start)+end
        if clear>0,run-clear<BoardOverlay.minimumArrowSpan {let scale=max(0,run-BoardOverlay.minimumArrowSpan)/clear;start*=knight ? 1:scale;end*=scale}
        origin=NSPoint(x:source.x+ux*side*start,y:source.y+uy*side*start)
        tip=NSPoint(x:destination.x-vx*side*end,y:destination.y-vy*side*end)
        let available=knight ? lastLength-side*(end+BoardOverlay.cornerRadius):hypot(tip.x-origin.x,tip.y-origin.y)
        let headLength=through ? 0:min(side*BoardOverlay.headLength,max(0,available)),wing=headLength*BoardOverlay.headWingRatio
        let base=NSPoint(x:tip.x-vx*headLength,y:tip.y-vy*headLength)
        shaft=NSBezierPath();shaft.move(to:origin)
        if knight {
            let radius=side*BoardOverlay.cornerRadius
            let before=NSPoint(x:corner.x-ux*radius,y:corner.y-uy*radius),after=NSPoint(x:corner.x+vx*radius,y:corner.y+vy*radius)
            shaft.line(to:before);shaft.curve(to:after,controlPoint1:corner,controlPoint2:corner)
        }
        shaft.line(to:base)
        head=NSBezierPath();if !through{head.move(to:NSPoint(x:base.x-vy*wing,y:base.y+vx*wing));head.line(to:tip);head.line(to:NSPoint(x:base.x+vy*wing,y:base.y-vx*wing));head.close()}
        for path in [shaft,head]{path.lineWidth=side*BoardOverlay.arrowWidth;path.lineCapStyle = .round;path.lineJoinStyle = .round}
    }
}
