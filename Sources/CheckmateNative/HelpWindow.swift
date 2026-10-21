import AppKit
import SwiftUI
/// Help ▸ Checkmate Help (D-1): a short guide in the app, written from the README for the learner.
enum HelpContent {
    struct Section:Identifiable {let title:String,text:String;var id:String{title}}
    static let sections=[
        Section(title:String(localized:"Lessons and puzzles",bundle:.checkmate),text:String(localized:"Open a lesson from the sidebar. Lessons play with narration; use Lesson ▸ Play (⌥⌘P), Previous Step (⌘[) and Next Step (⌘]) to move through them. Quick puzzles and practice activities are in the sidebar too.",bundle:.checkmate)),
        Section(title:String(localized:"Practice",bundle:.checkmate),text:String(localized:"Play a game against Stockfish, which runs on this Mac and works offline. Choose Game ▸ New Game… (⌘N) to pick your side and the opponent's strength. Game ▸ Hint (⇧⌘H) suggests a move, and Protected by (⇧⌘P) and Attacked by (⇧⌘A) show how a piece is defended or threatened. To play from the keyboard, choose Game ▸ Type a Move… (⌘L) and type a move such as e4, Nf3 or O-O. Click a move in the move list to see that earlier position, and use the left and right arrow keys to step through the moves.",bundle:.checkmate)),
        Section(title:String(localized:"Game review",bundle:.checkmate),text:String(localized:"Choose File ▸ Review Current Game (⇧⌘R) to go through a game move by move, or File ▸ Open… (⌘O) to review a PGN or FEN file. You can try your own moves without changing the original game, then save the review (⌘S) or export it (⇧⌘E). Edit ▸ Copy FEN and Copy PGN copy the position or the game.",bundle:.checkmate)),
        Section(title:String(localized:"Voice coach",bundle:.checkmate),text:String(localized:"The voice coach is off until you choose Connect Voice Coach in the Game menu. The first time, Checkmate explains what is sent to OpenAI and asks before it connects. Game ▸ Stop Speaking (⌘.) stops the coach at any time.",bundle:.checkmate)),
        Section(title:String(localized:"Windows",bundle:.checkmate),text:String(localized:"View ▸ Show Sidebar (⌃⌘S) and Show Details (⌥⌘I) open the drawers beside the board. Closing the window quits Checkmate, after the same questions Quit asks, because the board is the app's only window. Settings (⌘,) holds the board, sound, lessons, practice, voice and connection choices.",bundle:.checkmate)),
        Section(title:String(localized:"Your data",bundle:.checkmate),text:String(localized:"Games, progress and settings are stored only on this Mac. File ▸ Export Progress… saves a copy you can bring back with Import Progress…, and Show Backups… opens the folder where Checkmate keeps them.",bundle:.checkmate)),
    ]
}
private struct HelpView:View {
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:16){
        ForEach(HelpContent.sections){section in VStack(alignment:.leading,spacing:4){Text(section.title).sectionHeading();Text(section.text).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)}}
    }.padding(20).frame(maxWidth:.infinity,alignment:.leading)}.frame(minWidth:420,minHeight:360)}
}
@MainActor final class HelpWindow:NSWindowController {
    init(){let w=NSWindow(contentViewController:NSHostingController(rootView:HelpView()));w.title=String(localized:"Checkmate Help",bundle:.checkmate);w.styleMask=[.titled,.closable,.resizable,.miniaturizable];w.setContentSize(NSSize(width:480,height:520));w.isReleasedWhenClosed=false;w.identifier=NSUserInterfaceItemIdentifier("Help");super.init(window:w)}
    required init?(coder:NSCoder){fatalError()}
}
