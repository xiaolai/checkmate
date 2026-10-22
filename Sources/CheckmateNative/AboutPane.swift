import AppKit
import SwiftUI
import CheckmateCore
/// What the About pane reports, read from the running bundle and course so it cannot drift from the release. The
/// counts are the sidebar's: the main lessons Learn & explore counts, the practice lessons indented under them, and
/// the games its Mini-games section lists.
struct AboutFacts {
    let version:String,build:String,minimumSystem:String,lessons:Int,practiceLessons:Int,miniGames:Int,puzzles:Int,recordings:Int,dataDirectory:URL
    @MainActor init(model:NativeModel){let info=Bundle.main.infoDictionary ?? [:],library=model.learning.library
        version=info["CFBundleShortVersionString"] as? String ?? "unknown";build=info["CFBundleVersion"] as? String ?? "unknown";minimumSystem=info["LSMinimumSystemVersion"] as? String ?? "14.0"
        lessons=library.lessons.filter{!$0.isPractice}.count;practiceLessons=library.lessons.filter(\.isPractice).count;miniGames=SidebarSelection.miniGames(library).count;puzzles=library.puzzles.count;recordings=library.voices.reduce(0){$0+$1.count};dataDirectory=model.store.directory}
}
/// The About pane carries the GPL's Appropriate Legal Notices: copyright, no warranty, the license and the source.
struct AboutPane:View {
    let facts:AboutFacts
    static let project=URL(string:"https://github.com/xiaolai/checkmate")!,reportProblem=project.appendingPathComponent("issues/new")
    /// The pane's acknowledgements, which the standard About panel's credits list too (D-9).
    static let acknowledgements=[(String(localized:"Stockfish 19",bundle:.checkmate),"GPL-3.0"),("chess.js 1.4.0, Jeff Hlywa","BSD-2-Clause"),(String(localized:"Swift MCP SDK and dependencies",bundle:.checkmate),"MIT, Apache-2.0"),(String(localized:"Knight artwork, SVG Repo",bundle:.checkmate),"CC0-1.0"),(String(localized:"Chess pieces, Cburnett",bundle:.checkmate),"BSD-3-Clause")]
    static let license=String(localized:"Checkmate is free software: you can redistribute and modify it under the GNU General Public License, version 3 or later. It comes with no warranty.",bundle:.checkmate),narration=String(localized:"Lesson narration is AI-generated speech (OpenAI Cedar).",bundle:.checkmate)
    /// The About panel's credits: the license, the acknowledgements, and where the rest is.
    static var credits:NSAttributedString {
        let text=([license,"",String(localized:"Acknowledgements",bundle:.checkmate)]+acknowledgements.map{"\($0.0) (\($0.1))"}+[narration,"",String(localized:"Privacy, licenses and links are in Settings ▸ About.",bundle:.checkmate)]).joined(separator:"\n")
        let style=NSMutableParagraphStyle();style.alignment = .center
        return NSAttributedString(string:text,attributes:[.font:styledFont(.subheadline),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
    }
    /// Automation records each request in the data directory instead of opening it, so pointer tests stay silent and can still see the click arrive.
    static func open(_ url:URL,reveal:Bool=false,dataDirectory:URL){
        if NativePolicy.silent {let log=dataDirectory.appendingPathComponent("opened-urls.txt"),line=Data((url.absoluteString+"\n").utf8)
            if let handle=try? FileHandle(forWritingTo:log){handle.seekToEndOfFile();handle.write(line);try? handle.close()}else{try? line.write(to:log)};return}
        if reveal{NSWorkspace.shared.activateFileViewerSelecting([url])}else{NSWorkspace.shared.open(url)}
    }
    private func open(_ url:URL,reveal:Bool=false){Self.open(url,reveal:reveal,dataDirectory:facts.dataDirectory)}
    private func link(_ title:String,_ url:URL)->some View {Button(title){open(url)}.buttonStyle(.link)}
    var body:some View {
        Section {HStack(spacing:14){Image(nsImage:NSApp.applicationIconImage).resizable().frame(width:64,height:64).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:3){Text("Checkmate").sectionHeading(.title2.weight(.semibold));Text("Version \(facts.version) (\(facts.build))").foregroundStyle(.secondary).textSelection(.enabled);Text("Learn and practice chess on your Mac.")}}}
        Section("What's inside"){LabeledContent("Chess engine",value:String(localized:"Stockfish 19, on this Mac",bundle:.checkmate));LabeledContent("Lessons",value:"\(facts.lessons)");LabeledContent("Practice lessons",value:"\(facts.practiceLessons)");LabeledContent("Mini-games",value:"\(facts.miniGames)");LabeledContent("Puzzles",value:"\(facts.puzzles)");LabeledContent("Lesson recordings",value:"\(facts.recordings)");LabeledContent("Requires",value:String(localized:"macOS \(facts.minimumSystem) or later",bundle:.checkmate,comment:"The oldest macOS version the app runs on"))}
        Section("Privacy"){
            LabeledContent{Button("Show in Finder"){open(facts.dataDirectory,reveal:true)}}label:{Text("Games, progress and settings are stored only on this Mac.")}
            Text("Stockfish, lessons and puzzles work offline.")
            Text(VoiceConsent.sentToOpenAI)
            Text("Translating a lesson sends its text to Codex, and recording it sends the translated text to OpenAI for speech. Both happen only when you choose them, using your Codex sign-in.")
            Text("The Codex companion accepts connections only from this Mac. A Codex task you connect can read the current game, its position and moves, and your saved reviews, including the names, events and comments in imported games.")
        }
        Section {
            HStack(spacing:Metrics.tightGap){Text("Copyright © 2026");link("xiaolai",URL(string:"https://lixiaolai.com")!)}
            Text(Self.license)
            HStack(spacing:Metrics.padding){link(String(localized:"License",bundle:.checkmate),NativeResources.url("Checkmate-COPYING.txt"));link("Third-Party Notices",NativeResources.url("THIRD_PARTY_NOTICES.txt"));link(String(localized:"Source Code",bundle:.checkmate),Self.project.appendingPathComponent("releases/tag/v\(facts.version)"))}
        } header:{Text("License")}
        Section {ForEach(Self.acknowledgements,id:\.0){LabeledContent($0.0,value:$0.1)}} header:{Text("Acknowledgements")} footer:{Text(Self.narration)}
        Section {HStack(spacing:Metrics.padding){link(String(localized:"Checkmate on GitHub",bundle:.checkmate),Self.project);link(String(localized:"Changelog",bundle:.checkmate),Self.project.appendingPathComponent("blob/v\(facts.version)/CHANGELOG.md"));link(String(localized:"Report a Problem",bundle:.checkmate),Self.reportProblem)}}
    }
}
