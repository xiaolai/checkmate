import SwiftUI
import AppKit
import Combine
import CheckmateCore
/// The game library list as an AppKit table. The library controller owns every piece of state (lines, selection,
/// collapsed events, search); this view only renders `library.items`.
///
/// Why AppKit: SwiftUI's `List` measured a SwiftUI view for every row a search inserted (AppKit's automatic row
/// heights), so a keystroke that brought back dozens of events took three display frames. Here every line has a fixed
/// height and only the rows on screen ever get a view, reused through `makeView(withIdentifier:)`.
struct LibraryTable:NSViewRepresentable {
    @ObservedObject var library:ReviewLibraryController
    /// Passed so SwiftUI updates the table whenever the lines, the selection or the focus request change.
    let version:Int,selection:String?,focusRequests:Int
    static let rowHeight:CGFloat=50,headerHeight:CGFloat=30,brokenHeight:CGFloat=26
    func makeCoordinator()->Coordinator {Coordinator(library)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.documentView=Self.makeTable(context.coordinator);scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        scroll.setAccessibilityIdentifier("library-list")
        context.coordinator.apply(focusRequests:focusRequests)
        return scroll
    }
    /// The configured table, driven by `coordinator` (also how the tests build one).
    static func makeTable(_ coordinator:Coordinator)->LibraryTableView {
        let table=LibraryTableView();table.coordinator=coordinator
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("game"));column.resizingMask = .autoresizingMask;table.addTableColumn(column)
        table.headerView=nil;table.style = .inset;table.usesAutomaticRowHeights=false;table.rowHeight=rowHeight;table.floatsGroupRows=false
        table.intercellSpacing=NSSize(width:0,height:0);table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle;table.allowsEmptySelection=true;table.allowsMultipleSelection=false
        table.dataSource=coordinator;table.delegate=coordinator;table.target=coordinator;table.action=#selector(Coordinator.clicked(_:));table.doubleAction=#selector(Coordinator.clicked(_:))
        table.setAccessibilityLabel("Games");coordinator.table=table
        let menu=NSMenu();menu.delegate=coordinator;table.menu=menu
        return table
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){context.coordinator.library=library;context.coordinator.apply(focusRequests:focusRequests)}

    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSMenuDelegate {
        var library:ReviewLibraryController
        weak var table:LibraryTableView?
        private var items:[LibraryListItem]=[],ids:[String]=[],version = -1,focusRequests:Int
        private var applyingSelection=false
        private var observation:AnyCancellable?
        /// Opens a game; a test replaces it to see which game a row's action opens.
        var openRow:(LibraryRow)->Void
        init(_ library:ReviewLibraryController){
            self.library=library;focusRequests=library.listFocusRequests;openRow={[weak library] in library?.open($0)};super.init()
            // The table follows the controller's lines directly, as soon as they change, instead of waiting for SwiftUI's
            // next view update (which a keystroke sometimes reached several frames late). The change is applied after
            // the controller has finished publishing, never inside it.
            observation=library.$shownVersion.dropFirst().receive(on:RunLoop.main).sink{[weak self] _ in guard let self else{return};self.apply(focusRequests:self.focusRequests)}
        }
        /// Brings the table to the controller's lines. Lines removed or inserted change with no animation; a line that
        /// stays but whose value changed is reloaded, as are the headers on screen (their state follows the search and
        /// collapse). If the lines that stay are no longer in the same order, the table is reloaded instead. Selection
        /// callbacks are silenced throughout and the controller's selection is put back afterwards; nothing is
        /// published to the controller from here.
        func apply(focusRequests requests:Int){
            guard let table else{return}
            applyingSelection=true;defer{applyingSelection=false}
            let wantedID=library.selection
            if version != library.shownVersion {
                table.applyStarted=Date()
                let next=library.items
                var changed=IndexSet()
                switch LibraryTableUpdate.plan(old:items,new:next) {
                case .none:items=next
                case .reload:items=next;ids=next.map(\.id);table.reloadData()
                case .patch(let removed,let inserted,let rows):
                    table.beginUpdates();table.removeRows(at:removed,withAnimation:[]);items=next;ids=next.map(\.id);table.insertRows(at:inserted,withAnimation:[]);table.endUpdates()
                    changed=rows
                }
                // Headers on screen follow the search and collapse state, which the lines do not carry: they are refreshed
                // on every change, including one that leaves the lines as they were (clearing a search that matched them all).
                let visible=table.rows(in:table.visibleRect),onScreen=IndexSet(integersIn:visible.location..<visible.location+visible.length)
                let refresh=changed.union(onScreen.filteredIndexSet{if case .header=self.items[$0]{return true};return false})
                if !refresh.isEmpty{table.reloadData(forRowIndexes:refresh,columnIndexes:IndexSet(integer:0))}
                version=library.shownVersion
                table.appliedVersion=version;table.appliedIDs=ids;table.applyFinished=Date()
            }
            let wanted=wantedID.flatMap{ids.firstIndex(of:$0)}
            if table.selectedRow != (wanted ?? -1) {
                if let wanted{table.selectRowIndexes(IndexSet(integer:wanted),byExtendingSelection:false);table.scrollRowToVisible(wanted)}else{table.deselectAll(nil)}
            }
            if focusRequests != requests{focusRequests=requests;DispatchQueue.main.async{table.window?.makeFirstResponder(table)}}
        }
        func numberOfRows(in tableView:NSTableView)->Int {items.count}
        func tableView(_ tableView:NSTableView,isGroupRow row:Int)->Bool {if case .header=items[row]{return true};return false}
        func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat {
            switch items[row] {case .header:LibraryTable.headerHeight;case .broken:LibraryTable.brokenHeight;case .row:LibraryTable.rowHeight}
        }
        func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool {if case .row=items[row]{return true};return false}
        func tableViewSelectionDidChange(_ notification:Notification){
            guard !applyingSelection,let table else{return}
            let row=table.selectedRow;library.selection=row>=0 && row<items.count ? ids[row]:nil
        }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            switch items[row] {
            case .header(let section) where section.kind == .event:
                let view=reuse(tableView,EventHeaderCell.identifier){EventHeaderCell()}
                view.show(section,open:library.isOpen(section.id),enabled:library.query.isEmpty){[weak self] in self?.library.toggle(section.id)};return view
            case .header(let section):
                let view=reuse(tableView,SectionHeaderCell.identifier){SectionHeaderCell()}
                let sha=String(section.id.dropFirst("collection:".count))
                view.show(section,rename:{[weak self] in self?.library.requestRename(sha)},remove:{[weak self] in self?.removeCollection(sha,title:section.title)});return view
            case .broken(_,let broken):
                let view=reuse(tableView,BrokenCell.identifier){BrokenCell()};view.show(broken);return view
            case .row(let game):
                let view=reuse(tableView,GameRowCell.identifier){GameRowCell()};view.show(game){[weak self] in self?.openRow(game)};return view
            }
        }
        private func reuse<T:NSView>(_ table:NSTableView,_ identifier:NSUserInterfaceItemIdentifier,_ make:()->T)->T {
            if let view=table.makeView(withIdentifier:identifier,owner:nil) as? T{return view};let view=make();view.identifier=identifier;return view
        }
        /// A click (or double-click) on a game opens it, as a click on a row always has.
        @objc func clicked(_ sender:NSTableView){
            let row=sender.clickedRow;guard row>=0,row<items.count,case .row(let game)=items[row] else{return};library.selection=game.id;library.open(game)
        }
        /// The shortcut menu of a line (Control-click): a saved review opens, is renamed or deleted; a collection is
        /// renamed or removed.
        func actions(at row:Int)->[(title:String,perform:()->Void)] {
            guard row>=0,row<items.count else{return []}
            switch items[row] {
            case .row(let game):
                guard case .saved(let id)=game.source else{return [("Open",{[weak self] in self?.openRow(game)})]}
                return [("Open",{[weak self] in self?.openRow(game)}),("Rename…",{[weak self] in self?.library.model?.requestRenameReview(id)}),("Delete Saved Review…",{[weak self] in self?.library.model?.requestDeleteReview(id)})]
            case .header(let section) where section.id.hasPrefix("collection:"):
                let sha=String(section.id.dropFirst("collection:".count))
                return [("Rename…",{[weak self] in self?.library.requestRename(sha)}),("Remove…",{[weak self] in self?.removeCollection(sha,title:section.title)})]
            default:return []
            }
        }
        func menuNeedsUpdate(_ menu:NSMenu){
            menu.removeAllItems()
            for action in actions(at:table?.clickedRow ?? -1){let item=NSMenuItem(title:action.title,action:#selector(MenuAction.run),keyEquivalent:"");let target=MenuAction(action.perform);item.target=target;item.representedObject=target;menu.addItem(item)}
        }
        fileprivate func removeCollection(_ sha:String,title:String){if let collection=library.collection(sha){library.requestRemove(collection)}else{library.requestRemove(sha,name:title,games:nil)}}
        func returnPressed(){library.openSelection()}
        func escapePressed()->Bool {guard !library.query.isEmpty else{return false};library.query="";return true}
    }
}
/// How the table moves from one list of lines to the next, worked out without the table.
enum LibraryTableUpdate:Equatable {
    /// Nothing changed; reload everything; or remove (old indexes), then insert (final indexes), then reload lines that
    /// kept their id but show something else (final indexes).
    case none,reload,patch(removed:IndexSet,inserted:IndexSet,changed:IndexSet)
    static func plan(old:[LibraryListItem],new:[LibraryListItem])->LibraryTableUpdate {
        let oldIDs=old.map(\.id),newIDs=new.map(\.id),oldSet=Set(oldIDs),newSet=Set(newIDs)
        if oldIDs.isEmpty || newIDs.isEmpty{return oldIDs==newIDs ? .none:.reload}
        // Lines that stay must keep their order; otherwise rows would have to move, and a reload is simpler and as fast.
        guard oldIDs.filter({newSet.contains($0)})==newIDs.filter({oldSet.contains($0)}) else{return .reload}
        let removed=IndexSet(oldIDs.indices.filter{!newSet.contains(oldIDs[$0])}),inserted=IndexSet(newIDs.indices.filter{!oldSet.contains(newIDs[$0])})
        if removed.count+inserted.count>(oldIDs.count+newIDs.count)/2{return .reload}
        let previous=Dictionary(uniqueKeysWithValues:zip(oldIDs,old))
        let changed=IndexSet(new.indices.filter{index in previous[newIDs[index]].map{!same($0,new[index])} ?? false})
        return removed.isEmpty && inserted.isEmpty && changed.isEmpty ? .none:.patch(removed:removed,inserted:inserted,changed:changed)
    }
    /// Whether a line that kept its id still shows the same thing.
    static func same(_ a:LibraryListItem,_ b:LibraryListItem)->Bool {
        switch (a,b) {
        case (.row(let x),.row(let y)):x==y
        case (.broken(_,let x),.broken(_,let y)):x==y
        case (.header(let x),.header(let y)):x.title==y.title && x.kind==y.kind
        default:false
        }
    }
}
/// Return opens the selected game; Escape clears a search. Arrow keys are the table's own.
final class LibraryTableView:NSTableView {
    weak var coordinator:LibraryTable.Coordinator?
    /// The controller version and the exact line ids this table last applied (read by the timing scenario).
    var appliedVersion = -1,appliedIDs:[String]=[]
    /// When the last change of lines started and finished applying (read by the timing scenario).
    var applyStarted=Date.distantPast,applyFinished=Date.distantPast
    override func keyDown(with event:NSEvent){
        switch event.keyCode {
        case 36,76:coordinator?.returnPressed()
        case 53:if coordinator?.escapePressed() != true{super.keyDown(with:event)}
        default:super.keyDown(with:event)
        }
    }
}
// MARK: Cells. System fonts and colours only, so light, dark and increased contrast follow the system.
private func label(_ font:NSFont,_ color:NSColor = .labelColor)->NSTextField {
    let field=NSTextField(labelWithString:"");field.font=font;field.textColor=color;field.lineBreakMode = .byTruncatingTail;field.maximumNumberOfLines=1
    field.translatesAutoresizingMaskIntoConstraints=false;field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return field
}
/// A game: title, then details and facts when it has them, and the result in a badge. Its accessibility element is a
/// button named by the full title, which opens the game.
final class GameRowCell:NSTableCellView {
    static let identifier=NSUserInterfaceItemIdentifier("library-game")
    private let title=label(.systemFont(ofSize:NSFont.systemFontSize,weight:.semibold)),details=label(.systemFont(ofSize:NSFont.smallSystemFontSize),.secondaryLabelColor),facts=label(.systemFont(ofSize:NSFont.smallSystemFontSize-1),.secondaryLabelColor)
    private let badge=ResultBadge()
    private var action:()->Void={}
    private var rowLabel=""
    /// The game this cell shows and opens.
    private(set) var boundRow:LibraryRow?
    init(){
        super.init(frame:.zero)
        let lines=NSStackView(views:[title,details,facts]);lines.orientation = .vertical;lines.alignment = .leading;lines.spacing=1;lines.translatesAutoresizingMaskIntoConstraints=false
        addSubview(lines);addSubview(badge)
        NSLayoutConstraint.activate([lines.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),lines.centerYAnchor.constraint(equalTo:centerYAnchor),
                                     badge.leadingAnchor.constraint(greaterThanOrEqualTo:lines.trailingAnchor,constant:8),badge.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),
                                     badge.firstBaselineAnchor.constraint(equalTo:title.firstBaselineAnchor)])
    }
    required init?(coder:NSCoder){nil}
    func show(_ row:LibraryRow,open:@escaping ()->Void){
        title.stringValue=row.title;details.stringValue=row.details;details.isHidden=row.details.isEmpty;facts.stringValue=row.facts ?? "";facts.isHidden=row.facts==nil
        badge.text=row.result;action=open;boundRow=row;rowLabel=row.accessibilityLabel;setAccessibilityIdentifier("library-row-"+row.id)
    }
    override func isAccessibilityElement()->Bool {true}
    override func accessibilityRole()->NSAccessibility.Role? {.button}
    override func accessibilityLabel()->String? {rowLabel}
    override func accessibilityChildren()->[Any]? {[]}
    override func accessibilityPerformPress()->Bool {action();return true}
}
/// The result in a rounded badge, hidden from accessibility (the row's label already ends with it).
final class ResultBadge:NSView {
    var text="" {didSet{field.stringValue=text;invalidateIntrinsicContentSize()}}
    private let field=label(.monospacedDigitSystemFont(ofSize:NSFont.smallSystemFontSize-1,weight:.medium))
    init(){
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;wantsLayer=true;addSubview(field)
        field.setContentCompressionResistancePriority(.required,for:.horizontal)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6),field.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),field.topAnchor.constraint(equalTo:topAnchor,constant:2),field.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-2)])
    }
    required init?(coder:NSCoder){nil}
    override var firstBaselineOffsetFromTop:CGFloat {field.firstBaselineOffsetFromTop+2}
    override func updateLayer(){layer?.cornerRadius=bounds.height/2;layer?.backgroundColor=NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor}
    override func layout(){super.layout();needsDisplay=true}
    override var wantsUpdateLayer:Bool {true}
    override func isAccessibilityElement()->Bool {false}
}
/// An event's header: the whole line toggles the event, with a chevron that turns, as a named button whose value says
/// whether the event is expanded. A search shows every match, so it is disabled while searching.
final class EventHeaderCell:NSTableCellView {
    static let identifier=NSUserInterfaceItemIdentifier("library-event")
    private let button=HeaderButton()
    init(){
        super.init(frame:.zero);button.translatesAutoresizingMaskIntoConstraints=false;addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo:leadingAnchor,constant:2),button.trailingAnchor.constraint(equalTo:trailingAnchor),button.centerYAnchor.constraint(equalTo:centerYAnchor,constant:3)])
    }
    required init?(coder:NSCoder){nil}
    func show(_ section:LibrarySection,open:Bool,enabled:Bool,toggle:@escaping ()->Void){button.show(section,open:open,enabled:enabled,toggle:toggle)}
}
/// The role VoiceOver announces as a heading (what SwiftUI's header trait produced before).
let headingRole=NSAccessibility.Role(rawValue:"AXHeading")
final class HeaderButton:NSButton {
    private var toggle:()->Void={},open=true
    init(){
        super.init(frame:.zero);isBordered=false;bezelStyle = .inline;setButtonType(.momentaryChange);imagePosition = .imageLeading;alignment = .left;imageHugsTitle=true
        target=self;action=#selector(pressed);lineBreakMode = .byTruncatingTail;setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    }
    required init?(coder:NSCoder){nil}
    func show(_ section:LibrarySection,open:Bool,enabled:Bool,toggle:@escaping ()->Void){
        self.toggle=toggle;self.open=open;isEnabled=enabled
        let configuration=NSImage.SymbolConfiguration(pointSize:9,weight:.semibold)
        image=NSImage(systemSymbolName:open ? "chevron.down":"chevron.right",accessibilityDescription:nil)?.withSymbolConfiguration(configuration);contentTintColor = .secondaryLabelColor
        attributedTitle=NSAttributedString(string:" "+section.title,attributes:[.font:NSFont.systemFont(ofSize:NSFont.smallSystemFontSize,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor])
        setAccessibilityLabel(section.title);setAccessibilityIdentifier("library-section-"+section.id)
        setAccessibilityHelp(open ? "Hides this event's games.":"Shows this event's games.")
    }
    @objc private func pressed(){toggle()}
    override func accessibilityValue()->Any? {open ? "expanded":"collapsed"}
    // Announced as the event's heading; it keeps its press action, value and hint, so it still discloses the event.
    override func accessibilityRole()->NSAccessibility.Role? {headingRole}
}
/// A menu item's action, kept alive by the item that runs it.
final class MenuAction:NSObject {
    private let perform:()->Void
    init(_ perform:@escaping ()->Void){self.perform=perform}
    @objc func run(){perform()}
}
/// A Classics or collection header; a collection's has Rename… and Remove… buttons (Remove asks before removing).
final class SectionHeaderCell:NSTableCellView {
    static let identifier=NSUserInterfaceItemIdentifier("library-section")
    private let title=label(.systemFont(ofSize:NSFont.smallSystemFontSize,weight:.semibold),.secondaryLabelColor)
    private let rename=NSButton(title:"Rename…",target:nil,action:nil),remove=NSButton(title:"Remove…",target:nil,action:nil)
    private var onRename:()->Void={},onRemove:()->Void={}
    init(){
        super.init(frame:.zero)
        for button in [rename,remove]{button.bezelStyle = .inline;button.isBordered=false;button.controlSize = .small;button.font = .systemFont(ofSize:NSFont.smallSystemFontSize);button.contentTintColor = .controlAccentColor;button.target=self;button.translatesAutoresizingMaskIntoConstraints=false}
        rename.action=#selector(renamePressed);remove.action=#selector(removePressed)
        addSubview(title);addSubview(rename);addSubview(remove);title.setAccessibilityRole(headingRole)
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),title.centerYAnchor.constraint(equalTo:centerYAnchor,constant:3),
                                     rename.leadingAnchor.constraint(greaterThanOrEqualTo:title.trailingAnchor,constant:8),remove.leadingAnchor.constraint(equalTo:rename.trailingAnchor,constant:4),
                                     remove.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),rename.centerYAnchor.constraint(equalTo:title.centerYAnchor),remove.centerYAnchor.constraint(equalTo:title.centerYAnchor)])
    }
    required init?(coder:NSCoder){nil}
    func show(_ section:LibrarySection,rename onRename:@escaping ()->Void,remove onRemove:@escaping ()->Void){
        title.stringValue=section.title;self.onRename=onRename;self.onRemove=onRemove
        let collection=section.id.hasPrefix("collection:");remove.isHidden = !collection
        // A collection that could not be read keeps Remove…, but has no name file to rename until it reads again.
        rename.isHidden = !(collection && section.kind == .collection(nil))
        if collection{
            let sha=String(String(section.id.dropFirst("collection:".count)).prefix(12))
            remove.setAccessibilityLabel("Remove collection "+section.title);remove.setAccessibilityIdentifier("library-remove-"+sha)
            rename.setAccessibilityLabel("Rename collection "+section.title);rename.setAccessibilityIdentifier("library-rename-"+sha)
        }
    }
    @objc private func renamePressed(){onRename()}
    @objc private func removePressed(){onRemove()}

}
/// A collection that could not be read: its error, in the error colour.
final class BrokenCell:NSTableCellView {
    static let identifier=NSUserInterfaceItemIdentifier("library-broken")
    private let message=label(.systemFont(ofSize:NSFont.smallSystemFontSize),NativeColors.error)
    init(){
        super.init(frame:.zero)
        let icon=NSImageView(image:NSImage(systemSymbolName:"exclamationmark.triangle",accessibilityDescription:nil) ?? NSImage());icon.contentTintColor=NativeColors.error;icon.translatesAutoresizingMaskIntoConstraints=false
        addSubview(icon);addSubview(message)
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),icon.centerYAnchor.constraint(equalTo:centerYAnchor),message.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),message.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-6),message.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    required init?(coder:NSCoder){nil}
    func show(_ broken:BrokenCollection){message.stringValue=broken.error;setAccessibilityLabel("This collection could not be read: "+broken.error)}
    override func isAccessibilityElement()->Bool {true}
    override func accessibilityRole()->NSAccessibility.Role? {.staticText}
}
