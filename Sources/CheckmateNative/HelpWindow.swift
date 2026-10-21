import AppKit
import SwiftUI
/// Help ▸ Checkmate Help (D-1): a short guide in the app, written from the README for the learner.
enum HelpContent {
    struct Section:Identifiable {let title:String,text:String;var id:String{title}}
    static let sections=[
        Section(title:"Lessons and puzzles",text:"Open a lesson from the sidebar. Lessons play with narration; use Lesson ▸ Play (⌥⌘P), Previous Step (⌘[) and Next Step (⌘]) to move through them. Quick puzzles and practice activities are in the sidebar too."),
        Section(title:"Practice",text:"Play a game against Stockfish, which runs on this Mac and works offline. Choose Game ▸ New Game… (⌘N) to pick your side and the opponent's strength. Game ▸ Hint (⇧⌘H) suggests a move, and Protected by (⇧⌘P) and Attacked by (⇧⌘A) show how a piece is defended or threatened."),
        Section(title:"Game review",text:"Choose File ▸ Review Current Game (⇧⌘R) to go through a game move by move, or File ▸ Open… (⌘O) to review a PGN or FEN file. You can try your own moves without changing the original game, then save the review (⌘S) or export it (⇧⌘E). Edit ▸ Copy FEN and Copy PGN copy the position or the game."),
        Section(title:"Voice coach",text:"The voice coach is off until you choose Connect Voice Coach in the Game menu. The first time, Checkmate explains what is sent to OpenAI and asks before it connects. Game ▸ Stop Speaking (⌘.) stops the coach at any time."),
        Section(title:"Windows",text:"View ▸ Show Sidebar (⌃⌘S) and Show Details (⌥⌘I) open the drawers beside the board. Closing the window quits Checkmate, after the same questions Quit asks, because the board is the app's only window. Settings (⌘,) holds the board, sound, lessons, practice, voice and connection choices."),
        Section(title:"Your data",text:"Games, progress and settings are stored only on this Mac. File ▸ Export Progress… saves a copy you can bring back with Import Progress…, and Show Backups… opens the folder where Checkmate keeps them."),
    ]
}
private struct HelpView:View {
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:16){
        ForEach(HelpContent.sections){section in VStack(alignment:.leading,spacing:4){Text(section.title).font(.headline).accessibilityAddTraits(.isHeader);Text(section.text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}}
    }.padding(20).frame(maxWidth:.infinity,alignment:.leading)}.frame(minWidth:420,minHeight:360)}
}
@MainActor final class HelpWindow:NSWindowController {
    init(){let w=NSWindow(contentViewController:NSHostingController(rootView:HelpView()));w.title="Checkmate Help";w.styleMask=[.titled,.closable,.resizable,.miniaturizable];w.setContentSize(NSSize(width:480,height:520));w.isReleasedWhenClosed=false;w.identifier=NSUserInterfaceItemIdentifier("Help");super.init(window:w)}
    required init?(coder:NSCoder){fatalError()}
}
