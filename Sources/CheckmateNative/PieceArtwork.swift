import AppKit

// Piece artwork: Copyright (c) Cburnett. BSD 3-Clause License; the full text and provenance are in
// Artwork/Upstream/cburnett-pieces (LICENSE.txt, source.json) and the app bundles it as Licenses/cburnett-pieces.txt.
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
// conditions in that license are met. THIS SOFTWARE IS PROVIDED BY CBURNETT "AS IS" AND ANY EXPRESS OR IMPLIED
// WARRANTIES ARE DISCLAIMED.

/// The board's vector pieces (B-16): Cburnett's set, transcribed path for path from the committed SVGs (PieceArtworkTests
/// holds the two together) and drawn natively, so they stay sharp at any square size and take the board palette's piece
/// colours. A piece the set does not cover is drawn with its glyph, as the board drew every piece before.
enum PieceArtwork {
    enum Ink:Equatable {case white,black}
    /// One SVG path element: its path data, paint and optional affine transform (a,b,c,d,e,f), in the artwork's 45-unit
    /// box with y downwards.
    struct Shape:Equatable {
        let d:String,fill:Ink?,stroke:Ink?,width:CGFloat,cap:NSBezierPath.LineCapStyle,join:NSBezierPath.LineJoinStyle,evenOdd:Bool,transform:[CGFloat]?
        init(_ d:String,fill:Ink?,stroke:Ink?,width:CGFloat=1,cap:NSBezierPath.LineCapStyle = .butt,join:NSBezierPath.LineJoinStyle = .miter,evenOdd:Bool=false,transform:[CGFloat]?=nil){self.d=d;self.fill=fill;self.stroke=stroke;self.width=width;self.cap=cap;self.join=join;self.evenOdd=evenOdd;self.transform=transform}
    }
    enum Segment:Equatable {case move(CGPoint),line(CGPoint),curve(CGPoint,CGPoint,CGPoint),close}
    static let box:CGFloat=45

