import XCTest
import AppKit
import CryptoKit
@testable import CheckmateNative

/// The board's vector pieces (B-16): Cburnett's BSD-licensed set, transcribed from the committed SVGs and drawn natively,
/// with the old glyphs kept for any piece the set does not cover.
final class PieceArtworkTests:XCTestCase {
    private var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}
    private var artwork:URL {root.appendingPathComponent("Artwork/Upstream/cburnett-pieces")}
    private static let files:[String:String]=["wk":"klt","wq":"qlt","wr":"rlt","wb":"blt","wn":"nlt","wp":"plt","bk":"kdt","bq":"qdt","br":"rdt","bb":"bdt","bn":"ndt","bp":"pdt"]

    /// Reads the SVG the way the transcription must: every path in document order, its style resolved with SVG's defaults.
    private func shapes(_ file:URL)throws->[PieceArtwork.Shape] {
        let document=try XMLDocument(contentsOf:file,options:[])
        XCTAssertEqual(try document.nodes(forXPath:"//*[local-name()='g'][@transform]").count,0,"no group transforms")
        return try document.nodes(forXPath:"//*[local-name()='path']").map{node in
            let e=try XCTUnwrap(node as? XMLElement)
            var style:[String:String]=[:];for pair in (e.attribute(forName:"style")?.stringValue ?? "").split(separator:";"){let kv=pair.split(separator:":",maxSplits:1).map(String.init);if kv.count==2{style[kv[0]]=kv[1]}}
            func ink(_ v:String)->PieceArtwork.Ink? {v=="white" ? .white:v=="black" ? .black:nil}
            let fill=style["fill"] ?? "black",stroke=style["stroke"] ?? "none"
            XCTAssertEqual(style["opacity"] ?? "1","1");XCTAssertEqual(style["stroke-opacity"] ?? "1","1");if fill != "none"{XCTAssertEqual(style["fill-opacity"] ?? "1","1")}
            let width=Double((style["stroke-width"] ?? "1").replacingOccurrences(of:"px",with:""))!
            let cap:NSBezierPath.LineCapStyle=["butt":.butt,"round":.round,"square":.square][style["stroke-linecap"] ?? "butt"]!,join:NSBezierPath.LineJoinStyle=["miter":.miter,"round":.round][style["stroke-linejoin"] ?? "miter"]!
            var transform:[CGFloat]?
            if let t=e.attribute(forName:"transform")?.stringValue {
                let numbers=t.split(whereSeparator:{"(),".contains($0)}).dropFirst().map{CGFloat(Double($0)!)}
                transform=t.hasPrefix("translate") ? [1,0,0,1,numbers[0],numbers[1]]:numbers
            }
            let d=(e.attribute(forName:"d")?.stringValue ?? "").split(whereSeparator:\.isWhitespace).joined(separator:" ")
            return stroke=="none" ? PieceArtwork.Shape(d,fill:ink(fill),stroke:nil,evenOdd:fill != "none" && style["fill-rule"]=="evenodd",transform:transform)
                :PieceArtwork.Shape(d,fill:ink(fill),stroke:ink(stroke),width:CGFloat(width),cap:cap,join:join,evenOdd:fill != "none" && style["fill-rule"]=="evenodd",transform:transform)
        }
    }

    func testTheTableIsTheCommittedArtworkAndItsProvenance()throws {
        let provenance=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:artwork.appendingPathComponent("source.json"))) as? [String:Any])
        XCTAssertEqual(provenance["license"] as? String,"BSD-3-Clause")
        let recorded=try XCTUnwrap(provenance["files"] as? [String:[String:String]])
        XCTAssertEqual(Set(PieceArtwork.shapes.keys),Set(Self.files.keys))
        for (piece,name) in Self.files {
            let file=artwork.appendingPathComponent("Chess_\(name)45.svg")
            let digest=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
            XCTAssertEqual(digest,recorded[file.lastPathComponent]?["sha256"],"\(file.lastPathComponent) is the recorded upstream file")
            XCTAssertEqual(PieceArtwork.shapes[piece],try shapes(file),"\(piece) matches \(file.lastPathComponent)")
        }
    }
    func testTheLicenseTravelsWithTheAssetsTheAppAndAbout()throws {
        for file in [artwork.appendingPathComponent("LICENSE.txt"),root.appendingPathComponent("Sources/CheckmateCore/Resources/Licenses/cburnett-pieces.txt")] {
            let text=try String(contentsOf:file,encoding:.utf8);XCTAssertTrue(text.contains("Copyright (c) Cburnett"));XCTAssertTrue(text.contains("Redistributions in binary form"))
        }
        XCTAssertTrue(AboutPane.acknowledgements.contains{$0.0.contains("Cburnett") && $0.1=="BSD-3-Clause"})
        for notices in ["THIRD_PARTY_NOTICES.md","Sources/CheckmateCore/Resources/THIRD_PARTY_NOTICES.txt"] {XCTAssertTrue(try String(contentsOf:root.appendingPathComponent(notices),encoding:.utf8).contains("Cburnett"),notices)}
    }
    func testEveryPathParsesAndAnUnsupportedOneIsRefused(){
        for (piece,shapes) in PieceArtwork.shapes {for shape in shapes {XCTAssertFalse(PieceArtwork.segments(shape.d,transform:shape.transform)?.isEmpty ?? true,"\(piece): \(shape.d)")}}
        XCTAssertNil(PieceArtwork.segments("M 0 0 Q 1 1 2 2",transform:nil),"a command the set does not use is refused, not guessed")
        XCTAssertNil(PieceArtwork.segments("M 0 0 L 1",transform:nil),"a missing number is refused")
    }
    func testAnArcBecomesCurvesOnItsCircle()throws {
        // The queen's crown balls and pawn's head are circles drawn as two half arcs.
        let segments=try XCTUnwrap(PieceArtwork.segments("M 9 13 A 2 2 0 1 1 5,13 A 2 2 0 1 1 9 13 z",transform:[1,0,0,1,-1,-1]))
        // Centre (7,13) moved by translate(-1,-1); radius 2.
        let ends=segments.compactMap{s->CGPoint? in if case .curve(_,_,let end)=s{return end};return nil}
        XCTAssertGreaterThanOrEqual(ends.count,4)
        for p in ends {XCTAssertEqual(hypot(p.x-6,p.y-12),2,accuracy:1e-9)}
        // Midway along each cubic the curve stays within a hair of the circle.
        var start=CGPoint(x:8,y:12)
        for s in segments {guard case .curve(let c1,let c2,let end)=s else{continue}
            let mid=CGPoint(x:(start.x+3*c1.x+3*c2.x+end.x)/8,y:(start.y+3*c1.y+3*c2.y+end.y)/8);XCTAssertEqual(hypot(mid.x-6,mid.y-12),2,accuracy:0.002);start=end}
    }
    private func render(_ piece:String,side:Int=90,alpha:CGFloat=1)->NSBitmapImageRep {
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
        PieceArtwork.draw(piece,in:NSRect(x:0,y:0,width:side,height:side),alpha:alpha);NSGraphicsContext.restoreGraphicsState();return rep
    }
    /// Opaque pixels, their mean brightness, and how many sit in the base band (artwork y 34 to 39, where every piece
    /// has its wide base) and the mirrored band at the top (y 6 to 11). Bitmap row 0 is the top.
    private func ink(_ rep:NSBitmapImageRep)->(count:Int,brightness:Double,base:Int,top:Int) {
        var count=0,brightness=0.0,base=0,top=0
        for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {let c=rep.colorAt(x:x,y:y)!;if c.alphaComponent>0.5{count+=1;brightness+=Double(c.brightnessComponent);if (68..<78).contains(y){base+=1};if (12..<22).contains(y){top+=1}}}}
        return (count,count>0 ? brightness/Double(count):0,base,top)
    }
    func testEveryPieceDrawsUprightInsideItsSquareInItsSidesColour(){
        for kind in ["k","q","r","b","n","p"] {
            let white=ink(render("w"+kind)),black=ink(render("b"+kind))
            XCTAssertGreaterThan(white.count,400,"w\(kind) draws");XCTAssertGreaterThan(black.count,400,"b\(kind) draws")
            // Slender pieces are about half black outline at any size, so the sides are told apart against each other.
            XCTAssertGreaterThan(white.brightness,black.brightness+0.25,"w\(kind) reads lighter than b\(kind)");XCTAssertLessThan(black.brightness,0.4,"b\(kind) reads black")
            XCTAssertGreaterThan(white.base,white.top,"w\(kind) is upright");XCTAssertGreaterThan(black.base,black.top,"b\(kind) is upright")
        }
        let pawn=ink(render("wp")),king=ink(render("wk"));XCTAssertGreaterThan(king.count,pawn.count,"the pieces are told apart by shape")
    }
    func testFadingAPieceFadesItAsOne(){
        let rep=render("wq",alpha:0.4);var maximum:CGFloat=0
        for y in 0..<rep.pixelsHigh {for x in 0..<rep.pixelsWide {maximum=max(maximum,rep.colorAt(x:x,y:y)!.alphaComponent)}}
        XCTAssertEqual(maximum,0.4,accuracy:0.02,"overlapping strokes do not stack into darker seams")
    }
    func testAPieceWithoutArtworkFallsBackToItsGlyph(){
        XCTAssertNil(PieceArtwork.shapes["wx"]);XCTAssertGreaterThan(ink(render("wx")).count,100,"the glyph is drawn instead")
    }
    func testTheImageIsTheRequestedSize(){let image=PieceArtwork.image("bn",side:18);XCTAssertEqual(image.size,NSSize(width:18,height:18))}
}
