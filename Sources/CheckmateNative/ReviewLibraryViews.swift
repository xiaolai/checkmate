import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CheckmateCore
/// The game library in the review workspace: a fixed control row (search and scope), one scrolling list that fills the
/// remaining height, and a fixed footer. Imported text is untrusted and always shown verbatim.
struct GameLibraryBrowser:View {
    @ObservedObject var model:NativeModel
    @ObservedObject var library:ReviewLibraryController
    @State private var dropTargeted=false
    private var sections:[LibrarySection] {library.shown}
    var body:some View {VStack(alignment:.leading,spacing:Metrics.smallGap){
        Text("Game library").sectionHeading()
        ViewThatFits(in:.horizontal){
            HStack(spacing:Metrics.smallGap){search.frame(minWidth:150);scopePicker.pickerStyle(.segmented).controlSize(.small).fixedSize();sortPicker}
            HStack(spacing:Metrics.smallGap){search.frame(minWidth:160);scopePicker.pickerStyle(.menu).fixedSize();sortPicker}
            VStack(alignment:.leading,spacing:Metrics.smallGap){search.frame(minWidth:160);HStack(spacing:Metrics.smallGap){scopePicker.pickerStyle(.menu).fixedSize();sortPicker}}
        }
        results.frame(maxWidth:.infinity,maxHeight:.infinity)
            .overlay{if dropTargeted{RoundedRectangle(cornerRadius:6).stroke(Color.accentColor,lineWidth:3).allowsHitTesting(false)}}
            .onDrop(of:[.fileURL],isTargeted:$dropTargeted){providers in drop(providers)}
        footer
    }.onAppear{library.load()}}
    private var search:some View {
        LibrarySearchField(text:$library.query,focusRequests:library.findRequests,
                           moveDown:{library.moveIntoList()},
                           submit:{library.openSelection()})
            .frame(height:22).accessibilityLabel("Search the game library")
    }
    private var scopePicker:some View {
        Picker("Show",selection:$library.scope){ForEach(LibraryScope.allCases){Text($0.title).tag($0)}}.labelsHidden().accessibilityLabel("Show").accessibilityIdentifier("library-scope")
    }
    /// The order of the games in each section (R-21).
    private var sortPicker:some View {
        Picker("Sort By",selection:$library.sort){ForEach(LibrarySort.allCases){Text($0.title).tag($0)}}.pickerStyle(.menu).fixedSize().help("Sort By")
            .accessibilityLabel("Sort By").accessibilityIdentifier("library-sort")
    }
    @ViewBuilder private var results:some View {
        switch library.bundled {
        case .loading where library.scope != .saved:ProgressView("Loading the game library…").frame(maxWidth:.infinity,maxHeight:.infinity)
        case .failed(let message) where library.scope != .myGames && library.scope != .saved:
            VStack(spacing:Metrics.smallGap){Text("The game library could not be loaded.").font(.headline);Text(verbatim:message).foregroundStyle(.secondary).multilineTextAlignment(.center)}.foregroundStyle(Color(nsColor:NativeColors.error)).frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityElement(children:.combine)
        default:
            let shown=sections
            if shown.isEmpty || shown.allSatisfy({$0.rows.isEmpty && $0.kind == .collection(nil)}) {
                let searching = !library.query.isEmpty,hint=Self.emptyHint(scope:library.scope,searching:searching)
                ContentUnavailableView{Label(Self.emptyTitle(scope:library.scope,searching:searching),symbol:searching ? .search:.library)}
                    description:{if !hint.isEmpty{Text(hint)}}
                    actions:{if searching{Button("Clear Search"){library.query=""}}}
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {LibraryTable(library:library,version:library.shownVersion,selection:library.selection,focusRequests:library.listFocusRequests)}
        }
    }
    static func emptyTitle(scope:LibraryScope,searching:Bool)->String {
        switch (scope,searching) {case (.saved,false):String(localized:"No saved reviews yet",bundle:.checkmate);case (.saved,true):String(localized:"No saved reviews match your search",bundle:.checkmate);case (.myGames,false):String(localized:"No collections yet",bundle:.checkmate);case (_,false):String(localized:"No games",bundle:.checkmate);case (_,true):String(localized:"No games match your search",bundle:.checkmate)}
    }
    static func emptyHint(scope:LibraryScope,searching:Bool)->String {
        switch (scope,searching) {case (.saved,false):String(localized:"A game you review is saved here when you return to your game.",bundle:.checkmate);case (.saved,true):String(localized:"Try a name, player, event or year.",bundle:.checkmate);case (.myGames,false):String(localized:"Import a PGN collection, or drop a PGN file here.",bundle:.checkmate);case (_,false):"";case (_,true):String(localized:"Try a player, event, year or opening.",bundle:.checkmate)}
    }
    private var footer:some View {
        VStack(alignment:.leading,spacing:Metrics.tightGap){
            HStack(spacing:Metrics.smallGap){
                Button("Import Collection…"){library.chooseCollection()}.disabled(library.importing != nil).help("Import a downloaded PGN file, or drop one on the list.")
                Button("Get More Games"){library.openMoreGames()}.accessibilityHint("Opens a page of free PGN downloads in your browser.")
                Spacer()
                if let name=library.importing {
                    ProgressView().controlSize(.small).accessibilityLabel("Importing")
                    Text(verbatim:String(localized:"Importing \(PGNImporter.bounded(name,scalars:40))…",bundle:.checkmate)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel"){library.cancelImport()}.controlSize(.small)
                }
            }
        }
    }
    private func drop(_ providers:[NSItemProvider])->Bool {
        guard let provider=providers.first(where:{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}) else{return false}
        _=provider.loadObject(ofClass:URL.self){url,_ in guard let url,url.isFileURL else{return};Task{@MainActor in library.importCollection(url)}}
        return true
    }
}
/// A native search field: Escape clears it, ↓ moves into the results, Return opens the selected row, and Edit ▸ Find…
/// focuses it.
struct LibrarySearchField:NSViewRepresentable {
    @Binding var text:String
    let focusRequests:Int,moveDown:()->Void,submit:()->Void
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSSearchField {
        let field=NSSearchField();field.placeholderString=String(localized:"Players, event, year or opening",bundle:.checkmate);field.sendsSearchStringImmediately=true;field.sendsWholeSearchString=false
        field.delegate=context.coordinator;field.setAccessibilityIdentifier("library-search");field.setAccessibilityLabel(String(localized:"Search the game library",bundle:.checkmate));return field
    }
    func updateNSView(_ field:NSSearchField,context:Context){
        context.coordinator.parent=self
        if field.stringValue != text{field.stringValue=text}
        if context.coordinator.focusRequests != focusRequests{context.coordinator.focusRequests=focusRequests;DispatchQueue.main.async{field.window?.makeFirstResponder(field)}}
    }
    final class Coordinator:NSObject,NSSearchFieldDelegate {
        var parent:LibrarySearchField,focusRequests:Int
        init(_ parent:LibrarySearchField){self.parent=parent;focusRequests=parent.focusRequests}
        func controlTextDidChange(_ notification:Notification){if let field=notification.object as? NSSearchField{parent.text=field.stringValue}}
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):parent.moveDown();return true
            case #selector(NSResponder.insertNewline(_:)):parent.submit();return true
            case #selector(NSResponder.cancelOperation(_:)):(control as? NSSearchField)?.stringValue="";parent.text="";return true
            default:return false
            }
        }
    }
}
