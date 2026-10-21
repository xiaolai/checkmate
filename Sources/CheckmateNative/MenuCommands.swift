import AppKit
import UniformTypeIdentifiers
import CheckmateCore
/// What Edit ▸ Copy FEN and Copy PGN, File ▸ Export… and Share read (R-14): the position and game the board shows.
/// A network game gives nothing, so no position leaves the app while a game against another person is on (fairness).
struct ShownRecord:Equatable {
    let fen:String?,pgn:String?
    static func make(mode:NativeMode,fen:String?,pgn:String?)->ShownRecord? {
        guard mode != .network else{return nil}
        let record=ShownRecord(fen:fen.flatMap{$0.isEmpty ? nil:$0},pgn:pgn.flatMap{$0.isEmpty ? nil:$0})
        return record.fen==nil && record.pgn==nil ? nil:record
    }
}
extension NativeModel {
    /// A review gives its shown position and, when it has moves, its original record; practice gives its position and,
    /// once a move is played, its game. Lessons, puzzles, training and the review library give nothing.
    var shownRecord:ShownRecord? {
        if reviewWorkspace{return nil}
        if review.active{return ShownRecord.make(mode:session.mode,fen:session.displayFen,pgn:review.document.flatMap{$0.historyAvailable ? String(data:$0.original,encoding:.utf8):nil})}
        guard session.mode == .practice else{return nil}
        let pgn=session.rules.history.isEmpty ? nil:(try? ReviewRecordSource.data(session.rules,result:session.state.practice.ending?.result)).flatMap{String(data:$0,encoding:.utf8)}
        return ShownRecord.make(mode:.practice,fen:session.displayFen,pgn:pgn)
    }
}
/// The files File ▸ Open… offers (R-15): PGN and FEN, as declared in Info.plist or as another app names them, and plain text.
enum ReviewFileTypes {
    static let pgn=UTType(importedAs:"org.chessprogramming.pgn",conformingTo:.plainText),fen=UTType(importedAs:"org.chessprogramming.fen",conformingTo:.plainText)
    static var openable:[UTType] {["pgn","fen"].compactMap{UTType(filenameExtension:$0)}.reduce(into:[pgn,fen]){if !$0.contains($1){$0.append($1)}}+[.plainText]}
}
/// File ▸ Open Recent's list (R-15): the system's recent documents, or a list in memory for tests and automation.
@MainActor struct RecentFiles {
    var urls:()->[URL],note:(URL)->Void,clear:()->Void
    static var documents:RecentFiles {RecentFiles(urls:{NSDocumentController.shared.recentDocumentURLs},note:{NSDocumentController.shared.noteNewRecentDocumentURL($0)},clear:{NSDocumentController.shared.clearRecentDocuments(nil)})}
    static func memory()->RecentFiles {final class List{var urls:[URL]=[]};let list=List();return RecentFiles(urls:{list.urls},note:{url in list.urls.removeAll{$0==url};list.urls.insert(url,at:0);list.urls=Array(list.urls.prefix(10))},clear:{list.urls=[]})}
}
/// The menu bar's commands that are the app's rather than the window's: Help, About, updates, copying and recent files.
extension AppDelegate:NSMenuDelegate {
    static let shareID=NSUserInterfaceItemIdentifier("file-share")
    /// Automatic checks run at launch only when the learner turned them on, and never in automation or tests (V-19).
    static func checksAutomatically(settings:AppSettings,silent:Bool)->Bool {settings.checkForUpdates && !silent}
    private var dataDirectory:URL {model?.store.directory ?? StateStore.defaultDirectory()}
    @objc func showAbout(){presentAbout([.credits:AboutPane.credits])}
    @objc func showHelp(){if help==nil{help=HelpWindow()};help?.showWindow(nil);help?.window?.makeKeyAndOrderFront(nil)}
    @objc func reportProblem(){AboutPane.open(AboutPane.reportProblem,dataDirectory:dataDirectory)}
    @objc func checkForUpdates(){Task{await runUpdateCheck(automatic:false)}}
    /// A check the learner asked for always answers; an automatic one speaks only when there is a newer release.
    func runUpdateCheck(automatic:Bool) async {
        let current=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",outcome=await updateChecker.check(current:current),alert=NSAlert()
        switch outcome {
        case .available(let release):
            alert.messageText=String(localized:"Checkmate \(release.version) is available.",bundle:.checkmate);alert.informativeText=String(localized:"You have version \(current). Download the new version from GitHub, or update it with Homebrew.",bundle:.checkmate);alert.addButton(withTitle:String(localized:"Download",bundle:.checkmate));alert.addButton(withTitle:String(localized:"Later",bundle:.checkmate))
            if presentUpdateAlert(alert) == .alertFirstButtonReturn{AboutPane.open(release.page,dataDirectory:dataDirectory)}
        case .current(let version):
            guard !automatic else{return};alert.messageText=String(localized:"Checkmate is up to date.",bundle:.checkmate);alert.informativeText=String(localized:"Version \(version) is the latest release.",bundle:.checkmate);_ = presentUpdateAlert(alert)
        case .failed:
            guard !automatic else{return};alert.messageText=String(localized:"Checkmate couldn’t check for updates.",bundle:.checkmate);alert.informativeText=String(localized:"Check your internet connection, then try again.",bundle:.checkmate);_ = presentUpdateAlert(alert)
        }
    }
    private func copy(_ text:String?){guard let text else{return};pasteboard.clearContents();pasteboard.setString(text,forType:.string)}
    @objc func copyFEN(){copy(model?.shownRecord?.fen)}
    @objc func copyPGN(){copy(model?.shownRecord?.pgn)}
    /// File ▸ Export…: a review exports as its own Export does; a practice game saves as a PGN file.
    @objc func exportShown(){
        guard let model else{return};if model.review.active{model.exportReview();return}
        guard let pgn=model.shownRecord?.pgn else{return}
        let panel=NSSavePanel();panel.nameFieldStringValue=Self.practiceExportName;panel.allowedContentTypes=[ReviewFileTypes.pgn]
        panel.begin{[weak model] response in guard response == .OK,let url=panel.url else{return};do{try Data(pgn.utf8).write(to:url,options:.atomic)}catch{model?.storageError=String(localized:"The game could not be exported. Choose another location.",bundle:.checkmate)}}
    }
    var canExport:Bool {model?.mayExportReview==true || model?.shownRecord?.pgn != nil}
    /// A practice game exports under the name reviewing it would: its record has no players, so its own name.
    static var practiceExportName:String {PGNExporter.fileName(ReviewProvenance.currentGame.ownGameTitle ?? "",pgn:true)}
    /// The system's Share menu for the shown game (or position), and a disabled Share when there is nothing to share.
    func shareMenuItem()->NSMenuItem {
        let item:NSMenuItem
        if let text=model?.shownRecord.flatMap({$0.pgn ?? $0.fen}){let picker=NSSharingServicePicker(items:[text]);sharePicker=picker;item=picker.standardShareMenuItem}else{item=NSMenuItem(title:String(localized:"Share",bundle:.checkmate),action:nil,keyEquivalent:"");item.isEnabled=false}
        item.title=String(localized:"Share",bundle:.checkmate);item.identifier=Self.shareID;return item
    }
    @objc func openRecent(_ sender:NSMenuItem){guard let url=sender.representedObject as? URL else{return};application(NSApp,open:[url])}
    @objc func clearRecents(){recents.clear()}
    func menuNeedsUpdate(_ menu:NSMenu) {
        if menu === recentMenu {
            menu.removeAllItems();let urls=recents.urls()
            for url in urls{let item=NSMenuItem(title:url.lastPathComponent,action:#selector(openRecent(_:)),keyEquivalent:"");item.target=self;item.representedObject=url;item.toolTip=url.path;menu.addItem(item)}
            if !urls.isEmpty{menu.addItem(.separator())}
            let clear=NSMenuItem(title:String(localized:"Clear Menu",bundle:.checkmate),action:#selector(clearRecents),keyEquivalent:"");clear.target=self;clear.isEnabled = !urls.isEmpty;menu.addItem(clear)
        }
        if menu === fileMenu,let index=menu.items.firstIndex(where:{$0.identifier==Self.shareID}){menu.removeItem(at:index);menu.insertItem(shareMenuItem(),at:index)}
    }
}