    /// Path data to segments in artwork space, with the transform applied; arcs become cubic curves (SVG 1.1, F.6.5).
    /// Only the commands the set uses (absolute M, L, C, A and Z) are read; anything else is refused rather than guessed.
    static func segments(_ d:String,transform t:[CGFloat]?)->[Segment]? {
        var tokens:[Substring]=[],i=d.startIndex
        while i<d.endIndex {let c=d[i]
            if c.isLetter {tokens.append(d[i...i]);i=d.index(after:i);continue}
            if c==" " || c=="," || c.isNewline || c=="\t" {i=d.index(after:i);continue}
            var j=i,dot=false;if c=="-" || c=="+" {j=d.index(after:j)}
            while j<d.endIndex,d[j].isNumber || (d[j]=="." && !dot) {if d[j]=="."{dot=true};j=d.index(after:j)}
            if j<d.endIndex,d[j]=="e" || d[j]=="E" {var k=d.index(after:j);if k<d.endIndex,d[k]=="-" || d[k]=="+" {k=d.index(after:k)};while k<d.endIndex,d[k].isNumber{k=d.index(after:k)};j=k}
            guard j>i,Double(d[i..<j]) != nil else{return nil};tokens.append(d[i..<j]);i=j
        }
        func map(_ p:CGPoint)->CGPoint {guard let t,t.count==6 else{return p};return CGPoint(x:t[0]*p.x+t[2]*p.y+t[4],y:t[1]*p.x+t[3]*p.y+t[5])}
        var out:[Segment]=[],k=0,command:Character="?",current=CGPoint.zero,start=CGPoint.zero
        func numbers(_ n:Int)->[CGFloat]? {guard k+n<=tokens.count else{return nil};var v:[CGFloat]=[];for token in tokens[k..<k+n]{guard let x=Double(token) else{return nil};v.append(CGFloat(x))};k+=n;return v}
        while k<tokens.count {
            if let c=tokens[k].first,c.isLetter {command=c;k+=1} else if command=="M" {command="L"}
            switch command {
            case "M": guard let v=numbers(2) else{return nil};current=CGPoint(x:v[0],y:v[1]);start=current;out.append(.move(map(current)))
            case "L": guard let v=numbers(2) else{return nil};current=CGPoint(x:v[0],y:v[1]);out.append(.line(map(current)))
            case "C": guard let v=numbers(6) else{return nil};current=CGPoint(x:v[4],y:v[5]);out.append(.curve(map(CGPoint(x:v[0],y:v[1])),map(CGPoint(x:v[2],y:v[3])),map(current)))
            case "A": guard let v=numbers(7) else{return nil};let end=CGPoint(x:v[5],y:v[6])
                out+=arc(from:current,to:end,rx:v[0],ry:v[1],degrees:v[2],large:v[3] != 0,sweep:v[4] != 0).map{c in .curve(map(c.0),map(c.1),map(c.2))};current=end
            case "Z","z": out.append(.close);current=start
            default: return nil
            }
        }
        return out
    }
    /// An elliptical arc as cubic curves of at most a quarter turn each.
    private static func arc(from p1:CGPoint,to p2:CGPoint,rx:CGFloat,ry:CGFloat,degrees:CGFloat,large:Bool,sweep:Bool)->[(CGPoint,CGPoint,CGPoint)] {
        var rx=abs(rx),ry=abs(ry);guard p1 != p2 else{return []};guard rx>0,ry>0 else{return [(p1,p2,p2)]}
        let phi=degrees * .pi/180,cosPhi=cos(phi),sinPhi=sin(phi),dx=(p1.x-p2.x)/2,dy=(p1.y-p2.y)/2
        let x1=cosPhi*dx+sinPhi*dy,y1 = -sinPhi*dx+cosPhi*dy,lambda=x1*x1/(rx*rx)+y1*y1/(ry*ry)
        if lambda>1 {rx*=sqrt(lambda);ry*=sqrt(lambda)}
        let numerator=rx*rx*ry*ry-rx*rx*y1*y1-ry*ry*x1*x1,denominator=rx*rx*y1*y1+ry*ry*x1*x1
        let coef=(large==sweep ? -1:1)*sqrt(max(0,numerator/denominator)),cx1=coef*rx*y1/ry,cy1 = -coef*ry*x1/rx
        let cx=cosPhi*cx1-sinPhi*cy1+(p1.x+p2.x)/2,cy=sinPhi*cx1+cosPhi*cy1+(p1.y+p2.y)/2
        let theta=atan2((y1-cy1)/ry,(x1-cx1)/rx);var delta=atan2((-y1-cy1)/ry,(-x1-cx1)/rx)-theta
        if sweep && delta<0 {delta+=2 * .pi} else if !sweep && delta>0 {delta-=2 * .pi}
        let count=max(1,Int((abs(delta)/(.pi/2)-1e-9).rounded(.up))),step=delta/CGFloat(count),handle=4/3*tan(step/4)
        func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {CGPoint(x:cx+rx*cosPhi*x-ry*sinPhi*y,y:cy+rx*sinPhi*x+ry*cosPhi*y)}
        return (0..<count).map{n in let a=theta+step*CGFloat(n),b=a+step
            return (point(cos(a)-handle*sin(a),sin(a)+handle*cos(a)),point(cos(b)+handle*sin(b),sin(b)-handle*cos(b)),n==count-1 ? p2:point(cos(b),sin(b)))}
    }
    /// Every piece's shapes with their segments, read once. A piece with any unreadable path is left out whole, so it
    /// falls back to its glyph rather than drawing with a part missing.
    private static let parsed:[String:[(shape:Shape,segments:[Segment])]]=shapes.compactMapValues{list in
        var out:[(shape:Shape,segments:[Segment])]=[];for shape in list {guard let s=segments(shape.d,transform:shape.transform) else{return nil};out.append((shape,s))};return out}

