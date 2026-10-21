import AppKit
import SwiftUI
import CheckmateCore
/// What the About pane reports, read from the running bundle and course so it cannot drift from the release.
struct AboutFacts {
    let version:String,build:String,minimumSystem:String,lessons:Int,practiceActivities:Int,puzzles:Int,recordings:Int,dataDirectory:URL
    @MainActor init(model:NativeModel){let info=Bundle.main.infoDictionary ?? [:],library=model.learning.library
        version=info["CFBundleShortVersionString"] as? String ?? "unknown";build=info["CFBundleVersion"] as? String ?? "unknown";minimumSystem=info["LSMinimumSystemVersion"] as? String ?? "14.0"
        lessons=library.lessons.filter{!$0.isPractice}.count;practiceActivities=library.lessons.filter(\.isPractice).count;puzzles=library.puzzles.count;recordings=library.voices.reduce(0){$0+$1.count};dataDirectory=model.store.directory}
}
/// The About pane carries the GPL's Appropriate Legal Notices: copyright, no warranty, the license and the source.
struct AboutPane:View {
    let facts:AboutFacts
    private static let project=URL(string:"https://github.com/xiaolai/checkmate")!
    /// Automation records each request in the data directory instead of opening it, so pointer tests stay silent and can still see the click arrive.
    private func open(_ url:URL,reveal:Bool=false){
        if NativePolicy.silent {let log=facts.dataDirectory.appendingPathComponent("opened-urls.txt"),line=Data((url.absoluteString+"\n").utf8)
            if let handle=try? FileHandle(forWritingTo:log){handle.seekToEndOfFile();handle.write(line);try? handle.close()}else{try? line.write(to:log)};return}
        if reveal{NSWorkspace.shared.activateFileViewerSelecting([url])}else{NSWorkspace.shared.open(url)}
    }
    private func link(_ title:String,_ url:URL)->some View {Button(title){open(url)}.buttonStyle(.link)}
    var body:some View {
        Section {HStack(spacing:14){Image(nsImage:NSApp.applicationIconImage).resizable().frame(width:64,height:64).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:3){Text("Checkmate").font(.title2.weight(.semibold));Text("Version \(facts.version) (\(facts.build))").foregroundStyle(.secondary).textSelection(.enabled);Text("Learn and practice chess on your Mac.")}}}
        Section("What's inside"){LabeledContent("Chess engine",value:"Stockfish 19, on this Mac");LabeledContent("Lessons",value:"\(facts.lessons)");LabeledContent("Practice activities",value:"\(facts.practiceActivities)");LabeledContent("Puzzles",value:"\(facts.puzzles)");LabeledContent("Lesson recordings",value:"\(facts.recordings)");LabeledContent("Requires",value:"macOS \(facts.minimumSystem) or later")}
        Section("Privacy"){
            LabeledContent{Button("Show in Finder"){open(facts.dataDirectory,reveal:true)}}label:{Text("Games, progress and settings are stored only on this Mac.")}
            Text("Stockfish, lessons and puzzles work offline.")
            Text(VoiceConsent.sentToOpenAI)
            Text("Translating a lesson sends its text to Codex, and recording it sends the translated text to OpenAI for speech. Both happen only when you choose them, using your Codex sign-in.")
            Text("Chess MCP accepts connections only from this Mac. A Codex task you connect can read the current game, its position and moves, and your saved reviews, including the names, events and comments in imported games.")
        }
        Section {
            HStack(spacing:4){Text("Copyright © 2026");link("xiaolai",URL(string:"https://lixiaolai.com")!)}
            Text("Checkmate is free software: you can redistribute and modify it under the GNU General Public License, version 3 or later. It comes with no warranty.")
            HStack(spacing:16){link("License",NativeResources.url("Checkmate-COPYING.txt"));link("Third-Party Notices",NativeResources.url("THIRD_PARTY_NOTICES.txt"));link("Source Code",Self.project.appendingPathComponent("releases/tag/v\(facts.version)"))}
        } header:{Text("License")}
        Section {LabeledContent("Stockfish 19",value:"GPL-3.0");LabeledContent("chess.js 1.4.0, Jeff Hlywa",value:"BSD-2-Clause");LabeledContent("Swift MCP SDK and dependencies",value:"MIT, Apache-2.0");LabeledContent("Knight artwork, SVG Repo",value:"CC0-1.0")} header:{Text("Acknowledgements")} footer:{Text("Lesson narration is AI-generated speech (OpenAI Cedar).")}
        Section {HStack(spacing:16){link("Checkmate on GitHub",Self.project);link("Changelog",Self.project.appendingPathComponent("blob/v\(facts.version)/CHANGELOG.md"));link("Report a Problem",Self.project.appendingPathComponent("issues/new"))}}
    }
}
