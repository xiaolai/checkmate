import AppKit
import Combine
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
    static let collectionProvenance=ReviewProvenance.collectionGame
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
    /// The order of the games within each section (R-21).
    @Published var sort:LibrarySort = .standard{didSet{if sort != oldValue{refilter()}}}
    /// The selected game row, kept only while that row is on screen: Return never opens a game a search, scope or
    /// collapse has hidden.
    @Published var selection:String?{didSet{if selection != oldValue{updatePreview()}}}
    /// The selected game as the workspace's inspector previews it (R-26), read and parsed off the main actor.
    @Published private(set) var preview:LibraryPreview?
    private var previewTask:Task<Void,Never>?
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
    /// The saved reviews' index as the model last published it, shown in the Saved scope (R-11).
    private var savedEntries:[ReviewIndexEntry]=[]
    private var savedFollower:AnyCancellable?
    /// A collection just imported from a many-game record: once its rows are on screen its first game is selected.
    private var revealing:String?
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
        shown=catalog.sections(scope:scope,query:query,sort:sort)
        items=shown.flatMap{section -> [LibraryListItem] in
            var list:[LibraryListItem]=[.header(section)]
            if case .collection(let broken?)=section.kind{list.append(.broken(section.id,broken))}
            return section.kind == .event && !isOpen(section.id) ? list:list+section.rows.map{.row($0)}
        }
        if let selection,!items.contains(where:{$0.id==selection}){self.selection=nil}
        if let sha=revealing,let first=shown.first(where:{$0.id=="collection:"+sha})?.rows.first{revealing=nil;selection=first.id}
        // A renamed review or collection keeps its selection; its preview is read again under the new name.
        if let preview,let row=visibleRows.first(where:{$0.id==preview.id}),row.title != preview.title{self.preview=nil;updatePreview()}
        shownVersion+=1
    }
    private func updatePreview(){
        previewTask?.cancel();previewTask=nil
        guard let selection,let row=visibleRows.first(where:{$0.id==selection}) else{preview=nil;return}
        guard preview?.id != row.id else{return}
        let store=store,reviews=model?.reviewStore,library:GameLibrary?={if case .loaded(let library)=bundled{return library};return nil}()
        let collection:CollectionIndex?={if case .collection(let sha,_)=row.source{return collections.first{$0.sha256==sha}};return nil}()
        previewTask=Task{
            let read=await Task.detached{Result{()throws -> GameDocument in
                let data:Data
                switch row.source {
                case .bundled(let game):guard let library else{throw CheckmateError.invalid("The game library is not loaded.")};data=try library.data(game)
                case .collection(_,let record):guard let collection else{throw CheckmateError.invalid("This collection is no longer in the library.")};data=try store.data(record,in:collection)
                case .saved(let id):guard let reviews else{throw CheckmateError.invalid("Saved reviews are not available.")};return try reviews.load(id).document
                }
                guard let document=try PGNImporter.parse(data).first else{throw CheckmateError.invalid("No game was found in this record.")}
                return document
            }}.value
            guard !Task.isCancelled,self.selection==row.id else{return}
            switch read {
            case .success(let document):preview = .of(row,document:document)
            case .failure(let error):preview = .unreadable(row,userFacingMessage(error,fallback:"This game could not be read."))
            }
        }
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
            publish(built.with(saved:savedEntries))
        }
    }
    /// Shows a built catalog (also how the table tests give the controller its lines).
    func publish(_ built:LibraryCatalog){catalog=built}
    /// The Saved scope follows the model's index of saved reviews, most recent first.
    func follow(_ reviews:Published<[ReviewIndexEntry]>.Publisher){savedFollower=reviews.sink{[weak self] entries in MainActor.assumeIsolated{self?.showSaved(entries)}}}
    func showSaved(_ entries:[ReviewIndexEntry]){guard entries != savedEntries else{return};savedEntries=entries;catalog=catalog.with(saved:entries)}
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
        case .saved(let id):
            openingCollection=nil;model.openSavedReview(id)
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
    func importCollection(_ url:URL){importCollection(label:url.lastPathComponent,name:url.lastPathComponent,reveal:false){try ReviewDrop.bounded(ReviewDrop.validated(url))}}
    /// A record of many games opened, pasted or dropped for review (R-9) joins My games as a collection, named after its
    /// games' event, and its first game is selected for the learner to open.
    func importCollection(_ data:Data){scope = .myGames;query="";importCollection(label:"games",name:nil,reveal:true){data}}
    private func importCollection(label:String,name:String?,reveal:Bool,read:@escaping @Sendable ()throws->Data){
        cancelImport();let token=ReviewImportCancellation();importToken=token;importing=label;revealing=nil
        let started=collectionsGeneration,store=store,delay=NativePolicy.silent ? min(5000,max(0,automationImportDelayMs)):0
        importTask=Task{
            do{
                if delay>0{try await Task.sleep(for:.milliseconds(delay))}
                let index=try await withTaskCancellationHandler(operation:{try await Task.detached{try store.importCollection(read(),name:name,cancelled:{token.cancelled})}.value},onCancel:{token.cancel()})
                guard !Task.isCancelled,importToken===token else{return}
                importing=nil;importToken=nil
                // Removed after this import began: the removal wins and the rows stay gone.
                guard !removing.contains(index.sha256),(removedAt[index.sha256] ?? -1)<started else{return}
                collectionsGeneration+=1
                if reveal{revealing=index.sha256;collapsed.remove("collection:"+index.sha256)}
                if !collections.contains(where:{$0.sha256==index.sha256}){collections.append(index)};broken.removeAll{$0.id==index.sha256};rebuild()
                if index.unreadable>0{model?.storageError=Plural.count(index.unreadable,one:"%1$d game in %2$@ could not be read and was skipped.",other:"%1$d games in %2$@ could not be read and were skipped.",PGNImporter.bounded(index.name,scalars:80))}
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
        let alert=NSAlert.destructive("Remove “\(PGNImporter.bounded(name,scalars:80))”?",games.map{Plural.count($0,one:"Its %d game leaves My games. Reviews you saved from it are kept.",other:"Its %d games leave My games. Reviews you saved from them are kept.")} ?? "Its file is deleted from My games. Reviews you saved from it are kept.",action:"Remove")
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
    /// "Rename…" on a collection's header (R-21): the name is kept in the collection's name file.
    func requestRename(_ sha:String){
        guard let current=collection(sha) else{return}
        NSAlert.askName("Rename Collection",current:current.name,identifier:"collection-rename-field"){[weak self] name in self?.rename(sha,to:name)}
    }
    func rename(_ sha:String,to name:String){
        let store=store
        Task{
            do{
                try await Task.detached{try store.rename(sha,to:name)}.value
                let found=try await Task.detached{try store.load()}.value
                collectionsGeneration+=1;collections=found.collections;broken=found.broken;rebuild()
            }catch{model?.storageError=userFacingMessage(error,fallback:"The collection could not be renamed. Try again.")}
        }
    }
    func collection(_ sha:String)->CollectionIndex? {collections.first{$0.sha256==sha}}
    func openMoreGames(){NSWorkspace.shared.open(Self.moreGamesURL)}
}