    /// Draws `piece` ("wk", "bp"...) to fill `rect`; `alpha` fades it as one piece. Falls back to the glyph.
    static func draw(_ piece:String,in rect:NSRect,alpha:CGFloat=1){
        guard let shapes=parsed[piece],let context=NSGraphicsContext.current else{glyph(piece,rect:rect,alpha:alpha);return}
        let scale=rect.width/box,flipped=context.isFlipped
        func map(_ p:CGPoint)->NSPoint {NSPoint(x:rect.minX+p.x*scale,y:flipped ? rect.minY+p.y*scale:rect.maxY-p.y*scale)}
        let cg=context.cgContext,fading=alpha<1;if fading{cg.saveGState();cg.setAlpha(alpha);cg.beginTransparencyLayer(auxiliaryInfo:nil)}
        for (shape,segments) in shapes {
            let path=NSBezierPath()
            for segment in segments {switch segment{case .move(let p):path.move(to:map(p));case .line(let p):path.line(to:map(p));case .curve(let a,let b,let p):path.curve(to:map(p),controlPoint1:map(a),controlPoint2:map(b));case .close:path.close()}}
            if let fill=shape.fill {path.windingRule=shape.evenOdd ? .evenOdd:.nonZero;(fill == .white ? BoardPalette.lightPiece:BoardPalette.darkPiece).setFill();path.fill()}
            if let stroke=shape.stroke {path.lineWidth=shape.width*scale;path.lineCapStyle=shape.cap;path.lineJoinStyle=shape.join;(stroke == .white ? BoardPalette.lightPiece:BoardPalette.pieceOutline).setStroke();path.stroke()}
        }
        if fading{cg.endTransparencyLayer();cg.restoreGState()}
    }
    /// A piece as a small image, for rows of captured pieces.
    static func image(_ piece:String,side:CGFloat)->NSImage {NSImage(size:NSSize(width:side,height:side),flipped:false){rect in draw(piece,in:rect);return true}}
    /// The font glyph the board drew before the vector set, kept for any piece without artwork.
    private static func glyph(_ piece:String,rect:NSRect,alpha:CGFloat){let symbols=["k":"♚","q":"♛","r":"♜","b":"♝","n":"♞","p":"♟"],white=piece.first=="w",size=rect.width*0.8
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Arial Unicode MS",size:size) ?? NSFont.systemFont(ofSize:size),.foregroundColor:(white ? BoardPalette.lightPiece:BoardPalette.darkPiece).withAlphaComponent(alpha),.strokeColor:BoardPalette.pieceOutline.withAlphaComponent(alpha),.strokeWidth:white ? BoardOverlay.pieceOutlineWidth:0]
        let value=symbols[String(piece.suffix(1)),default:"♟"] as NSString,s=value.size(withAttributes:attrs);value.draw(at:NSPoint(x:rect.midX-s.width/2,y:rect.midY-s.height/2),withAttributes:attrs)
    }

