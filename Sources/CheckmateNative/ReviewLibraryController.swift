import AppKit
import UniformTypeIdentifiers
import CheckmateCore
/// The review workspace's game library: the bundled games and the learner's imported collections, loaded and indexed off
/// the main actor. Opening a row starts a draft review through the model's ordinary cancellable parse; nothing here is a
/// saved review, so MCP sees an entry only once the learner saves a review of it.
/// One line of the library list.
enum LibraryListItem {
    case header(LibrarySection),broken(String,BrokenCollection),row(LibraryRow)
    var id:String {switch self {case .header(let section):"header:"+section.id;case .broken(let id,_):"broken:"+id;case .row(let row):row.id}}
}
@MainActor final class ReviewLibraryController:ObservableObject {
    /// A free download page of World Championship PGN files; downloaded files can be imported as a collection.
    static let moreGamesURL=URL(string:"https://www.pgnmentor.com/files.html#world")!
    static let collectionProvenance="Collection game"
    enum Bundled:Equatable {case loading,loaded(GameLibrary),failed(String)}
    @Published private(set) var bundled:Bundled = .loading
    @Published private(set) var catalog=LibraryCatalog(library:nil,collections:[]){didSet{refilter()}}
    /// The sections for the current scope and query, filtered once per change: the view and its keyboard handling
    /// read this instead of filtering every row on each evaluation of its body.
    @Published private(set) var shown:[LibrarySection]=[]
    @Published private(set) var importing:String?
    /// The browser's search, scope and collapsed events live here, so they survive the workspace being hidden.
    @Published var query=""{didSet{if query != oldValue{refilter()}}}
    @Published var scope:LibraryScope = .all{didSet{if scope != oldValue{refilter()}}}
    @Published var collapsed:Set<String>=[]{didSet{if collapsed != oldValue{refilter()}}}
    /// The selected game row, kept only while that row is on screen: Return never opens a game a search, scope or
    /// collapse has hidden.
    @Published var selection:String?
    /// Bumped by ↓ in the search field: the list takes keyboard focus.
    @Published private(set) var listFocusRequests=0
    /// Bumped by Edit ▸ Find… while the workspace shows: the search field takes focus.
    @Published private(set) var findRequests=0
    let store:GameCollectionStore
    weak var model:NativeModel?
    private var loadTask:Task<Void,Never>?,importTask:Task<Void,Never>?
    private var importToken:ReviewImportCancellation?
    private var collections:[CollectionIndex]=[],broken:[BrokenCollection]=[]
    /// Bumped by every change this controller makes to `collections`: a disk load that started before a change is stale.
    private var collectionsGeneration=0
    /// The collections generation at each collection's latest removal: an import that started earlier is not published.
    private var removedAt:[String:Int]=[:]
    /// Collections being removed: their games no longer open.
    private(set) var removing:Set<String>=[]
    private var catalogGeneration=0,openGeneration=0
    /// Which collection the review being opened came from, so removing that collection cancels the open.
    private(set) var openingCollection:String?
    var automationImportDelayMs=0
    init(directory:URL){store=GameCollectionStore(directory:directory)}
    var loaded:Bool {if case .loaded=bundled{return true};return false}
    func requestFind(){findRequests+=1}
    /// Bumped with every refilter, so the view reacts to new results without comparing thousands of rows.
    @Published private(set) var shownVersion=0
    /// The lines of the list exactly as drawn: each section's header, a broken collection's error, and the games of
    /// every open section (a search opens every event). Built once per change; the table only renders it.
    private(set) var items:[LibraryListItem]=[]
    /// The game rows on screen, in order: keyboard navigation and Return only ever reach these.
    var visibleRows:[LibraryRow] {items.compactMap{if case .row(let row)=$0{return row};return nil}}
    /// An event's games show unless it is collapsed; a search shows every match, collapsed or not.
    func isOpen(_ id:String)->Bool {!collapsed.contains(id) || !query.isEmpty}
    func toggle(_ id:String){guard query.isEmpty else{return};if collapsed.contains(id){collapsed.remove(id)}else{collapsed.insert(id)}}
    private func refilter(){
        shown=catalog.sections(scope:scope,query:query)
        items=shown.flatMap{section -> [LibraryListItem] in
            var list:[LibraryListItem]=[.header(section)]
            if case .collection(let broken?)=section.kind{list.append(.broken(section.id,broken))}
            return section.kind == .event && !isOpen(section.id) ? list:list+section.rows.map{.row($0)}
        }
        if let selection,!items.contains(where:{$0.id==selection}){self.selection=nil}
        shownVersion+=1
    }
    /// ↓ from the search field: the first game on screen is selected and the list takes focus.
    func moveIntoList(){if let first=visibleRows.first{selection=first.id};listFocusRequests+=1}
    /// Return (in the field or the list) opens the selected game, if it is on screen.
    func openSelection(){guard let selection,let row=visibleRows.first(where:{$0.id==selection}) else{return};open(row)}
    /// Reads the bundled library and every collection once; later imports and removals update the catalog in place.
    func load(){
        guard loadTask==nil else{return}
        let store=store
        loadTask=Task{
            let library=await Task.detached{Result{try GameLibrary.load()}}.value
            switch library {case .success(let library):bundled = .loaded(library);case .failure(let error):bundled = .failed(userFacingMessage(error,fallback:"The game library could not be loaded."))}
            // A read that an import or removal overtook is stale: it is discarded and the folder read again.
            while !Task.isCancelled {
                let started=collectionsGeneration
                let found=await Task.detached{Result{try store.load()}}.value
                guard collectionsGeneration==started else{continue}
                switch found {case .success(let found):collections=found.collections;broken=found.broken;case .failure(let error):collections=[];broken=[BrokenCollection(id:String(repeating:"0",count:64),name:"My games",error:userFacingMessage(error,fallback:"Your collections could not be read."))]}
                break
            }
            rebuild()
        }
    }
    /// Reads everything again from disk, as the first load does (used by the timing scenario after it writes a collection).
    func reload(){loadTask?.cancel();loadTask=nil;load()}
    /// The catalog (every row and folded search key) is built off the main actor; only the latest build is published.
    private func rebuild(){
        catalogGeneration+=1;let generation=catalogGeneration
        let library:GameLibrary?={if case .loaded(let library)=bundled{return library};return nil}(),collections=collections,broken=broken
        Task{
            let built=await Task.detached{LibraryCatalog(library:library,collections:collections,broken:broken)}.value
            guard catalogGeneration==generation else{return}
            publish(built)
        }
    }
    /// Shows a built catalog (also how the table tests give the controller its lines).
    func publish(_ built:LibraryCatalog){catalog=built}
    /// Automation only: while set, a library open holds after reading its record, before it may start a parse, until
    /// released. It lets the scenario prove that the newest open wins even when an older parse would finish first.
    /// Outside isolated automation `NativePolicy.silent` is false and this is never consulted.
    var automationHoldReads=false
    private var heldReads:[CheckedContinuation<Void,Never>]=[]
    func automationReleaseReads(){automationHoldReads=false;let held=heldReads;heldReads=[];held.forEach{$0.resume()}}
    private func automationBarrier()async {guard NativePolicy.silent,automationHoldReads else{return};await withCheckedContinuation{heldReads.append($0)}}
    func open(_ row:LibraryRow){
        guard let model else{return}
        let fallback="This game could not be opened for review. Your current game and reviews are unchanged."
        // The newest request wins: a review still being parsed is cancelled now, before this one is read, so it cannot
        // finish (and replace the activity) while this one loads.
        if model.importingReview{model.cancelReviewImport()}
        // Both generations are captured: a newer open here, or any navigation in the model (practice, another review),
        // makes this read stale, and a stale read never starts a parse.
        openGeneration+=1;let generation=openGeneration,activity=model.activityGeneration,store=store
        switch row.source {
        case .bundled(let game):
            guard case .loaded(let library)=bundled else{return}
            openingCollection=nil
            Task{
                let read=await Task.detached{Result{try library.data(game)}}.value
                await automationBarrier()
                guard openGeneration==generation,model.activityGeneration==activity else{return}
                switch read {
                case .success(let data):model.openLibraryRecord(data,provenance:GameLibrary.provenance,fallback:fallback){try GameLibrary.verify($0,matches:game)}
                case .failure(let error):model.storageError=userFacingMessage(error,fallback:fallback)
                }
            }
        case .collection(let sha,let record):
            guard !removing.contains(sha),let collection=collections.first(where:{$0.sha256==sha}) else{return}
            openingCollection=sha
            Task{
                // Read and hashed off the main actor; a removal or a newer open in the meantime wins.
                let read=await Task.detached{Result{try store.data(record,in:collection)}}.value
                await automationBarrier()
                guard openGeneration==generation,model.activityGeneration==activity,!removing.contains(sha),collections.contains(where:{$0.sha256==sha}) else{return}
                switch read {
                case .success(let data):model.openLibraryRecord(data,provenance:Self.collectionProvenance,fallback:"This game could not be read. It is skipped; the rest of the collection is unchanged.")
                case .failure(let error):model.storageError=userFacingMessage(error,fallback:fallback)
                }
            }
        }
    }
    /// "Import Collection…": the open panel, then an import off the main actor.
    func chooseCollection(startingIn directory:URL?=nil){
        let panel=NSOpenPanel();panel.allowsOtherFileTypes=true;panel.allowsMultipleSelection=false;panel.prompt="Import";panel.message="Choose a PGN file to add to My games."
        if let pgn=UTType(filenameExtension:"pgn"){panel.allowedContentTypes=[pgn,.plainText]}
        if let directory{panel.directoryURL=directory}
        panel.begin{[weak self] response in guard response == .OK,let url=panel.url else{return};self?.importCollection(url)}
    }
    /// One import at a time, cancellable; the file is checked and read with the drop's bounded reader.
    func importCollection(_ url:URL){
        cancelImport();let token=ReviewImportCancellation();importToken=token;importing=url.lastPathComponent
        let started=collectionsGeneration,store=store,delay=NativePolicy.silent ? min(5000,max(0,automationImportDelayMs)):0,name=url.lastPathComponent
        importTask=Task{
            do{
                if delay>0{try await Task.sleep(for:.milliseconds(delay))}
                let index=try await withTaskCancellationHandler(operation:{try await Task.detached{try store.importCollection(ReviewDrop.bounded(ReviewDrop.validated(url)),name:name,cancelled:{token.cancelled})}.value},onCancel:{token.cancel()})
                guard !Task.isCancelled,importToken===token else{return}
                importing=nil;importToken=nil
                // Removed after this import began: the removal wins and the rows stay gone.
                guard !removing.contains(index.sha256),(removedAt[index.sha256] ?? -1)<started else{return}
                collectionsGeneration+=1
                if !collections.contains(where:{$0.sha256==index.sha256}){collections.append(index)};broken.removeAll{$0.id==index.sha256};rebuild()
                if index.unreadable>0{model?.storageError="\(index.unreadable) game\(index.unreadable==1 ? "":"s") in \(PGNImporter.bounded(name,scalars:80)) could not be read and \(index.unreadable==1 ? "was":"were") skipped."}
            }catch{
                guard importToken===token else{return};importing=nil;importToken=nil
                if case CheckmateError.cancelled=error{return};if Task.isCancelled{return}
                model?.storageError=(error as? ReviewDrop.Rejection)?.reason ?? userFacingMessage(error,fallback:"This file could not be imported. Your library is unchanged.")
            }
        }
    }
    func cancelImport(){importToken?.cancel();importTask?.cancel();importTask=nil;importToken=nil;importing=nil}
    func requestRemove(_ collection:CollectionIndex){requestRemove(collection.sha256,name:collection.name,games:collection.records.count)}
    /// Every removal is confirmed, a broken collection's included: its file may still be recoverable.
    func requestRemove(_ sha:String,name:String,games:Int?){
        let alert=NSAlert();alert.messageText="Remove “\(PGNImporter.bounded(name,scalars:80))”?"
        alert.informativeText=games.map{"Its \($0) game\($0==1 ? "":"s") leave My games. Reviews you saved from them are kept."} ?? "Its file is deleted from My games. Reviews you saved from it are kept."
        let removeButton=alert.addButton(withTitle:"Remove");removeButton.keyEquivalent="";let cancel=alert.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r";alert.window.defaultButtonCell=cancel.cell as? NSButtonCell
        if let window=NSApp.mainWindow{alert.beginSheetModal(for:window){[weak self] response in if response == .alertFirstButtonReturn{self?.remove(sha)}}}
        else if alert.runModal() == .alertFirstButtonReturn{remove(sha)}
    }
    func remove(_ sha:String){
        // Marked at once: its games stop opening, and an import of it still in flight is not published.
        removing.insert(sha);collectionsGeneration+=1;removedAt[sha]=collectionsGeneration;openGeneration+=1
        // An open of one of its games still parsing is cancelled with it; the store cancels an import of the same file.
        if openingCollection==sha,model?.importingReview==true{model?.cancelReviewImport()};if openingCollection==sha{openingCollection=nil}
        let store=store
        Task{
            defer{removing.remove(sha)}
            do{try await Task.detached{try store.remove(sha)}.value;collectionsGeneration+=1;collections.removeAll{$0.sha256==sha};broken.removeAll{$0.id==sha};rebuild()}
            catch{model?.storageError=userFacingMessage(error,fallback:"The collection could not be removed. Try again.")}
        }
    }
    func collection(_ sha:String)->CollectionIndex? {collections.first{$0.sha256==sha}}
    func openMoreGames(){NSWorkspace.shared.open(Self.moreGamesURL)}
}
