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
        let headings=["Suggested practice","Game library","PGN game records","FEN positions","Training","Quick puzzles","Try a move","Moves","Voice coach","Voice Coach","Games on your network","Host a Game","Moments to review","Evaluation","Game review","Practice from this position","Checkmate","Game paused","You Reached the End of This Set"]
        let all=files.values.joined(separator:"\n")
        for heading in headings {
            XCTAssertTrue(all.contains("Text(\"\(heading)\").sectionHeading("),"\(heading) is a heading")
            XCTAssertFalse(all.contains("Text(\"\(heading)\").font("),"\(heading) is styled without the heading trait")
        }
        // Headings whose text is computed: the practice result and its summary card, the course-complete card, Help, and the end of Today's Mix.
        for heading in ["Self.practiceHeading(session)","CourseCompleteCard.title","section.title","TodayMix.finished"] {
            XCTAssertTrue(all.contains("Text(\(heading)).sectionHeading("),"\(heading) is a heading")
            XCTAssertFalse(all.contains("Text(\(heading)).font("),"\(heading) is styled without the heading trait")
        }
        // The library preview's title and the lesson list's course sections are computed headings too.
        for heading in ["Text(verbatim:preview.title)","Text(group.title)"] {
            XCTAssertTrue(all.contains("\(heading).sectionHeading("),"\(heading) is a heading")
            XCTAssertFalse(all.contains("\(heading).font("),"\(heading) is styled without the heading trait")
        }
        // Text follows text styles, in SwiftUI and AppKit alike. The fixed sizes allowed scale with what they are drawn
        // in rather than with the text: a piece glyph or coordinate sized to its board square, a symbol sized to its image;
        // a size read from a text style is a text style.
        let fixed=try NSRegularExpression(pattern:#"(?:\.system\(size|\b\w*[sS]ystemFont\(ofSize|NSFont\(name:[^,]*,\s*size|\.custom\([^,]*,\s*size):\s*([^,)]+)"#)
        let scaled=["Self.square","size","Self.coordinateFontSize(side:s","s*0.16","rect.height"]
        var found=0
        for (name,text) in files {
            for match in fixed.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                found+=1;let size=Range(match.range(at:1),in:text).map{String(text[$0])} ?? ""
                XCTAssertTrue(scaled.contains{size==$0 || $0=="Self.square" && size.hasPrefix($0)} || size.hasPrefix("NSFont.preferredFont(forTextStyle:"),"\(name) fixes a font size (\(size)); use a text style")
            }
        }
        XCTAssertGreaterThanOrEqual(found,5,"the check sees the board's scaled glyphs, so it reads the sources it means to")
    }
    func testWindowLabelsUseTextStyles(){
        XCTAssertEqual(textLabel("Notes").font?.pointSize,NSFont.preferredFont(forTextStyle:.body).pointSize)
        let title=textLabel("Settings",.title3,.semibold)
        XCTAssertEqual(title.font?.pointSize,NSFont.preferredFont(forTextStyle:.title3).pointSize)
        XCTAssertEqual((title.font?.fontDescriptor.object(forKey:.traits) as? [NSFontDescriptor.TraitKey:Any])?[.weight] as? CGFloat ?? 0,NSFont.Weight.semibold.rawValue,accuracy:0.01)
        // The library's result badge: digits of one width, at its text style's size.
        XCTAssertEqual(styledFont(.caption1,.medium,monospacedDigits:true).pointSize,NSFont.preferredFont(forTextStyle:.caption1).pointSize)
    }
}