    /// Transcribed from Artwork/Upstream/cburnett-pieces/Chess_<piece><l|d>t45.svg, path elements in document order.
    static let shapes:[String:[Shape]]=[
        "wk":[
            Shape("M 22.5,11.625 L 22.5,6",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 22.5,25 C 22.5,25 27,17.5 25.5,14.5 C 25.5,14.5 24.5,12 22.5,12 C 20.5,12 19.5,14.5 19.5,14.5 C 18,17.5 22.5,25 22.5,25",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.miter,evenOdd:true),
            Shape("M 11.5,37 C 17,40.5 27,40.5 32.5,37 L 32.5,30 C 32.5,30 41.5,25.5 38.5,19.5 C 34.5,13 25,16 22.5,23.5 L 22.5,27 L 22.5,23.5 C 19,16 9.5,13 6.5,19.5 C 3.5,25.5 11.5,29.5 11.5,29.5 L 11.5,37 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,evenOdd:true),
            Shape("M 20,8 L 25,8",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 11.5,29.5 C 17,27 27,27 32.5,30",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 11.5,37 C 17,34.5 27,34.5 32.5,37",fill:nil,stroke:.black,width:1.5,cap:.round,join:.round),
            Shape("M 11.5,33.5 C 17,31.5 27,31.5 32.5,33.5",fill:nil,stroke:.black,width:1.5,cap:.round,join:.round)],
        "wq":[
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,-1,-1]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,15.5,-5.5]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,32,-1]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,7,-4.5]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,24,-4]),
            Shape("M 9,26 C 17.5,24.5 30,24.5 36,26 L 38,14 L 31,25 L 31,11 L 25.5,24.5 L 22.5,9.5 L 19.5,24.5 L 14,10.5 L 14,25 L 7,14 L 9,26 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 9,26 C 9,28 10.5,28 11.5,30 C 12.5,31.5 12.5,31 12,33.5 C 10.5,34.5 10.5,36 10.5,36 C 9,37.5 11,38.5 11,38.5 C 17.5,39.5 27.5,39.5 34,38.5 C 34,38.5 35.5,37.5 34,36 C 34,36 34.5,34.5 33,33.5 C 32.5,31 32.5,31.5 33.5,30 C 34.5,28 36,28 36,26 C 27.5,24.5 17.5,24.5 9,26 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 11.5,30 C 15,29 30,29 33.5,30",fill:nil,stroke:.black,width:1,cap:.round,join:.round),
            Shape("M 12,33.5 C 18,32.5 27,32.5 33,33.5",fill:nil,stroke:.black,width:1,cap:.round,join:.round),
            Shape("M 10.5,36 C 15.5,35 29,35 34,36",fill:nil,stroke:.black,width:1,cap:.round,join:.round)],
        "wr":[
            Shape("M 9,39 L 36,39 L 36,36 L 9,36 L 9,39 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 12,36 L 12,32 L 33,32 L 33,36 L 12,36 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 11,14 L 11,9 L 15,9 L 15,11 L 20,11 L 20,9 L 25,9 L 25,11 L 30,11 L 30,9 L 34,9 L 34,14",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 34,14 L 31,17 L 14,17 L 11,14",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,evenOdd:true),
            Shape("M 31,17 L 31,29.500018 L 14,29.500018 L 14,17",fill:.white,stroke:.black,width:1.50000036,cap:.butt,join:.miter,evenOdd:true),
            Shape("M 31,29.5 L 32.5,32 L 12.5,32 L 14,29.5",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,evenOdd:true),
            Shape("M 11,14 L 34,14",fill:nil,stroke:.black,width:1,cap:.round,join:.miter)],
        "wb":[
            Shape("M 9,36 C 12.385255,35.027671 19.114744,36.430821 22.5,34 C 25.885256,36.430821 32.614745,35.027671 36,36 C 36,36 37.645898,36.541507 39,38 C 38.322949,38.972328 37.354102,38.986164 36,38.5 C 32.614745,37.527672 25.885256,38.958493 22.5,37.5 C 19.114744,38.958493 12.385255,37.527672 9,38.5 C 7.6458978,38.986164 6.6770511,38.972328 6,38 C 7.3541023,36.055343 9,36 9,36 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 15,32 C 17.5,34.5 27.5,34.5 30,32 C 30.5,30.5 30,30 30,30 C 30,27.5 27.5,26 27.5,26 C 33,24.5 33.5,14.5 22.5,10.5 C 11.5,14.5 12,24.5 17.5,26 C 17.5,26 15,27.5 15,30 C 15,30 14.5,30.5 15,32 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 25 10 A 2.5 2.5 0 1 1 20,10 A 2.5 2.5 0 1 1 25 10 z",fill:.white,stroke:.black,width:1.5,cap:.butt,join:.round,transform:[1,0,0,1,0,-2]),
            Shape("M 17.5,26 L 27.5,26",fill:nil,stroke:.black,width:1.5,cap:.butt,join:.miter),
            Shape("M 15,30 L 30,30",fill:nil,stroke:.black,width:1.5,cap:.butt,join:.miter),
            Shape("M 22.5,15.5 L 22.5,20.5",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 20,18 L 25,18",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter)],
        "wn":[
            Shape("M 22,10 C 32.5,11 38.5,18 38,39 L 15,39 C 15,30 25,32.5 23,18",fill:.white,stroke:.black,width:1.5,cap:.round,join:.miter,evenOdd:true),
            Shape("M 24,18 C 24.384461,20.911278 18.447064,25.368624 16,27 C 13,29 13.180802,31.342892 11,31 C 9.95828,30.055984 12.413429,27.962451 11,28 C 10,28 11.187332,29.231727 10,30 C 9,30 5.9968392,30.999999 6,26 C 6,24 12,14 12,14 C 12,14 13.885866,12.097871 14,10.5 C 13.273953,9.505631 13.5,8.5 13.5,7.5 C 14.5,6.5 16.5,10 16.5,10 L 18.5,10 C 18.5,10 19.281781,8.0080745 21,7 C 22,7 22,10 22,10",fill:.white,stroke:.black,width:1.5,cap:.round,join:.round,evenOdd:true),
            Shape("M 9 23.5 A 0.5 0.5 0 1 1 8,23.5 A 0.5 0.5 0 1 1 9 23.5 z",fill:.black,stroke:.black,width:1.5,cap:.round,join:.round,transform:[1,0,0,1,0.5,2]),
            Shape("M 15 15.5 A 0.5 1.5 0 1 1 14,15.5 A 0.5 1.5 0 1 1 15 15.5 z",fill:.black,stroke:.black,width:1.50000052,cap:.round,join:.round,transform:[0.866025,0.5,-0.5,0.866025,9.692632,-5.173394]),
            Shape("M 37,39 C 38,19 31.5,11.5 25,10.5",fill:nil,stroke:.black,width:1,cap:.round,join:.miter)],
        "wp":[
            Shape("M 22 9 C 19.792 9 18 10.792 18 13 C 18 13.885103 18.29397 14.712226 18.78125 15.375 C 16.829274 16.496917 15.5 18.588492 15.5 21 C 15.5 23.033947 16.442042 24.839082 17.90625 26.03125 C 14.907101 27.08912 10.5 31.578049 10.5 39.5 L 33.5 39.5 C 33.5 31.578049 29.092899 27.08912 26.09375 26.03125 C 27.557958 24.839082 28.5 23.033948 28.5 21 C 28.5 18.588492 27.170726 16.496917 25.21875 15.375 C 25.70603 14.712226 26 13.885103 26 13 C 26 10.792 24.208 9 22 9 z",fill:.white,stroke:.black,width:1.5,cap:.round,join:.miter)],
        "bk":[
            Shape("M 22.5,11.625 L 22.5,6",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 22.5,25 C 22.5,25 27,17.5 25.5,14.5 C 25.5,14.5 24.5,12 22.5,12 C 20.5,12 19.5,14.5 19.5,14.5 C 18,17.5 22.5,25 22.5,25",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.miter,evenOdd:true),
            Shape("M 11.5,37 C 17,40.5 27,40.5 32.5,37 L 32.5,30 C 32.5,30 41.5,25.5 38.5,19.5 C 34.5,13 25,16 22.5,23.5 L 22.5,27 L 22.5,23.5 C 19,16 9.5,13 6.5,19.5 C 3.5,25.5 11.5,29.5 11.5,29.5 L 11.5,37 z",fill:.black,stroke:.black,width:1.5,cap:.round,join:.round,evenOdd:true),
            Shape("M 20,8 L 25,8",fill:nil,stroke:.black,width:1.5,cap:.round,join:.miter),
            Shape("M 11.5,29.5 C 17,27 27,27 32.5,30",fill:nil,stroke:.white,width:1.5,cap:.round,join:.miter),
            Shape("M 11.5,37 C 17,34.5 27,34.5 32.5,37",fill:nil,stroke:.white,width:1.5,cap:.round,join:.round),
            Shape("M 11.5,33.5 C 17,31.5 27,31.5 32.5,33.5",fill:nil,stroke:.white,width:1.5,cap:.round,join:.round),
            Shape("M 32,29.5 C 32,29.5 40.5,25.5 38.025969,19.846552 C 34.147406,13.996552 25,18 22.5,24.5 L 22.511718,26.596552 L 22.5,24.5 C 20,18 9.9063892,13.996552 6.9974672,19.846552 C 4.5,25.5 11.845671,28.846552 11.845671,28.846552",fill:nil,stroke:.white,width:1.5,cap:.round,join:.round)],
        "bq":[
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.black,stroke:.black,width:1,cap:.round,join:.round,transform:[1,0,0,1,-1,-1]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.black,stroke:.black,width:1,cap:.round,join:.round,transform:[1,0,0,1,15.5,-5.5]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.black,stroke:.black,width:1,cap:.round,join:.round,transform:[1,0,0,1,32,-1]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.black,stroke:.black,width:1,cap:.round,join:.round,transform:[1,0,0,1,7,-4.5]),
            Shape("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",fill:.black,stroke:.black,width:1,cap:.round,join:.round,transform:[1,0,0,1,24,-4]),
            Shape("M 9,26 C 17.5,24.5 30,24.5 36,26 L 38,14 L 31,25 L 31,11 L 25.5,24.5 L 22.5,9.5 L 19.5,24.5 L 14,10.5 L 14,25 L 7,14 L 9,26 z",fill:.black,stroke:.black,width:1,cap:.butt,join:.round,evenOdd:true),
            Shape("M 9,26 C 9,28 10.5,28 11.5,30 C 12.5,31.5 12.5,31 12,33.5 C 10.5,34.5 10.5,36 10.5,36 C 9,37.5 11,38.5 11,38.5 C 17.5,39.5 27.5,39.5 34,38.5 C 34,38.5 35.5,37.5 34,36 C 34,36 34.5,34.5 33,33.5 C 32.5,31 32.5,31.5 33.5,30 C 34.5,28 36,28 36,26 C 27.5,24.5 17.5,24.5 9,26 z",fill:.black,stroke:.black,width:1,cap:.butt,join:.round,evenOdd:true),
            Shape("M 11.5,30 C 15,29 30,29 33.5,30",fill:nil,stroke:.white,width:1,cap:.round,join:.round),
            Shape("M 12,33.5 C 18,32.5 27,32.5 33,33.5",fill:nil,stroke:.white,width:1,cap:.round,join:.round),
            Shape("M 10.5,36 C 15.5,35 29,35 34,36",fill:nil,stroke:.white,width:1,cap:.round,join:.round)],
        "br":[
            Shape("M 9,39 L 36,39 L 36,36 L 9,36 L 9,39 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 12.5,32 L 14,29.5 L 31,29.5 L 32.5,32 L 12.5,32 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 12,36 L 12,32 L 33,32 L 33,36 L 12,36 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 14,29.5 L 14,16.5 L 31,16.5 L 31,29.5 L 14,29.5 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.miter,evenOdd:true),
            Shape("M 14,16.5 L 11,14 L 34,14 L 31,16.5 L 14,16.5 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 11,14 L 11,9 L 15,9 L 15,11 L 20,11 L 20,9 L 25,9 L 25,11 L 30,11 L 30,9 L 34,9 L 34,14 L 11,14 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 12,35.5 L 33,35.5 L 33,35.5",fill:nil,stroke:.white,width:1,cap:.round,join:.miter),
            Shape("M 13,31.5 L 32,31.5",fill:nil,stroke:.white,width:1,cap:.round,join:.miter),
            Shape("M 14,29.5 L 31,29.5",fill:nil,stroke:.white,width:1,cap:.round,join:.miter),
            Shape("M 14,16.5 L 31,16.5",fill:nil,stroke:.white,width:1,cap:.round,join:.miter),
            Shape("M 11,14 L 34,14",fill:nil,stroke:.white,width:1,cap:.round,join:.miter)],
        "bb":[
            Shape("M 9,36 C 12.385255,35.027671 19.114744,36.430821 22.5,34 C 25.885256,36.430821 32.614745,35.027671 36,36 C 36,36 37.645898,36.541507 39,38 C 38.322949,38.972328 37.354102,38.986164 36,38.5 C 32.614745,37.527672 25.885256,38.958493 22.5,37.5 C 19.114744,38.958493 12.385255,37.527672 9,38.5 C 7.6458978,38.986164 6.6770511,38.972328 6,38 C 7.3541023,36.055343 9,36 9,36 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 15,32 C 17.5,34.5 27.5,34.5 30,32 C 30.5,30.5 30,30 30,30 C 30,27.5 27.5,26 27.5,26 C 33,24.5 33.5,14.5 22.5,10.5 C 11.5,14.5 12,24.5 17.5,26 C 17.5,26 15,27.5 15,30 C 15,30 14.5,30.5 15,32 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,evenOdd:true),
            Shape("M 25 10 A 2.5 2.5 0 1 1 20,10 A 2.5 2.5 0 1 1 25 10 z",fill:.black,stroke:.black,width:1.5,cap:.butt,join:.round,transform:[1,0,0,1,0,-2]),
            Shape("M 17.5,26 L 27.5,26",fill:nil,stroke:.white,width:1.5,cap:.round,join:.miter),
            Shape("M 15,30 L 30,30",fill:nil,stroke:.white,width:1.5,cap:.round,join:.miter),
            Shape("M 22.5,15.5 L 22.5,20.5",fill:nil,stroke:.white,width:1.5,cap:.round,join:.miter),
            Shape("M 20,18 L 25,18",fill:nil,stroke:.white,width:1.5,cap:.round,join:.miter)],
        "bn":[
            Shape("M 22,10 C 32.5,11 38.5,18 38,39 L 15,39 C 15,30 25,32.5 23,18",fill:.black,stroke:.black,width:1,cap:.round,join:.miter,evenOdd:true),
            Shape("M 24,18 C 24.384461,20.911278 18.447064,25.368624 16,27 C 13,29 13.180802,31.342892 11,31 C 9.95828,30.055984 12.413429,27.962451 11,28 C 10,28 11.187332,29.231727 10,30 C 9,30 5.9968392,30.999999 6,26 C 6,24 12,14 12,14 C 12,14 13.885866,12.097871 14,10.5 C 13.273953,9.505631 13.5,8.5 13.5,7.5 C 14.5,6.5 16.5,10 16.5,10 L 18.5,10 C 18.5,10 19.281781,8.0080745 21,7 C 22,7 22,10 22,10",fill:.black,stroke:.black,width:1,cap:.round,join:.round,evenOdd:true),
            Shape("M 9 23.5 A 0.5 0.5 0 1 1 8,23.5 A 0.5 0.5 0 1 1 9 23.5 z",fill:.black,stroke:.white,width:1,cap:.round,join:.round,transform:[1,0,0,1,0.5,2]),
            Shape("M 15 15.5 A 0.5 1.5 0 1 1 14,15.5 A 0.5 1.5 0 1 1 15 15.5 z",fill:.black,stroke:.white,width:1,cap:.round,join:.round,transform:[0.866025,0.5,-0.5,0.866025,9.692632,-5.173394]),
            Shape("M 24.55,10.4 L 24.25,11.5 L 24.8,11.6 C 27.901459,12.077147 31.123526,13.834204 33.375,18.09375 C 35.626474,22.353296 36.297157,29.05687 35.8,39 L 35.75,39.5 L 37.5,39.5 L 37.5,39 C 38.002843,28.94313 36.623526,22.146704 34.25,17.65625 C 31.876474,13.165796 28.461041,11.022853 25.0625,10.5 L 24.55,10.4 z",fill:.white,stroke:nil,evenOdd:true)],
        "bp":[
            Shape("M 22 9 C 19.792 9 18 10.792 18 13 C 18 13.885103 18.29397 14.712226 18.78125 15.375 C 16.829274 16.496917 15.5 18.588492 15.5 21 C 15.5 23.033947 16.442042 24.839082 17.90625 26.03125 C 14.907101 27.08912 10.5 31.578049 10.5 39.5 L 33.5 39.5 C 33.5 31.578049 29.092899 27.08912 26.09375 26.03125 C 27.557958 24.839082 28.5 23.033948 28.5 21 C 28.5 18.588492 27.170726 16.496917 25.21875 15.375 C 25.70603 14.712226 26 13.885103 26 13 C 26 10.792 24.208 9 22 9 z",fill:.black,stroke:.black,width:1,cap:.round,join:.miter)]
    ]
}
