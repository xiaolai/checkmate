import XCTest
import AppKit
@testable import CheckmateNative
/// D-23, D-24: section headings are announced as headings, and window labels follow text styles instead of fixed sizes.
/// SwiftUI builds its accessibility tree only for a connected assistive client, so an in-process test cannot read the
/// heading role; the source is checked instead, and a live accessibility listing shows them as AXHeading.
final class TextStyleAccessibilityTests:XCTestCase {
    private static let sources=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/CheckmateNative")
    private func source()throws -> [String:String] {
        let files=try FileManager.default.contentsOfDirectory(at:Self.sources,includingPropertiesForKeys:nil).filter{$0.pathExtension=="swift"}
        XCTAssertFalse(files.isEmpty,"the native sources were found");return try Dictionary(uniqueKeysWithValues:files.map{($0.lastPathComponent,try String(contentsOf:$0,encoding:.utf8))})
    }
    func testSectionHeadingsUseTheSharedHeadingModifier()throws {
        let files=try source()
        // One place adds the heading trait, so every heading reads the same way.
        for (name,text) in files where name != "Helpers.swift" {XCTAssertFalse(text.contains(".accessibilityAddTraits(.isHeader)"),"\(name) adds the heading trait itself; use sectionHeading()")}
        XCTAssertTrue(files["Helpers.swift"]?.contains("func sectionHeading(") == true)
        let headings=["Suggested practice","Game library","PGN game records","FEN positions","Training","Quick puzzles","Try a move","Moves","Voice coach","Games on your network","Host a Game","Moments to review","Evaluation","Game review","Practise from this position","Checkmate"]
        let all=files.values.joined(separator:"\n")
        for heading in headings {
            XCTAssertTrue(all.contains("Text(\"\(heading)\").sectionHeading("),"\(heading) is a heading")
            XCTAssertFalse(all.contains("Text(\"\(heading)\").font("),"\(heading) is styled without the heading trait")
        }
        XCTAssertFalse(all.contains(".font(.system(size:"),"fixed font sizes give way to text styles")
    }
    func testWindowLabelsUseTextStyles(){
        XCTAssertEqual(textLabel("Notes").font?.pointSize,NSFont.preferredFont(forTextStyle:.body).pointSize)
        let title=textLabel("Settings",.title3,.semibold)
        XCTAssertEqual(title.font?.pointSize,NSFont.preferredFont(forTextStyle:.title3).pointSize)
        XCTAssertEqual((title.font?.fontDescriptor.object(forKey:.traits) as? [NSFontDescriptor.TraitKey:Any])?[.weight] as? CGFloat ?? 0,NSFont.Weight.semibold.rawValue,accuracy:0.01)
    }
}
