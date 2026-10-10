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
    static let haloWidth:CGFloat=0.022,focusWidth:CGFloat=0.025
    static let haloFillLow:CGFloat=0.10,haloFillHigh:CGFloat=0.18
    static let haloStrokeLow:CGFloat=0.55,haloStrokeHigh:CGFloat=0.85
    static let annotationInset:CGFloat=0.08,annotationFill:CGFloat=0.14
    static let arrowDash:[CGFloat]=[0.12,0.09]
    static let arrowSpeed:TimeInterval=0.14 // Board squares per second.
    static func arrowDashPhase(at elapsed:TimeInterval,side:CGFloat)->CGFloat {
        let cycle=Double(arrowDash.reduce(0,+))
        // A decreasing phase moves marks from the path origin toward its tip.
        return CGFloat(cycle-(max(0,elapsed)*arrowSpeed).truncatingRemainder(dividingBy:cycle))*side
    }
    static let arrowWidth:CGFloat=haloWidth,arrowOpacity:CGFloat=haloStrokeHigh
    static let sourceClearance:CGFloat=0.52
    static let endpointInset:CGFloat=0.42,headLength:CGFloat=0.11
    static let headWingRatio:CGFloat=0.55
    static let cornerRadius:CGFloat=0.20
    static let coverageOpacity:CGFloat=0.5,destinationOpacity:CGFloat=0.75
    static let pieceOutlineWidth:CGFloat = -1.5
    static func breath(at elapsed:TimeInterval)->CGFloat {
        CGFloat((1-cos(2 * .pi * elapsed/breathPeriod))/2)
    }
}

struct BoardArrow {
    let shaft:NSBezierPath,head:NSBezierPath,origin:NSPoint,tip:NSPoint
    init?(from:String,to:String,board:BoardView) {
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
        origin=NSPoint(x:source.x+ux*side*BoardOverlay.sourceClearance,y:source.y+uy*side*BoardOverlay.sourceClearance)
        tip=NSPoint(x:destination.x-vx*side*BoardOverlay.endpointInset,y:destination.y-vy*side*BoardOverlay.endpointInset)
        let available=knight ? lastLength-side*(BoardOverlay.endpointInset+BoardOverlay.cornerRadius):hypot(tip.x-origin.x,tip.y-origin.y)
        let headLength=min(side*BoardOverlay.headLength,max(0,available)),wing=headLength*BoardOverlay.headWingRatio
        let base=NSPoint(x:tip.x-vx*headLength,y:tip.y-vy*headLength)
        shaft=NSBezierPath();shaft.move(to:origin)
        if knight {
            let radius=side*BoardOverlay.cornerRadius
            let before=NSPoint(x:corner.x-ux*radius,y:corner.y-uy*radius),after=NSPoint(x:corner.x+vx*radius,y:corner.y+vy*radius)
            shaft.line(to:before);shaft.curve(to:after,controlPoint1:corner,controlPoint2:corner)
        }
        shaft.line(to:base)
        head=NSBezierPath();head.move(to:NSPoint(x:base.x-vy*wing,y:base.y+vx*wing));head.line(to:tip);head.line(to:NSPoint(x:base.x+vy*wing,y:base.y-vx*wing));head.close()
        for path in [shaft,head]{path.lineWidth=side*BoardOverlay.arrowWidth;path.lineCapStyle = .round;path.lineJoinStyle = .round}
    }
}
