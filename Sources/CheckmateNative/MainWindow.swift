import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit
import CheckmateCore
final class BoardWindow:NSWindow {
    /// Arrow keys nothing focused handled step through the practice moves (`GameWindow.historyArrow`).
    override func keyDown(with event:NSEvent){if (windowController as? GameWindow)?.historyKey(event)==true{return};super.keyDown(with:event)}
    /// Edit ▸ Undo (⌘Z): a text field in focus handles it first; otherwise the window would answer it with its own
    /// empty undo manager and the game never heard it. It goes to the game window instead, which follows
    /// `NativeModel.undoAction`: a just-deleted review's restore, or the game's take back and undo turn.
    @objc func undo(_ sender:Any?){(windowController as? GameWindow)?.undo(sender)}
    override func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(undo(_:)),let controller=windowController as? GameWindow{return controller.validateMenuItem(item)}
        return super.validateMenuItem(item)
    }
    var drawerViewport:NSRect?,drawerOrigins:ClosedRange<CGFloat>?
    override func setFrame(_ frameRect:NSRect,display flag:Bool){var frame=frameRect;if let available=drawerViewport{frame.origin.x=max(available.minX,min(available.maxX-frame.width,frame.minX));frame.origin.y=max(available.minY,min(available.maxY-frame.height,frame.minY))};if let range=drawerOrigins{frame.origin.x=max(range.lowerBound,min(range.upperBound,frame.minX))};super.setFrame(frame,display:flag)}
}
/// Drawers have fixed widths and open only from their toolbar buttons. A dragged divider would collapse one
/// behind the controller's back: its toggle then needed two clicks and the board moved instead of the window edge.
/// The system's sidebar and inspector toggles (View menu, toolbar) drive the window's drawers, whose state is the
/// window's `desiredLeft`/`desiredRight` (D-5, D-6): the split items themselves never collapse.
final class DrawerSplitViewController:NSSplitViewController {
    var drawerOpen:(_ sidebar:Bool)->Bool={_ in false},toggleDrawer:(_ sidebar:Bool)->Void={_ in}
    override func splitView(_ splitView:NSSplitView,effectiveRect proposedEffectiveRect:NSRect,forDrawnRect drawnRect:NSRect,ofDividerAt dividerIndex:Int)->NSRect {.zero}
    override func toggleSidebar(_ sender:Any?){toggleDrawer(true)}
    override func toggleInspector(_ sender:Any?){toggleDrawer(false)}
    override func validateUserInterfaceItem(_ item:any NSValidatedUserInterfaceItem)->Bool {
        let sidebar=item.action == #selector(toggleSidebar(_:))
        guard sidebar || item.action == #selector(toggleInspector(_:)) else{return super.validateUserInterfaceItem(item)}
        (item as? NSMenuItem)?.title=GameWindow.drawerTitle(sidebar:sidebar,open:drawerOpen(sidebar));return true
    }
}
final class BoardTitleView:NSView {
    weak var board:NSView?
    let label=textLabel(String(localized:"Practice · White vs Stockfish",bundle:.checkmate),.title3,.semibold),tabs=NSSegmentedControl(labels:[String(localized:"Game",bundle:.checkmate),String(localized:"Demonstration",bundle:.checkmate)],trackingMode:.selectOne,target:nil,action:nil)
    override init(frame:NSRect){super.init(frame:frame);addSubview(label);addSubview(tabs);label.alignment = .center;tabs.isHidden=true}
    required init?(coder:NSCoder){fatalError()}
    override var mouseDownCanMoveWindow:Bool {true}
    override var intrinsicContentSize:NSSize {NSSize(width:300,height:28)}
    override func layout(){super.layout();syncCenter()}
    func syncCenter(){guard let board=board,let boardWindow=board.window,let ownWindow=window else{return};let screen=boardWindow.convertToScreen(NSRect(origin:board.convert(NSPoint(x:board.bounds.midX,y:0),to:nil),size:.zero)).origin;let center=convert(ownWindow.convertFromScreen(NSRect(origin:screen,size:.zero)).origin,from:nil).x;let reach=2*max(0,min(center,bounds.width-center)),labelWidth=min(300,reach,max(120,board.bounds.width-Metrics.padding*2)),tabWidth=min(280,labelWidth);label.frame=NSRect(x:center-labelWidth/2,y:4,width:labelWidth,height:20);tabs.frame=NSRect(x:center-tabWidth/2,y:0,width:tabWidth,height:28)}

}
@MainActor final class GameWindow:NSWindowController,NSWindowDelegate,NSToolbarDelegate,NSMenuItemValidation {
    let relationships=RelationshipController(),history=PracticeHistory()
    let model:NativeModel,board=BoardView(),split=DrawerSplitViewController(),main=NSViewController()
    var navigation:NSViewController!,inspector:NSViewController!
    let titleView=BoardTitleView(frame:NSRect(x:0,y:0,width:300,height:28))
    private(set) var controlsHeight:NSLayoutConstraint!
    /// Where the bar last laid out each control and its status, in the bar's coordinates (layout acceptance).
    private(set) var barFrames:[String:CGRect]=[:]
    var sidebarItem:NSSplitViewItem!,boardItem:NSSplitViewItem!,inspectorItem:NSSplitViewItem!,controls:NSHostingView<TransportContent>!,welcome:NSHostingView<WelcomeContent>!,puzzles:NSHostingView<PuzzleLibraryContent>!
    private var playbackLineView:NSView?
    private(set) var reviewWorkspaceView:NSHostingView<ReviewWorkspaceContent>!
    private var workspaceAboveControls:NSLayoutConstraint!,workspaceFill:NSLayoutConstraint!
    private(set) var trainingLibraryView:NSHostingView<TrainingLibraryHost>!
    var leftExtent:CGFloat {Metrics.left+split.splitView.dividerThickness}
    var rightExtent:CGFloat {Metrics.right+split.splitView.dividerThickness}
    var availableFrameOverride:NSRect?
    private var fullscreen=false,fullscreenTransition=false
    private var normalCoreFrame:NSRect?
    private var fullscreenWidth:NSLayoutConstraint?
    var desiredLeft=false,desiredRight=false,animating=false,fixedBoardWidth:NSLayoutConstraint?,settings:SettingsWindow?
    private var observations:Set<AnyCancellable>=[]
    /// Shows a promotion menu at a point of a view and returns whether an item was chosen; tests answer it without a
    /// modal menu loop.
    var presentPromotionMenu:(NSMenu,NSPoint,NSView)->Bool={menu,point,view in menu.popUp(positioning:menu.items.first,at:point,in:view)}
    private var coreFrame:NSRect?
    private var fittedLayout=false
    /// Where the window last stood when fitting or the learner placed it: while fitted, a move from here is the learner's
    /// and carries the preferred frame with it, so a later drawer change or relaunch keeps it.
    private var fittedOrigin:NSPoint?
    private var announcedReviewIdentity=""
    private(set) var errorBanner:NSHostingView<StorageErrorBanner>?
    func setCoreFrame(_ frame:NSRect){coreFrame=frame;fittedOrigin=nil;fixedBoardWidth?.constant=frame.width;fixedBoardWidth?.isActive=true;window?.setFrame(frame,display:true);fittedOrigin=window?.frame.origin;window?.contentView?.layoutSubtreeIfNeeded()}
    private let titleID=NSToolbarItem.Identifier("checkmate.title")
    init(model:NativeModel){self.model=model
        let w=BoardWindow(contentRect:NSRect(x:0,y:0,width:Metrics.core,height:Metrics.core),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:w);w.title=String(localized:"Checkmate",bundle:.checkmate);w.isMovableByWindowBackground=true;w.titleVisibility = .hidden;w.titlebarSeparatorStyle = .none;w.titlebarAppearsTransparent=true;w.isReleasedWhenClosed=false;w.isRestorable=false;w.delegate=self;w.autorecalculatesKeyViewLoop=true;w.identifier=NSUserInterfaceItemIdentifier("main");w.collectionBehavior=[.fullScreenPrimary];w.tabbingMode = .disallowed
        main.view=BackgroundView();navigation=NSHostingController(rootView:SidebarContent(session:model.session,learning:model.learning,model:model,network:model.network));inspector=ToolbarInsetHostingController(rootView:DetailContent(session:model.session,learning:model.learning,model:model,voice:model.voice,relationships:relationships,history:history,inspect:{[weak self] mode in self?.toggleRelationship(mode)}))
        split.drawerOpen={[unowned self] in $0 ? desiredLeft:desiredRight};split.toggleDrawer={[unowned self] in $0 ? toggleLeft():toggleRight()}
        _ = split.view;split.splitView.autoresizingMask=[.width,.height];split.splitView.isVertical=true;split.splitView.dividerStyle = .thin
        sidebarItem=NSSplitViewItem(sidebarWithViewController:navigation);boardItem=NSSplitViewItem(viewController:main);inspectorItem=NSSplitViewItem(inspectorWithViewController:inspector)
        for (item,width) in [(sidebarItem!,Metrics.left),(inspectorItem!,Metrics.right)] {item.minimumThickness=width;item.maximumThickness=width;item.automaticMaximumThickness=width;item.preferredThicknessFraction=NSSplitViewItem.unspecifiedDimension;item.holdingPriority = .defaultHigh;item.canCollapse=true;item.canCollapseFromWindowResize=false;item.allowsFullHeightLayout=true;item.collapseBehavior = .preferResizingSplitViewWithFixedSiblings;item.titlebarSeparatorStyle = .none;item.isCollapsed=true}
        boardItem.minimumThickness=Metrics.minimum;boardItem.titlebarSeparatorStyle = .none;split.addSplitViewItem(sidebarItem);split.addSplitViewItem(boardItem);split.addSplitViewItem(inspectorItem);w.contentViewController=split
        let leftLimit=navigation.view.widthAnchor.constraint(lessThanOrEqualToConstant:Metrics.left),rightLimit=inspector.view.widthAnchor.constraint(lessThanOrEqualToConstant:Metrics.right);leftLimit.priority=NSLayoutConstraint.Priority(999);rightLimit.priority=NSLayoutConstraint.Priority(999);NSLayoutConstraint.activate([leftLimit,rightLimit])
        let toolbar=NSToolbar(identifier:"Checkmate.Native.Toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false;w.toolbar=toolbar;w.toolbarStyle = .unified
        installBoardCallbacks();buildBoardArea();observeModel()
        let restored=WindowGeometry.restored(model.session.state.window.frame,screens:NSScreen.screens.map(\.visibleFrame),size:Double(Metrics.core),minimum:Double(Metrics.minimum))
        fixedBoardWidth=main.view.widthAnchor.constraint(equalToConstant:restored.width);fixedBoardWidth!.isActive=true
        coreFrame=restored;w.setFrame(restored,display:false);refresh()
        desiredLeft=model.session.state.window.left;desiredRight=model.session.state.window.right
        DispatchQueue.main.async{self.boardItem.minimumThickness=Metrics.minimum;self.animateDrawers();self.model.session.reply()}
    }
    required init?(coder:NSCoder){fatalError()}
    /// Board input and the model's navigation and import callbacks.
    private func installBoardCallbacks(){
        // A lesson or review just opened starts clean, with its guidance showing.
        let opened={[weak self] in guard let self else{return};self.relationships.dismiss();self.board.cancelAnimation();self.showDetails();self.refresh()}
        model.learning.onLessonOpened=opened;model.onReview=opened
        board.reviewKey={[weak self] key in guard let self=self,self.model.review.active,self.model.review.branch==nil else{return false};switch key{case 123:self.model.review.step(-1);case 124:self.model.review.step(1);case 125:self.model.review.last();case 126:self.model.review.first();case 49:self.model.review.playing ? self.model.review.pause():self.model.review.play();default:return false};self.refresh();return true}
        board.dropReview={[weak self] data in self?.model.importReviewData(data)};board.dropRejected={[weak self] reason in self?.model.storageError=reason}
        model.review.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        history.choose={[weak self] index in self?.showPracticeMove(index)};history.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        model.onImport={[weak self] in guard let self=self else{return};self.desiredLeft=self.model.session.state.window.left;self.desiredRight=self.model.session.state.window.right;self.animateDrawers()};board.onLayout={[weak self] in self?.titleView.needsLayout=true;self?.titleView.syncCenter()};board.activate={[weak self] square in self?.select(square)};board.canDrag={[weak self] square in self?.dragMoves(square) ?? false};model.movePlacedDirectly={[weak self] move in self?.board.isDropped(move) ?? false};board.inspectRelationship={[weak self] mode in self?.toggleRelationship(mode)};board.dismissRelationships={[weak self] in guard let self=self else{return false};let dismissed=self.relationships.dismiss();if dismissed{self.refresh()};return dismissed};board.clearSelection={[weak self] in guard let self=self else{return};if self.model.review.active{self.model.review.clearSelection();self.refresh()}else if self.model.session.mode == .network{self.model.network.clearSelection();self.refresh()}else if self.model.session.mode == .practice{self.model.session.clearSelection()}else if let training=self.model.training,self.trainingExercise != nil{training.clearSelection();self.refresh()}else{self.model.learning.clearSelection()}};titleView.board=board;titleView.tabs.target=self;titleView.tabs.action=#selector(selectTab)
    }
    /// The board area: transport, welcome card, puzzle and training libraries, error banner and playback line.
    private func buildBoardArea(){
        controls=VisibleHostingView(rootView:TransportContent(session:model.session,learning:model.learning,voice:model.voice,review:model.review,network:model.network,newGame:{[weak self] in self?.newGame()},showDetails:{[weak self] in self?.showDetails()},gameCommand:{[weak self] action in if action == .resign{self?.resign()}else if action == .flipBoard{self?.flipBoard()}},lowTime:NetworkLowTimeWarning{[weak model] in guard let model else{return};model.audio.lowTime(settings:model.session.state.settings)},continueWithStockfish:{[weak model] in model?.companion.disable();model?.session.continueWithStockfish()},resumeGame:{[weak model] in model?.resumeAfterFailedRestore()},training:model.training,openTrainingLibrary:{[weak model] in model?.trainingLibrary()},continueLesson:{[weak self] in guard let self else{return};self.model.continueLesson();self.announceLesson()},restartAttempt:{[weak model] in model?.requestRestartAttempt()},previousLessonEnd:{[weak self] in guard let self else{return};self.model.previousLessonEnd();self.announceLesson()},returnToOriginal:{[weak model] in guard let model else{return};model.review.clearBranch();model.saveReview()},rowsChanged:{[weak self] rows in self?.setControlRows(rows)},framesChanged:{[weak self] frames in self?.barFrames=frames},connectVoice:{[weak model] in model?.connectPracticeVoice()}));welcome=VisibleHostingView(rootView:WelcomeContent(title:""));puzzles=VisibleHostingView(rootView:PuzzleLibraryContent(learning:model.learning,session:model.session))
        reviewWorkspaceView=VisibleHostingView(rootView:ReviewWorkspaceContent(model:model))
        // The workspace fills the board area through its constraints; its list would otherwise feed a size back into them
        // that changes with every layout pass (an endless Update Constraints loop).
        reviewWorkspaceView.sizingOptions=[];trainingLibraryView=VisibleHostingView(rootView:TrainingLibraryHost(model:model))
        for v in [board,controls!,welcome!,puzzles!,reviewWorkspaceView!,trainingLibraryView!] {main.view.addSubview(v);v.translatesAutoresizingMaskIntoConstraints=false}
        controlsHeight=controls.heightAnchor.constraint(equalToConstant:Metrics.header)
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo:main.view.leadingAnchor),controls.trailingAnchor.constraint(equalTo:main.view.trailingAnchor),controls.bottomAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.bottomAnchor),controlsHeight])
        // Errors sit above the board area, which yields its top to the banner while one shows: a banner that
        // overlaid the board swallowed clicks on the eighth rank. The board stays square, only smaller.
        let banner=VisibleHostingView(rootView:StorageErrorBanner(model:model));errorBanner=banner;banner.isHidden=model.storageError==nil
        main.view.addSubview(banner);banner.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([banner.leadingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.leadingAnchor),banner.trailingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.trailingAnchor),banner.topAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.topAnchor)])
        model.$storageError.removeDuplicates().receive(on:RunLoop.main).sink{[weak self] message in guard let self=self else{return};self.errorBanner?.isHidden=message==nil;if let message=message{NSAccessibility.post(element:self.errorBanner as Any,notification:.announcementRequested,userInfo:[.announcement:message,.priority:NSAccessibilityPriorityLevel.high.rawValue])}}.store(in:&observations)
        let playbackLine=VisibleHostingView(rootView:LessonProgressContent(review:model.review,session:model.session,learning:model.learning))
        playbackLineView=playbackLine
        main.view.addSubview(playbackLine);playbackLine.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([playbackLine.leadingAnchor.constraint(equalTo:main.view.leadingAnchor),playbackLine.trailingAnchor.constraint(equalTo:main.view.trailingAnchor),playbackLine.bottomAnchor.constraint(equalTo:main.view.bottomAnchor),playbackLine.heightAnchor.constraint(equalToConstant:Metrics.playbackLineHeight)])
        // The transport is hidden while the workspace shows, so the workspace then runs down to the window's bottom edge
        // instead of keeping the transport's height empty.
        workspaceFill=reviewWorkspaceView.bottomAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.bottomAnchor,constant:-Metrics.smallGap)
        for v in [board,welcome!,puzzles!,reviewWorkspaceView!,trainingLibraryView!] {let top=v.topAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.topAnchor,constant:Metrics.smallGap);top.priority = .defaultHigh;NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.leadingAnchor,constant:Metrics.padding),v.trailingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.trailingAnchor,constant:-Metrics.padding),top,v.topAnchor.constraint(greaterThanOrEqualTo:banner.bottomAnchor)]);let bottom=v.bottomAnchor.constraint(equalTo:controls.topAnchor,constant:-Metrics.smallGap);bottom.isActive=true;if v===reviewWorkspaceView{workspaceAboveControls=bottom}}
    }
    /// Model changes refresh the window; moves animate and are announced.
    private func observeModel(){
        model.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        model.network.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        // The agreed hint's arrow follows the assistant (assistance plan A6). The inspector follows the agreed level
        // through the model, which redraws on every participation change.
        model.networkAssistant.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        // The squares the network game's coach is speaking about (A10) light up as it speaks, and go when it stops.
        model.voice.$networkFocus.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] _ in self?.refresh()}.store(in:&observations)
        // The training coach's spoken squares and highlights (mini-game plan WI-021) light up on the training board.
        model.voice.$trainingFocus.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] _ in self?.refresh()}.store(in:&observations)
        model.trainingVoice?.$marks.removeDuplicates().dropFirst().receive(on:RunLoop.main).sink{[weak self] _ in self?.refresh()}.store(in:&observations)
        // VoiceOver hears the network game's moves, offers, result and clocks (LAN-play plan D10).
        model.network.announce={[weak self] text in self?.announce(text)}
        // Voice failures and the coach's answers reach VoiceOver (V-21); a failure's button opens its Settings pane (V-27).
        model.voiceHelp.announce={[weak self] text in self?.announce(text)};model.voiceHelp.showSettings={[weak self] category in self?.openSettings(category:category)}
        // D11: the permission help appears only on the two denial signals, and goes once access comes back.
        model.network.$permissionHelp.removeDuplicates().receive(on:RunLoop.main).sink{[weak self] shown in self?.syncPermissionHelp(shown)}.store(in:&observations)
        // The network place's lobby and game chrome live in the details drawer: open it on arrival, as a lesson or review does.
        model.session.$activity.removeDuplicates().filter{$0 == .at(.network)}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.session.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations);model.learning.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        // A review read aloud keeps to its sheet: the drawer stays as it is.
        model.voice.$connection.map{$0 == .ready}.removeDuplicates().filter{$0}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,self.model.voice.miniReviewSession==nil else{return};self.showDetails()}.store(in:&observations)
        // These messages are shown only in the details drawer, which starts closed; open it when one appears.
        model.session.$error.removeDuplicates().compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.session.$preview.map{$0?.error}.removeDuplicates().compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.learning.$feedback.removeDuplicates().filter{!$0.isEmpty}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,self.model.learning.activePuzzle != nil else{return};self.showDetails()}.store(in:&observations)
        // A connection attempt or a live connection that failed shows why in the drawer.
        model.voice.$connection.removeDuplicates().receive(on:RunLoop.main).sink{[weak self] state in guard case .failed=state else{return};self?.showDetails()}.store(in:&observations)
        let undone=model.session.onUndo;model.session.onUndo={[weak self] in undone?();self?.board.cancelAnimation()}
        let sound=model.session.onMove;model.session.onMove={[weak self] move in sound?(move);guard let self=self else{return};self.board.animate(move,duration:Double(self.model.session.state.settings.pieceDuration)/1000);self.announce(move)}
        let miniSound=model.learning.onMiniMove;model.learning.onMiniMove={[weak self] move in miniSound?(move);guard let self else{return};self.board.animate(move,landing:self.model.learning.miniGame?.board,duration:Double(self.model.session.state.settings.pieceDuration)/1000);if self.model.learning.miniGame?.computer==true,move.color=="b"{self.announce(String(localized:"The computer played \(move.san).",bundle:.checkmate))}}
        let attemptSound=model.learning.onAttemptMove;model.learning.onAttemptMove={[weak self] move in attemptSound?(move);guard let self else{return};self.board.animate(move,landing:self.model.learning.attempt.board,duration:Double(self.model.session.state.settings.pieceDuration)/1000);self.announce(self.attemptAnnouncement(for:move))}
        let trainingSound=model.training?.onMove;model.training?.onMove={[weak self] move in trainingSound?(move);guard let self else{return};self.board.animate(move,duration:Double(self.model.session.state.settings.pieceDuration)/1000);self.announce(self.trainingAnnouncement(for:move))}
        // A training exercise's feedback and hints are shown in the details drawer, as a puzzle's are: open it when one appears.
        if let training=model.training{training.$exercise.map{$0?.feedback ?? ""}.removeDuplicates().merge(with:training.$exercise.map{$0?.hintText ?? ""}.removeDuplicates()).filter{!$0.isEmpty}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,self.trainingExercise != nil else{return};self.showDetails()}.store(in:&observations)}
        let attemptReset=model.learning.onAttemptReset;model.learning.onAttemptReset={[weak self] in attemptReset?();self?.board.cancelAnimation()}
        board.refusedDrop={[weak self] from,to in guard let self,self.model.learning.attemptStep,!self.model.review.active else{return};self.model.learning.attempt.refused(from:from,to:to)}
        let miniReset=model.learning.onMiniReset;model.learning.onMiniReset={[weak self] in miniReset?();self?.board.cancelAnimation()}
        model.learning.miniReview.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.syncMiniReviewSheet()}}.store(in:&observations)
        // A network mini-game's review (protocol 1.3) uses the same sheet, opened from the network pane.
        model.network.miniReview.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.syncMiniReviewSheet()}}.store(in:&observations)
    }
    /// The finished mini-game's review sheet follows its reviewer: shown when a result arrives, gone when it is
    /// dismissed or the review ends (restart, undo, leaving the game).
    private var miniReviewSheet:NSWindow?
    private func syncMiniReviewSheet(){
        // The lesson's or library's game, or the network game's: at most one of them asks for the sheet at a time.
        let reviewer=model.network.miniReview.sheetOpen ? model.network.miniReview:model.learning.miniReview
        if reviewer.sheetOpen,let review=reviewer.review {
            guard miniReviewSheet==nil,let window else{return}
            let sheet=NSWindow(contentViewController:NSHostingController(rootView:MiniGameReviewSheet(review:review,voice:model.voice,read:{[weak model] in model?.readMiniReviewAloud()},close:{[weak reviewer] in reviewer?.dismissSheet()})))
            sheet.title="\(review.kind.title) review";miniReviewSheet=sheet;window.beginSheet(sheet)
        } else if let sheet=miniReviewSheet {miniReviewSheet=nil;window?.endSheet(sheet)}
    }
    /// The open mini-game review sheet's content, for the acceptance scenario.
    var miniReviewSheetShown:Bool {miniReviewSheet?.sheetParent != nil}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,.toggleSidebar,.sidebarTrackingSeparator,.flexibleSpace,titleID,.flexibleSpace,.inspectorTrackingSeparator,.toggleInspector,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem? {
        if id == .sidebarTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:0)};if id == .inspectorTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:1)}
        let item=NSToolbarItem(itemIdentifier:id)
        // AppKit builds the system toggles itself; this is only a fallback with the same action.
        if id == .toggleSidebar || id == .toggleInspector{item.action=id == .toggleSidebar ? #selector(NSSplitViewController.toggleSidebar(_:)):#selector(NSSplitViewController.toggleInspector(_:));item.target=split;item.isBordered=true;label(toolbarItem:item);return item}
        if id==titleID{item.view=titleView;item.isBordered=false;item.label=String(localized:"Current activity",bundle:.checkmate);return item}
        return nil
    }
    /// One noun per drawer, "Sidebar" and "Details", in the View menu, the toolbar and Help (D-6).
    static func drawerTitle(sidebar:Bool,open:Bool)->String {(open ? String(localized:"Hide ",bundle:.checkmate):String(localized:"Show ",bundle:.checkmate))+(sidebar ? String(localized:"Sidebar",bundle:.checkmate):String(localized:"Details",bundle:.checkmate))}
    /// The system toggle items keep their own action, which reaches the split controller; their label, image
    /// description and tooltip name the drawer, and the tooltip says whether it will open or close, as the View menu does.
    func label(toolbarItem item:NSToolbarItem){
        let sidebar=item.itemIdentifier == .toggleSidebar,label=sidebar ? String(localized:"Sidebar",bundle:.checkmate):String(localized:"Details",bundle:.checkmate),tip=Self.drawerTitle(sidebar:sidebar,open:sidebar ? desiredLeft:desiredRight)+(sidebar ? " (⌃⌘S)":" (⌥⌘I)")
        if item.label != label{item.label=label;item.paletteLabel=label};if item.toolTip != tip{item.toolTip=tip}
        if item.image?.accessibilityDescription != label{item.image=NSImage(systemSymbolName:sidebar ? "sidebar.left":"sidebar.right",accessibilityDescription:label)}
    }
    /// The system toolbar toggles reach the window controller too when the window itself is first responder.
    @objc func toggleSidebar(_ sender:Any?){split.toggleSidebar(sender)}
    @objc func toggleInspector(_ sender:Any?){split.toggleInspector(sender)}
    func toolbarWillAddItem(_ notification:Notification){if let item=notification.userInfo?["item"] as? NSToolbarItem,item.itemIdentifier == .toggleSidebar || item.itemIdentifier == .toggleInspector{label(toolbarItem:item)}}
    private func syncDrawerToggles(){for item in window?.toolbar?.items ?? [] where item.itemIdentifier == .toggleSidebar || item.itemIdentifier == .toggleInspector{label(toolbarItem:item)}}
    /// The window's own title and subtitle come from the board-area label, for the Window menu, Mission Control and
    /// VoiceOver (D-10); the title bar stays hidden, so the centred label is the only one drawn.
    static func windowTitles(_ label:String)->(title:String,subtitle:String) {let parts=label.components(separatedBy:" · ");return (parts[0],parts.dropFirst().joined(separator:" · "))}
    private func setTitle(_ label:String){titleView.label.stringValue=label;let titles=Self.windowTitles(label);if window?.title != titles.title{window?.title=titles.title};if window?.subtitle != titles.subtitle{window?.subtitle=titles.subtitle}}
    @objc func toggleLeft(){desiredLeft.toggle();rememberPanes();animateDrawers()}
    @objc func toggleRight(){desiredRight.toggle();rememberPanes();animateDrawers()}
    private func rememberPanes(){model.session.state.window.left=desiredLeft;model.session.state.window.right=desiredRight;model.session.emit(semantic:false,save:true)}
    func showDetails(){if !desiredRight{desiredRight=true;rememberPanes();animateDrawers()}}
    func animateDrawers(){
        guard !animating,!fullscreenTransition,let window=window else{return}
        let changeLeft=sidebarItem.isCollapsed==desiredLeft,changeRight=inspectorItem.isCollapsed==desiredRight
        guard changeLeft || changeRight else{return};animating=true
        let width=fixedBoardWidth ?? main.view.widthAnchor.constraint(equalToConstant:main.view.frame.width);fixedBoardWidth=width
        let available=availableFrameOverride ?? window.screen?.visibleFrame ?? window.frame
        let core=coreFrame ?? window.frame,left=desiredLeft ? leftExtent:0,right=desiredRight ? rightExtent:0
        var target=NSRect(x:core.minX-left,y:core.minY,width:core.width+left+right,height:core.height)
        fittedLayout=fullscreen || !available.contains(target)
        if !fullscreen {
            target.size.width=min(target.width,available.width);target.origin.x=max(available.minX,min(available.maxX-target.width,target.minX));target.size.height=min(target.height,available.height);target.origin.y=max(available.minY,min(available.maxY-target.height,target.minY))
        }
        // Drawers too wide for the screen never squeeze the board below its fitted floor; the window then runs past the screen.
        let targetCore=fullscreen ? max(1,split.view.bounds.width-left-right):max(Metrics.minimumFitted,target.width-left-right)
        if !fullscreen{target.size.width=targetCore+left+right}
        let targetWidth=fullscreen ? split.view.bounds.width:target.width
        boardItem.minimumThickness=min(Metrics.minimum,max(Metrics.minimumFitted,targetCore))
        let outward = !fullscreen && !fittedLayout && abs(main.view.frame.width-core.width)<1
        sidebarItem.collapseBehavior = fullscreen ? .preferResizingSiblingsWithFixedSplitView:.preferResizingSplitViewWithFixedSiblings
        inspectorItem.collapseBehavior=sidebarItem.collapseBehavior
        sidebarItem.preferredThicknessFraction=outward ? NSSplitViewItem.unspecifiedDimension:Metrics.left/targetWidth
        inspectorItem.preferredThicknessFraction=outward ? NSSplitViewItem.unspecifiedDimension:Metrics.right/targetWidth
        // Keep the center explicit in fullscreen too: AppKit otherwise restores
        // its sidebar autosave size and squeezes the board to its minimum.
        width.isActive = true
        if !fullscreen,let native=window as? BoardWindow{native.drawerViewport=available;native.drawerOrigins=min(window.frame.minX,target.minX)...max(window.frame.minX,target.minX)}
        NSAnimationContext.runAnimationGroup{context in
            context.allowsImplicitAnimation=true;context.duration=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:Metrics.drawerAnimation;context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
            width.constant=targetCore
            if changeLeft{sidebarItem.animator().isCollapsed = !desiredLeft}
            if changeRight{inspectorItem.animator().isCollapsed = !desiredRight}
        } completionHandler:{[weak self] in MainActor.assumeIsolated{guard let self=self else{return};self.window?.contentView?.layoutSubtreeIfNeeded();self.titleView.syncCenter();(self.window as? BoardWindow)?.drawerOrigins=nil;(self.window as? BoardWindow)?.drawerViewport=nil;self.fittedOrigin=self.window?.frame.origin;self.animating=false;self.animateDrawers()}}
    }

    @objc func selectTab(){model.session.selectPresentation(titleView.tabs.selectedSegment==1)}
    func select(_ sq:String){
        if model.review.active{if let from=model.review.selected,model.review.displayRules?.moves(from).contains(where:{$0.to==sq && $0.promotion != nil})==true{let shown=reviewPromotionKey;showPromotionMenu(at:sq,action:#selector(promoteReview(_:))){[sq,$0,from,shown]};return};do{try model.review.selectSquare(sq)}catch{showError(error)};refresh();return}

        let s=model.session
        // The network game takes its own input (LAN-play plan D9): no practice or lesson handling, and the piece
        // inspector only at the level both players agreed (assistance plan A1).
        if s.mode == .network {
            let game=model.network
            // Board insight (assistance plan A1): while inspecting, a click picks the piece to inspect, except a dot of
            // the selected piece, which leaves inspection and plays, as in practice.
            if relationships.mode != nil{let plays=game.canMove && game.selected != sq && game.destinations.contains(sq);if plays{relationships.dismiss()}else{game.click(sq);relationships.select(board.position[sq] == nil ? nil:sq);refresh();return}}
            if let from=game.selected,game.destinations.contains(sq),game.needsPromotion(from:from,to:sq){let shown=game.revision;showPromotionMenu(at:sq,action:#selector(promoteNetwork(_:))){NetworkPromotion(from:from,to:sq,piece:$0,revision:shown)};return}
            game.click(sq);refresh();return
        }
        // Inspection hides the move dots but not the move: a playable destination of the inspected piece leaves
        // inspection and plays, so P or A pressed by accident can never make a legal move unplayable.
        if s.mode == .practice,shownHistoryPly != nil{refuseHistoryMove();return}
        let attempt=model.learning.attemptStep ? model.learning.attempt:nil
        if relationships.mode != nil{let plays=s.mode == .practice && s.selected != sq && s.inspection?.legalNow==true && s.destinations.contains(sq) || attempt.map{$0.selected != sq && $0.destinations.contains(sq)} == true;if plays{relationships.dismiss()}else{if s.mode == .practice{do{try s.inspectPiece(sq)}catch{showError(error)}};relationships.select(board.position[sq] == nil ? nil:sq);refresh();return}}
        if s.mode == .practice {
        if let from=s.selected,s.inspection?.legalNow==true,s.destinations.contains(sq),(s.presentationHidden || s.preview==nil && s.demonstration==nil) {let promotion=s.rules.moves(from).contains{$0.to==sq && $0.promotion != nil};if promotion {let shown=practiceGame;showPromotionMenu(at:sq,action:#selector(promote(_:))){PracticePromotion(from:from,to:sq,piece:$0,game:shown)};return}}
        do{try s.select(sq)}catch{showError(error)}
    }else if let training=model.training,trainingExercise != nil{training.click(sq);askTrainingPromotion(training,reaching:sq)}
    else if model.learning.attemptStep,let from=model.learning.attempt.selected,model.learning.attempt.destinations.contains(sq),model.learning.attempt.needsPromotion(from:from,to:sq) {let shown=model.learning.attempt.identity;showPromotionMenu(at:sq,action:#selector(promoteAttempt(_:))){AttemptPromotion(from:from,to:sq,piece:$0,identity:shown)};return}
    else{model.learning.click(sq)};refresh()}
    /// A lesson exercise's promotion, bound to the attempt and move it was offered for: a choice made after the attempt
    /// moved on (an undo, a restart, another step) does nothing.
    struct AttemptPromotion {let from:String,to:String,piece:String,identity:String}
    @objc func promoteAttempt(_ item:NSMenuItem){guard let choice=item.representedObject as? AttemptPromotion,!model.review.active,!model.reviewWorkspace,model.learning.attemptStep,model.learning.attempt.identity==choice.identity else{refresh();return};model.learning.attempt.play(from:choice.from,to:choice.to,promotion:choice.piece);refresh()}
    /// A network-game promotion, bound to the position the menu was opened over: one answered meanwhile does nothing.
    struct NetworkPromotion {let from:String,to:String,piece:String,revision:Int}
    @objc func promoteNetwork(_ item:NSMenuItem){guard let choice=item.representedObject as? NetworkPromotion,model.session.mode == .network,!model.review.active,model.network.revision==choice.revision else{refresh();return};model.network.play(from:choice.from,to:choice.to,promotion:choice.piece);refresh()}
    /// The exercise shown on the board, if a training exercise (not the library or a library mini-game) is open.
    var trainingExercise:TrainingController.Exercise? {guard case .training=model.session.activity.place else{return nil};return model.training?.exercise}
    /// Dragging applies where selecting a piece and then a square plays a move; marking and route exercises stay
    /// click-only, and in practice only the learner's own pieces drag.
    func dragMoves(_ square:String)->Bool {
        guard !model.reviewWorkspace,relationships.mode==nil else{return false}
        if model.review.active{return true}
        let l=model.learning,s=model.session
        if s.mode == .network{return model.network.canDrag(square)}
        if s.mode == .practice{return shownHistoryPly==nil && board.position[square]?.first.map(String.init)==s.humanSide}
        // Selecting squares is click-only; a piece the learner moves may be dragged.
        if let exercise=trainingExercise{return !exercise.finished && (exercise.task == .move || exercise.task == .game && model.training?.games.thinking == false) && board.position[square]?.first.map(String.init)==exercise.scenario.learner}
        if l.attemptStep{return l.attempt.learnerToMove && board.position[square]?.first=="w"}
        return l.mini || l.activePuzzle != nil && l.exercise?.kind=="move"
    }
    /// The promotion choices at a square; each item carries `payload(piece)` for its action. Returns whether one was chosen.
    @discardableResult private func showPromotionMenu(at sq:String,action:Selector,payload:(String)->Any)->Bool {
        let menu=NSMenu()
        // Each piece answers to its letter alone (B-13); Queen opens under the pointer, highlighted.
        for (title,piece,tip) in [(String(localized:"Queen",bundle:.checkmate),"q",String(localized:"Promote to a queen",bundle:.checkmate)),(String(localized:"Rook",bundle:.checkmate),"r",String(localized:"Promote to a rook",bundle:.checkmate)),(String(localized:"Bishop",bundle:.checkmate),"b",String(localized:"Promote to a bishop",bundle:.checkmate)),(String(localized:"Knight",bundle:.checkmate),"n",String(localized:"Promote to a knight",bundle:.checkmate))]{let item=NSMenuItem(title:title,action:action,keyEquivalent:piece);item.keyEquivalentModifierMask=[];item.target=self;item.image=promotionImage(piece);item.toolTip=tip;item.representedObject=payload(piece);menu.addItem(item)}
        return presentPromotionMenu(menu,board.squareRect(sq).origin,board)
    }
    /// A training promotion, bound to the attempt, its saved revision and the move the menu was opened for: a choice
    /// made after any of them changed (an agent's action, a restart, a cancel) does nothing.
    struct TrainingPromotion {let from:String,to:String,piece:String,attempt:String,revision:Int}
    /// Whether `pending` is still the shown exercise's open promotion, for the attempt and revision it was offered on.
    private func trainingPromotionOpen(from:String,to:String,attempt:String,revision:Int)->Bool {
        guard let exercise=trainingExercise,!exercise.finished,let pending=exercise.pendingPromotion else{return false}
        return pending.from==from && pending.to==to && exercise.snapshot.id==attempt && exercise.snapshot.revision==revision
    }
    /// A move to the last rank asks for its piece through the board's menu, as practice does; closing the menu without
    /// a choice cancels the promotion, which counts nothing. Only the click that reached the promotion square asks; one
    /// left open by an agent keeps the drawer's chooser.
    private func askTrainingPromotion(_ training:TrainingController,reaching sq:String){
        guard let exercise=trainingExercise,!exercise.finished,let pending=exercise.pendingPromotion,pending.to==sq else{return}
        let attempt=exercise.snapshot.id,revision=exercise.snapshot.revision
        let chosen=showPromotionMenu(at:pending.to,action:#selector(promoteTraining(_:))){TrainingPromotion(from:pending.from,to:pending.to,piece:$0,attempt:attempt,revision:revision)}
        if !chosen,trainingPromotionOpen(from:pending.from,to:pending.to,attempt:attempt,revision:revision){training.cancelPromotion()}
    }
    @objc func promoteTraining(_ item:NSMenuItem){guard let choice=item.representedObject as? TrainingPromotion,!model.review.active,let training=model.training,trainingPromotionOpen(from:choice.from,to:choice.to,attempt:choice.attempt,revision:choice.revision) else{refresh();return};training.attempt(from:choice.from,to:choice.to,promotion:choice.piece);refresh()}
    private func promotionImage(_ piece:String)->NSImage {
        let symbol=["q":"♛","r":"♜","b":"♝","n":"♞"][piece] ?? ""
        let size=NSSize(width:Metrics.promotionIconSize,height:Metrics.promotionIconSize)
        let image=NSImage(size:size,flipped:false){rect in
            (symbol as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:rect.height),.foregroundColor:NSColor.black]);return true
        };image.isTemplate=true;return image
    }
    /// The review position a promotion menu was opened over; the menu's run loop lets an agent move the review meanwhile.
    private var reviewPromotionKey:String {model.review.identity+":\(model.review.branchPly)"}
    /// A choice applies only to the position and piece the menu was opened for; one changed meanwhile is ignored.
    @objc func promoteReview(_ item:NSMenuItem){guard let values=item.representedObject as? [String],values.count==4,model.review.active,model.review.selected==values[2],reviewPromotionKey==values[3] else{refresh();return};do{try model.review.selectSquare(values[0],promotion:values[1])}catch{showError(error)};refresh()}
    /// A practice promotion chosen from the menu, bound to the exact game position the menu was opened over.
    struct PracticePromotion {let from:String,to:String,piece:String,game:(generation:Int,position:Int,history:[String])}
    /// The menu's run loop lets an agent replace the game meanwhile; an identical position in another game is not this one.
    @objc func promote(_ item:NSMenuItem){guard let choice=item.representedObject as? PracticePromotion,stillShowing(choice.game,exactly:true) else{refresh();return};do{try model.session.playWhite(from:choice.from,to:choice.to,promotion:choice.piece)}catch{showError(error)};refresh()}
    func toggleRelationship(_ mode:RelationshipMode){guard !model.review.active,!model.reviewWorkspace,model.session.mode != .network || model.network.inspectable,trainingExercise==nil,let selected=board.selected,board.position[selected] != nil else{return};relationships.toggle(mode,selected:selected);refresh();if relationships.mode != nil{showDetails()}}
    @objc func showProtection(){toggleRelationship(.protected)}
    @objc func showAttacks(){toggleRelationship(.attacked)}
    @objc func dismissInspection(){relationships.dismiss();refresh()}
    /// VoiceOver hears every practice move as it lands, with check, mate or a draw, as sighted players see it.
    private func announce(_ move:MoveRecord){if let text=announcement(for:move){announce(text)}}
    /// What VoiceOver hears for a move that just landed; nil outside practice or during review.
    func announcement(for move:MoveRecord)->String? {
        let s=model.session;guard s.mode == .practice,!model.review.active else{return nil}
        var text=move.color==s.humanSide ? String(localized:"You played \(move.san).",bundle:.checkmate):move.color=="w" ? String(localized:"White played \(move.san).",bundle:.checkmate):String(localized:"Black played \(move.san).",bundle:.checkmate)
        if s.rules.checkmate{text+=move.color==s.humanSide ? String(localized:" Checkmate. You win.",bundle:.checkmate):String(localized:" Checkmate.",bundle:.checkmate)}else if s.rules.check{text+=move.color==s.humanSide ? String(localized:" Check.",bundle:.checkmate):String(localized:" Your king is in check.",bundle:.checkmate)}else if s.rules.draw{text+=String(localized:" The game is drawn.",bundle:.checkmate)}
        return text
    }
    /// What VoiceOver hears when a lesson exercise move lands: the move, check or mate, and the exercise's outcome.
    func attemptAnnouncement(for move:MoveRecord)->String {
        let attempt=model.learning.attempt!,rules=attempt.rules
        var text=move.color=="w" ? String(localized:"You played \(move.san).",bundle:.checkmate):String(localized:"The computer played \(move.san).",bundle:.checkmate)
        if rules.checkmate{text+=String(localized:" Checkmate.",bundle:.checkmate)}else if rules.check{text+=move.color=="w" ? String(localized:" Check.",bundle:.checkmate):String(localized:" Your king is in check.",bundle:.checkmate)}else if rules.draw{text+=String(localized:" The game is drawn.",bundle:.checkmate)}
        switch attempt.phase {case .achieved?:text+=String(localized:" Well done! ",bundle:.checkmate)+(attempt.judgement?.feedback ?? "");case .offTrack?,.failed?:text+=" "+(attempt.judgement?.feedback ?? "");default:break}
        return text
    }
    /// What VoiceOver hears when a training move lands: who played it, and check or mate from its notation. The
    /// exercise's result is in its feedback, which the drawer and the bar show.
    func trainingAnnouncement(for move:MoveRecord)->String {
        let learner=move.color==trainingExercise?.scenario.learner
        var text=(learner ? String(localized:"You played ",bundle:.checkmate):String(localized:"The opponent played ",bundle:.checkmate))+move.san+"."
        if move.san.hasSuffix("#"){text+=String(localized:" Checkmate.",bundle:.checkmate)}else if move.san.hasSuffix("+"){text+=learner ? String(localized:" Check.",bundle:.checkmate):String(localized:" Your king is in check.",bundle:.checkmate)}
        return text
    }
    /// The bar takes a second row when its sides no longer fit beside the centre group; the board yields the height.
    private func setControlRows(_ rows:Int){let height=Metrics.header+CGFloat(max(0,rows-1))*(ControlBarView.rowHeight+Metrics.smallGap);if controlsHeight.constant != height{controlsHeight.constant=height}}
    /// An arrow that crossed into another lesson says where the learner now is.
    private func announceLesson(){announce(String(localized:"Now in \(model.learning.localizedTitle(index:model.learning.lessonIndex)).",bundle:.checkmate))}
    private func announce(_ text:String){NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    func refresh(){syncDrawerToggles();syncMenus();let s=model.session,l=model.learning
        // The learner's own side sits nearest them in practice, training and a review of their own game; lessons and
        // other reviews keep White at the bottom. Flip Board turns what is shown over until something else is (B-6);
        // the network game keeps its own flip.
        let natural=model.review.active ? model.review.document.flatMap(model.reviewLearnerSide)=="b":s.mode == .practice && s.humanSide=="b" || trainingExercise?.scenario.learner=="b" || s.mode == .network && model.network.blackAtBottom
        board.blackAtBottom = !model.reviewWorkspace && natural != (s.mode != .network && flipped==boardSubject)
        board.reviewNavigation=model.review.active && model.review.branch==nil
        reviewWorkspaceView.isHidden = !model.reviewWorkspace;controls.isHidden=model.reviewWorkspace;if workspaceFill.isActive != model.reviewWorkspace{workspaceAboveControls.isActive=false;workspaceFill.isActive=model.reviewWorkspace;workspaceAboveControls.isActive = !model.reviewWorkspace}
playbackLineView?.isHidden=model.reviewWorkspace
        trainingLibraryView.isHidden=true
        if model.reviewWorkspace{board.isHidden=true;welcome.isHidden=true;puzzles.isHidden=true;setTitle(String(localized:"Game review",bundle:.checkmate));titleView.label.isHidden=false;titleView.tabs.isHidden=true;return}
        board.theme=s.state.settings.boardTheme
        if model.review.active{let review=model.review;applyBoard(reviewPresentation(review));board.relationshipMode=nil;board.relationshipConnectors=[]
            if announcedReviewIdentity != review.identity{announcedReviewIdentity=review.identity;let node=review.document?.nodes[review.nodeID];let announcement=review.branch==nil ? String(localized:"Review, \(node?.fullmove ?? 1), \(node?.side=="b" ? "Black":"White"), \(node?.san ?? "starting position")",bundle:.checkmate):String(localized:"Imagined line, move \(review.branchPly)",bundle:.checkmate);NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:announcement,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
            board.isHidden=false;puzzles.isHidden=true;welcome.isHidden=true;setTitle(review.branch==nil ? String(localized:"Review · Original game",bundle:.checkmate):String(localized:"Review · Imagined moves",bundle:.checkmate));titleView.label.isHidden=false;titleView.tabs.isHidden=true;board.needsDisplay=true;return}

        // An exercise's own presentation replaces the activity's before relationships read the selection; it offers no inspection.
        var shown=s.mode == .network ? networkPresentation():trainingExercise.map(trainingPresentation) ?? activityPresentation()
        if trainingExercise != nil{relationships.dismiss()}
        // The network board offers inspection only at board insight or more (assistance plan A1), from its own position.
        let network=s.mode == .network,inspectable=network && model.network.inspectable
        if network && !inspectable{relationships.dismiss()}
        relationships.update(board:shown.position,fen:network ? model.network.fen:s.mode == .practice ? s.displayFen:l.attemptStep ? l.attempt.rules.fen:nil,selected:trainingExercise==nil && (!network || inspectable) ? shown.selected:nil,identity:network ? model.network.identity:s.displayIdentity)
        if let report=relationships.report{shown.selected=report.square;shown.destinations=[];shown.attacked=[];shown.arrows=[];shown.guards=[];shown.highlights.removeAll{$0.kind != "check" && $0.kind != "no"}}
        applyBoard(shown)
        board.relationshipMode=relationships.report?.mode
        board.relationshipConnectors=relationships.report?.relations.map{RelationshipConnector(source:$0.square,target:relationships.report!.square,limited:$0.limited)} ?? []
        board.needsDisplay=true
        let library=s.mode == .puzzles && l.activePuzzle==nil,titlecard=s.mode == .lesson && l.frame.board==nil
        let trainingLibrary=model.training != nil && s.activity.place == .trainingLibrary
        board.isHidden=library || titlecard || trainingLibrary;puzzles.isHidden = !library;welcome.isHidden = !titlecard;trainingLibraryView.isHidden = !trainingLibrary
        if titlecard {welcome.rootView=WelcomeContent(title:l.localizedStepTitle(index:l.lessonIndex,step:l.step))}
        setTitle(s.mode == .network ? model.network.boardTitle:s.mode == .practice ? String(localized:"Practice · \(s.humanSide=="b" ? "Black":"White") vs Stockfish",bundle:.checkmate):s.mode == .puzzles ? String(localized:"Quick puzzles",bundle:.checkmate):l.mini ? l.miniKind.title:s.mode == .training ? trainingExercise?.definition.title ?? String(localized:"Training",bundle:.checkmate):l.localizedTitle(index:l.lessonIndex)+(l.attemptStatus.map{" · "+$0} ?? ""))
        let temporary=s.preview != nil || s.demonstration != nil;titleView.label.isHidden=temporary;titleView.tabs.isHidden = !temporary;titleView.tabs.setLabel(s.demonstration != nil ? String(localized:"Demonstration",bundle:.checkmate):String(localized:"Try a Move",bundle:.checkmate),forSegment:1);titleView.tabs.selectedSegment=s.presentationHidden ? 0:1;titleView.needsLayout=true
    }
    /// Everything the board shows for one activity. Each builder sets every field, so nothing from the previous
    /// activity survives a switch; `applyBoard` is the one place the board receives it.
    /// `source` names what the board shows (a review, its preview, a lesson, a demonstration, which practice game or
    /// mini-game run…), independent of the position: an animation belongs to one source, so switching to another with the
    /// same pieces (a new game from the start position included) still ends it.
    private struct BoardPresentation {var source:String,position:Position,selected:String?,destinations:[String],playable:Bool,dropsAnywhere:Bool,attacked:[String],highlights:[Highlight],arrows:[[String]],guards:[[String]],counts:[String],motion:PieceMotion?}
    private func applyBoard(_ p:BoardPresentation){board.displaySource=p.source;board.position=p.position;board.selected=p.selected;board.destinations=p.destinations;board.destinationsPlayable=p.playable;board.dropsAnywhere=p.dropsAnywhere;board.attacked=p.attacked;board.highlights=p.highlights;board.arrows=p.arrows;board.guards=p.guards;board.counts=p.counts;board.explicitMotion=p.motion}
    /// A review: the last move (and an imagined line's arrow), check, then the review's and the voice coach's marks.
    private func reviewPresentation(_ review:ReviewController)->BoardPresentation {
        var p=BoardPresentation(source:review.branch==nil ? "review":"review_preview",position:review.board,selected:review.selected,destinations:review.destinations,playable:true,dropsAnywhere:false,attacked:[],highlights:[],arrows:[],guards:[],counts:[],motion:nil)
        // An imagined line starts from its own root, which a preview can place away from the selected move.
        let imagined=review.branch.flatMap{branch in review.branchPly>0 ? branch.moves[review.branchPly-1]:nil}
        if let move=imagined ?? review.document?.nodes[review.branch?.root ?? review.nodeID].uci {let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2));p.highlights=[Highlight(sq:from,kind:"last"),Highlight(sq:to,kind:"last")];if imagined != nil{p.arrows=[[from,to]]}}
        if let rules=review.displayRules,rules.check,let king=rules.board.first(where:{$0.value==rules.turn+"k"})?.key{p.highlights.append(Highlight(sq:king,kind:"check"))}
        p.highlights += review.highlights+model.session.voiceFocus.map{Highlight(sq:$0,kind:"focus")};p.arrows += review.arrows
        return p
    }
    /// Practice, a lesson, a puzzle or a mini-game, with a demonstration on top.
    private func activityPresentation()->BoardPresentation {let s=model.session,l=model.learning,practice=s.mode == .practice
        var p=BoardPresentation(source:"\(s.displayView):\(s.gameGeneration):\(l.miniGame.map{"\($0.kind.rawValue)/\($0.opponentSeed ?? "")"} ?? ""):\(l.attemptStep ? l.attempt.record?.id ?? "":"")",position:s.displayBoard,selected:practice ? s.selected:l.picked.first,destinations:practice ? s.destinations:l.destinations,playable:!practice || s.inspection?.legalNow != false,dropsAnywhere:!practice && !l.mini && l.activePuzzle != nil && l.exercise?.kind=="move",attacked:practice ? s.inspection?.attacks ?? []:[],highlights:s.highlights+s.voiceFocus.map{Highlight(sq:$0,kind:"focus")},arrows:s.arrows,guards:[],counts:[],motion:nil)
        // The last move is drawn first so the coach's highlights stay visible on top of it, as in review.
        if practice,s.displayView=="game" {if let last=s.rules.records.last{p.highlights.insert(contentsOf:[Highlight(sq:last.from,kind:"last"),Highlight(sq:last.to,kind:"last")],at:0)};if s.rules.check,let king=s.rules.board.first(where:{$0.value==s.rules.turn+"k"})?.key{p.highlights.append(Highlight(sq:king,kind:"check"))}}
        if !practice {p.highlights+=l.frame.hl+l.picked.map{Highlight(sq:$0,kind:"focus")};p.arrows=l.frame.arrows+p.arrows;p.guards=l.frame.guards;p.counts=l.frame.counts ?? [];p.motion=l.frame.motion.map{motion in var landed=motion;if board.shouldReduceMotion{landed.t=1};return landed}}
        if !s.presentationHidden,let d=s.demonstration {let frame=d.lines[d.line].frames[d.ply];p.arrows=frame.arrows+p.arrows;p.highlights+=frame.highlights}
        // An earlier position of the game (B-9): its pieces and the move that led there, and nothing to play or inspect.
        if practice,let ply=shownHistoryPly{let records=s.rules.records;guard let earlier=TrainingMaterial.board(fen:records[ply].before) else{preconditionFailure("A recorded position has an unreadable FEN: \(records[ply].before)")}
            p=BoardPresentation(source:"history:\(s.gameGeneration):\(ply)",position:earlier,selected:nil,destinations:[],playable:false,dropsAnywhere:false,attacked:[],highlights:ply>0 ? [Highlight(sq:records[ply-1].from,kind:"last"),Highlight(sq:records[ply-1].to,kind:"last")]:[],arrows:[],guards:[],counts:[],motion:nil)}
        return p
    }
    /// The network game: its own board, selection and legal dots; a pending move shows its lifted piece and target.
    private func networkPresentation()->BoardPresentation {
        let game=model.network,rules=game.rules
        var p=BoardPresentation(source:"network:\(game.identity)",position:game.board,selected:game.pending?.from ?? game.selected,destinations:game.destinations,playable:true,dropsAnywhere:false,attacked:[],highlights:[],arrows:[],guards:[],counts:[],motion:nil)
        if let last=rules.records.last{p.highlights=[Highlight(sq:last.from,kind:"last"),Highlight(sq:last.to,kind:"last")]}
        if rules.check,let king=rules.board.first(where:{$0.value==rules.turn+"k"})?.key{p.highlights.append(Highlight(sq:king,kind:"check"))}
        if let pending=game.pending{p.highlights.append(Highlight(sq:pending.to,kind:"target"))}
        // The agreed hint (assistance plan A6), on the learner's own board only: an arrow from the piece to its square.
        if let hint=model.networkAssistant.hint{p.arrows=[[hint.from,hint.to]];p.highlights.append(Highlight(sq:hint.from,kind:"focus"))}
        // The coach's segment being spoken, on the learner's own board (A10).
        p.highlights += model.voice.networkFocus.map{Highlight(sq:$0,kind:"focus")}
        return p
    }
    /// An exercise shows only what the learner did: no legal-move dots or hidden answers, except a hint asked for.
    private func trainingPresentation(_ exercise:TrainingController.Exercise)->BoardPresentation {
        // The training coach's highlights, only while they belong to the board shown.
        let coach=model.trainingVoice?.shownMarks ?? TrainingVoiceAdapter.Marks()
        let target=[exercise.scenario.target ?? exercise.scenario.drill?.target ?? exercise.scenario.goal?.target].compactMap{$0}.map{Highlight(sq:$0,kind:"target")}
        return BoardPresentation(source:"training",position:model.session.displayBoard,selected:exercise.picked,destinations:[],playable:true,dropsAnywhere:exercise.task == .move || exercise.task == .game,attacked:[],highlights:(exercise.lastMove.map{[Highlight(sq:$0.from,kind:"last"),Highlight(sq:$0.to,kind:"last")]} ?? [])+target+exercise.selection.map{Highlight(sq:$0,kind:"answer")}+exercise.hintSquares.map{Highlight(sq:$0,kind:"hint")}+coach.squares.map{Highlight(sq:$0,kind:"focus")}+model.voice.trainingFocus.map{Highlight(sq:$0,kind:"focus")},arrows:coach.arrows,guards:[],counts:[],motion:nil)
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(typeMove){return typedMoveAvailable}
        // The network game's own items act on its controller (LAN-play plan D9); in network mode nothing else in the
        // Game or Lesson menu shows (`syncMenus`).
        if let action=item.action,let enabled=Self.networkItemEnabled(action,network:model.session.mode == .network,game:model.network){return enabled}
        if let enabled=Self.voiceMenuItemEnabled(item,model:model,offered:!model.reviewWorkspace && bar.item(.voiceConnect)?.enabled==true){return enabled}
        if let action=item.action,[#selector(lessonPlayPause),#selector(lessonPrevious),#selector(lessonNext),#selector(lessonFromStart),#selector(barHint)].contains(action) {
            let shown=barItem(for:action)
            let fallback=[#selector(lessonPlayPause):String(localized:"Play",bundle:.checkmate,comment:"Verb: start playback of a lesson"),#selector(lessonPrevious):String(localized:"Previous Step",bundle:.checkmate),#selector(lessonNext):String(localized:"Next Step",bundle:.checkmate),#selector(lessonFromStart):String(localized:"Play Step from Start",bundle:.checkmate),#selector(barHint):String(localized:"Hint",bundle:.checkmate,comment:"Noun: ask for a hint")][action] ?? item.title
            // The title follows the control: Pause while playing, and the lesson's name where the arrow crosses into it.
            switch shown?.action {
            case .previousLesson?,.nextLesson?:item.title=shown!.label.replacingOccurrences(of:String(localized:"Previous lesson:",bundle:.checkmate),with:String(localized:"Previous Lesson:",bundle:.checkmate)).replacingOccurrences(of:String(localized:"Next lesson:",bundle:.checkmate),with:String(localized:"Next Lesson:",bundle:.checkmate))
            case .playPause?,.reviewPlayPause?,.demoPlayPause?:item.title=shown!.symbol == .pause ? String(localized:"Pause",bundle:.checkmate):String(localized:"Play",bundle:.checkmate,comment:"Verb: start playback of a lesson")
            case .attemptHint?,.trainingHint?,.hint?:item.title=shown!.label
            default:item.title=fallback
            }
            return shown?.enabled ?? false
        }
        if item.action == #selector(flipBoard){return !model.reviewWorkspace && !board.isHidden}
        if item.action == #selector(resign){return !model.review.active && model.session.canResign}
        // Edit ▸ Undo follows `NativeModel.undoAction`: right after a deletion it puts the review back; in a review it
        // has nothing else; elsewhere it is the game's take back.
        if item.action == NSSelectorFromString("undo:"){switch model.undoAction{case .restoreReview:item.title=String(localized:"Undo Delete Review",bundle:.checkmate);return true;case .nothing:item.title=String(localized:"Undo",bundle:.checkmate);return false;case .game:item.title=String(localized:"Undo",bundle:.checkmate)}}
        if item.action == #selector(undo as () -> Void) || item.action == NSSelectorFromString("undo:"),!model.review.active,!model.reviewWorkspace {
            if model.learning.attemptStep{if item.action == #selector(undo as () -> Void){item.title=String(localized:"Undo Turn",bundle:.checkmate)};return model.learning.attempt.hasMoves}
            if let exercise=trainingExercise{return model.training.map{ControlBarModel.canTakeBack($0,exercise)} ?? false}
            if item.action == #selector(undo as () -> Void){item.title=model.learning.mini ? String(localized:"Undo Turn",bundle:.checkmate):String(localized:"Take Back Move",bundle:.checkmate)}
        }
        if [#selector(showProtection),#selector(showAttacks),#selector(dismissInspection)].contains(item.action){if item.action == #selector(dismissInspection){return relationships.mode != nil};item.state=(item.action == #selector(showProtection) && relationships.mode == .protected || item.action == #selector(showAttacks) && relationships.mode == .attacked) ? .on:.off;return !model.review.active && trainingExercise==nil && (model.session.mode != .network || model.network.inspectable) && board.selected.flatMap{board.position[$0]} != nil && !board.isHidden};guard [#selector(newGame),#selector(undo as () -> Void),NSSelectorFromString("undo:"),#selector(restorePrevious),#selector(claimDraw),#selector(resign)].contains(item.action) else{return true};guard !model.review.active,!model.reviewWorkspace else{return false};if model.learning.mini,![#selector(restorePrevious),#selector(claimDraw),#selector(resign)].contains(item.action){return item.action == #selector(newGame) || model.learning.miniGame?.history.isEmpty == false};guard model.session.mode == .practice else{return false};if item.action == #selector(undo as () -> Void) || item.action == NSSelectorFromString("undo:"){return model.session.canTakeBack};if item.action == #selector(claimDraw){return model.session.claimableDraw != nil};if item.action == #selector(resign){return !model.session.finished && !model.session.rules.history.isEmpty};if item.action == #selector(restorePrevious){return !model.session.state.practice.previousGame.isEmpty};return true}
    @objc func newGame(){
        guard !model.review.active,!model.reviewWorkspace else{return}
        if model.learning.mini {
            if model.learning.miniGame?.history.isEmpty != false{model.learning.restartMini();return}
            // The sheet answers for the mini-game it was shown over: one replaced meanwhile (an agent, a restart) is kept.
            let shown=model.learning.miniGame.map{($0.kind,$0.opponentSeed)}
            let alert=NSAlert.destructive(String(localized:"Start a new \(model.learning.miniKind.title) game?",bundle:.checkmate),String(localized:"This replaces the current mini-game.",bundle:.checkmate),action:String(localized:"New Game",bundle:.checkmate));present(alert){[weak self] response in guard response == .alertFirstButtonReturn,let self,self.model.learning.mini,let game=self.model.learning.miniGame,let shown,game.kind==shown.0,game.opponentSeed==shown.1 else{return};self.model.learning.restartMini()};return
        }
        guard model.session.mode == .practice else{return};let a=NSAlert();a.messageText=String(localized:"Start a new game?",bundle:.checkmate);a.informativeText=model.session.state.practice.previousGame.isEmpty ? String(localized:"Your current game will be available under Restore Previous Game.",bundle:.checkmate):String(localized:"Your current game will be available under Restore Previous Game, replacing the game kept there now.",bundle:.checkmate)
        let choices=NewGameChoices.view(settings:model.session.state.settings,side:model.session.humanSide);a.accessoryView=choices.view
        let shown=practiceGame
        a.addButton(withTitle:String(localized:"New Game",bundle:.checkmate));a.addButton(withTitle:String(localized:"Cancel",bundle:.checkmate));present(a){r in guard r == .alertFirstButtonReturn,self.stillShowing(shown) else{return};self.board.cancelAnimation()
            var settings=self.model.session.state.settings;let preset=NewGameChoices.strengths[choices.strength.indexOfSelectedItem].tag
            if settings.opponentPreset != preset{settings.opponentPreset=preset;self.model.session.updateSettings(settings)}
            self.model.session.newGame(side:NewGameChoices.side(at:choices.side.indexOfSelectedItem){Bool.random()})}}
    @objc func claimDraw(){if model.session.mode == .network{model.network.claimDraw();return};guard !model.review.active,model.session.mode == .practice else{return};model.session.claimDraw();refresh()}
    // MARK: The network game's menu items (LAN-play plan D9)
    /// The Game menu's base items in network mode: Resign, Offer Draw, Claim Draw, Flip Board and Leave Game. The only
    /// others it shows are `inspectorActions`, and those only at board insight or more.
    static let networkActions:Set<Selector>=[#selector(resign),#selector(offerDraw),#selector(claimDraw),#selector(flipBoard),#selector(leaveGame),#selector(typeMove)]
    /// The piece inspector's items, shown in network mode only when the agreed level allows it (assistance plan A1).
    static let inspectorActions:Set<Selector>=[#selector(showProtection),#selector(showAttacks),#selector(dismissInspection)]
    /// Items that exist only for the network game, hidden elsewhere.
    static let networkOnlyActions:Set<Selector>=[#selector(offerDraw),#selector(leaveGame)]
    /// The Game menu and the Lesson menu's bar item, from `AppDelegate.installMenus`.
    weak var gameMenu:NSMenu?
    weak var lessonMenuItem:NSMenuItem?
    func syncMenus(){if let gameMenu{Self.syncMenus(gameMenu,lesson:lessonMenuItem,network:model.session.mode == .network,inspector:model.network.inspectable)}}
    /// In network mode the Game menu shows only the network items and the Lesson menu hides; elsewhere the network-only
    /// items hide. Hidden items take no key equivalents either, so a practice or lesson shortcut cannot reach the
    /// network place.
    /// `inspector`: the network game allows Protected by / Attacked by (assistance plan A1), so those items show too.
    static func syncMenus(_ gameMenu:NSMenu,lesson:NSMenuItem?,network:Bool,inspector:Bool=false){
        for item in gameMenu.items {
            let hidden=item.isSeparatorItem ? network:item.action.map{network ? !(networkActions.contains($0) || inspector && inspectorActions.contains($0)):networkOnlyActions.contains($0)} ?? false
            if item.isHidden != hidden{item.isHidden=hidden}
        }
        if let lesson,lesson.isHidden != network{lesson.isHidden=network}
    }
    /// Whether a network item is enabled; nil for an item the network game does not own here, which the window's
    /// other rules decide.
    static func networkItemEnabled(_ action:Selector,network:Bool,game:NetworkGameController)->Bool? {
        guard networkOnlyActions.contains(action) || network && networkActions.contains(action) else{return nil}
        // Flip Board works everywhere (B-6): outside the network game the window decides.
        guard network else{return false}
        switch action {
        case #selector(resign):return game.canResign
        case #selector(claimDraw):return game.canClaimDraw
        case #selector(offerDraw):return game.canOfferDraw
        case #selector(flipBoard):return game.seat != nil
        default:return game.part != nil
        }
    }
    @objc func offerDraw(){guard model.session.mode == .network else{return};model.network.offerDraw()}
    @objc func flipBoard(){guard !model.reviewWorkspace else{return};if model.session.mode == .network{model.network.flip()}else{flipped=flipped==boardSubject ? nil:boardSubject};refresh()}
    /// The subject Flip Board turned over, if it still shows.
    private var flipped:String?
    /// What the board shows, for Flip Board: a flip lasts while the same review, game, exercise or lesson is shown.
    private var boardSubject:String {
        if model.review.active{return "review:"+(model.review.document?.id.uuidString ?? "")}
        if let exercise=trainingExercise{return "training:"+exercise.snapshot.id}
        let s=model.session
        switch s.mode {case .practice:return "practice:\(s.gameGeneration)";case .lesson:return "lesson:\(model.learning.lessonIndex):\(model.learning.mini)";default:return "\(s.mode)"}
    }
    @objc func leaveGame(){guard model.session.mode == .network else{return};model.leaveNetworkGame()}
    /// D11's help: a sheet whose button opens System Settings › Privacy & Security › Local Network.
    private func syncPermissionHelp(_ shown:Bool){
        if shown,permissionAlert==nil,let window {
            let alert=NSAlert();alert.messageText=String(localized:"Allow Checkmate on your local network",bundle:.checkmate)
            alert.informativeText=String(localized:"Finding and joining network games needs Local Network access. Turn on Checkmate in System Settings › Privacy & Security › Local Network; a game that is waiting carries on by itself once it is on.",bundle:.checkmate)
            alert.addButton(withTitle:String(localized:"Open Local Network Settings",bundle:.checkmate)).setAccessibilityIdentifier("network-permission-open-settings")
            alert.addButton(withTitle:String(localized:"Not Now",bundle:.checkmate)).setAccessibilityIdentifier("network-permission-close")
            alert.window.setAccessibilityIdentifier("network-permission-sheet")
            permissionAlert=alert
            alert.beginSheetModal(for:window){[weak self] response in MainActor.assumeIsolated{
                guard let self else{return};self.permissionAlert=nil
                if response == .alertFirstButtonReturn{self.model.openLocalNetworkSettings()}
                if self.model.network.permissionHelp{self.model.network.dismissPermissionHelp()}
            }}
        }else if !shown,let alert=permissionAlert,let window {window.endSheet(alert.window)}
    }
    private(set) var permissionAlert:NSAlert?
    /// D9's crash notice at launch: "Your network game with Ben ended when Checkmate closed", with Review offered when
    /// the game has moves. The file is gone once read.
    func offerNetworkCrashReview(){
        guard let entry=model.takeNetworkCrashNotice(),let window else{return}
        let moves=NativeModel.replayedMoves(entry) ?? [],reviewable = !moves.isEmpty
        let alert=NSAlert();alert.messageText=entry.notice;alert.informativeText=NativeModel.crashDetail(entry,moves:moves)
        if reviewable{alert.addButton(withTitle:String(localized:"Review",bundle:.checkmate,comment:"Verb: open the game for review")).setAccessibilityIdentifier("network-crash-review")}
        alert.addButton(withTitle:reviewable ? String(localized:"Not Now",bundle:.checkmate):"OK").setAccessibilityIdentifier("network-crash-dismiss")
        alert.window.setAccessibilityIdentifier("network-crash-notice")
        alert.beginSheetModal(for:window){[weak self] response in MainActor.assumeIsolated{if reviewable,response == .alertFirstButtonReturn{self?.model.reviewNetworkCrash(entry,moves:moves)}}}
    }
    @objc func resign(){
        if model.session.mode == .network{model.resignNetworkGame();return}
        guard !model.review.active,model.session.canResign else{return}
        let a=NSAlert.destructive(String(localized:"Resign this game?",bundle:.checkmate),String(localized:"The game is recorded as a loss. Start a new game or review it afterwards.",bundle:.checkmate),action:String(localized:"Resign",bundle:.checkmate,comment:"Verb: give up the game"))
        let shown=practiceGame
        present(a){[weak self] r in guard r == .alertFirstButtonReturn,let self,self.stillShowing(shown) else{return};self.model.session.resign();self.refresh()}
    }
    /// The practice game a sheet or menu was shown over. Moves played meanwhile keep it the same game (`exactly` also
    /// requires the same position in it); a new, restored or forked game (an agent can start one while the sheet is
    /// up) or another activity does not, even when it reaches an identical position. The session's position counter
    /// advances on every position change, so `exactly` also refuses a move and its undo, which restore the history.
    var practiceGame:(generation:Int,position:Int,history:[String]) {let s=model.session;return (s.gameGeneration,s.position,s.rules.history)}
    func stillShowing(_ shown:(generation:Int,position:Int,history:[String]),exactly:Bool=false)->Bool {
        let now=practiceGame;return !model.review.active && !model.reviewWorkspace && model.session.mode == .practice && now.generation==shown.generation && (exactly ? now.position==shown.position && now.history==shown.history:now.history.starts(with:shown.history))}
    @objc func showSettings(){if settings==nil{settings=SettingsWindow(model:model)};settings?.showWindow(nil);settings?.window?.makeKeyAndOrderFront(nil)}
    func openSettings(category:SettingsCategory){if settings==nil{settings=SettingsWindow(model:model)};settings?.show(category:category)}
    /// Edit ▸ Undo (⌘Z) reaches here when no text field claims it: it takes back the move, as Game ▸ Take Back does. In a
    /// review it undoes the window's last undoable action instead (a saved review's deletion).
    @objc func undo(_ sender:Any?){switch model.undoAction{case .restoreReview:model.undoDeletion();case .nothing:return;case .game:undo()}}
    @objc func undo(){
        guard !model.review.active,!model.reviewWorkspace else{return};board.cancelAnimation()
        if model.learning.mini{model.learning.undoMini()}
        else if model.learning.attemptStep{model.learning.attempt.undo()}
        else if let exercise=trainingExercise{if let training=model.training,ControlBarModel.canTakeBack(training,exercise){training.undo()}}
        else{model.session.undo()}
    }
    // MARK: Lesson menu: each item performs the bar's own control, so the two never disagree.
    private var bar:ControlBarModel {controls.rootView.barModel}
    /// The bar control a Lesson menu item stands for now, if the bar shows one.
    private func barItem(for action:Selector)->ControlBarItem? {
        let candidates:[ControlBarAction]
        switch action {
        case #selector(lessonPlayPause):candidates=[.playPause,.reviewPlayPause,.demoPlayPause]
        case #selector(lessonPrevious):candidates=[.previousLesson,.previousStep,.reviewPrevious,.demoPrevious,.previewPrevious]
        case #selector(lessonNext):candidates=[.nextLesson,.nextStep,.reviewNext,.demoNext,.previewNext]
        case #selector(lessonFromStart):candidates=[.stepFromStart]
        case #selector(barHint):candidates=[.attemptHint,.hint,.trainingHint]
        default:return nil
        }
        // The review library hides the bar and owns the window: nothing reaches the lesson behind it.
        guard !model.reviewWorkspace else{return nil}
        let shown=bar;return candidates.lazy.compactMap{shown.item($0)}.first
    }
    private func performBar(_ action:Selector){guard let item=barItem(for:action),item.enabled else{NSSound.beep();return};controls.rootView.perform(item.action);refresh()}
    @objc func lessonPlayPause(){performBar(#selector(lessonPlayPause))}
    @objc func lessonPrevious(){performBar(#selector(lessonPrevious))}
    @objc func lessonNext(){performBar(#selector(lessonNext))}
    @objc func lessonFromStart(){performBar(#selector(lessonFromStart))}
    @objc func barHint(){performBar(#selector(barHint))}
    @objc func restorePrevious(){guard !model.review.active,!model.reviewWorkspace else{return};board.cancelAnimation();do{try model.session.restorePrevious()}catch{showError(error)}}
    func showError(_ error:Error){present(Self.failureAlert(error))}
    /// The board area stays square while the learner resizes, with drawers open or closed: its side follows the edge
    /// dragged most and never exceeds the screen.
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize)->NSSize {
        guard sender.inLiveResize,!animating,!fullscreen,!fullscreenTransition else{return frameSize}
        let drawers=drawerWidth,current=sender.frame.size
        var side=abs(frameSize.height-current.height)>abs(frameSize.width-current.width) ? frameSize.height:frameSize.width-drawers
        // The floor is the usual minimum only where the screen fits it with these drawers, as `squareAfterResize` fits.
        let fit=sender.screen.map{min($0.visibleFrame.height,$0.visibleFrame.width-drawers)} ?? .greatestFiniteMagnitude,lowest=min(Metrics.minimum,max(Metrics.minimumFitted,fit))
        side=max(lowest,min(side,fit));boardItem.minimumThickness=lowest
        fixedBoardWidth?.constant=side;return NSSize(width:side+drawers,height:side)
    }
    private var drawerWidth:CGFloat {(sidebarItem.isCollapsed ? 0:leftExtent)+(inspectorItem.isCollapsed ? 0:rightExtent)}
    /// Zoom (and a title-bar double-click set to zoom) grows the board area to the largest square the screen allows.
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect)->NSRect {
        let drawers=drawerWidth,side=max(Metrics.minimumFitted,min(defaultFrame.height,defaultFrame.width-drawers))
        return NSRect(x:defaultFrame.minX,y:defaultFrame.maxY-side,width:side+drawers,height:side)
    }
    private var squaring=false
    /// Any other resize — Zoom, Fill and tiling, a display change — is re-squared from the new height, so the board
    /// area is never left stretched and a stretched frame is never saved.
    private func squareAfterResize(){
        guard !squaring,!animating,!fullscreen,!fullscreenTransition,let window=window,!window.inLiveResize,!window.styleMask.contains(.fullScreen),let board=fixedBoardWidth?.constant,abs(window.frame.height-board)>1 || abs(window.frame.width-board-drawerWidth)>1 else{return}
        squaring=true;defer{squaring=false}
        let drawers=drawerWidth;var side=window.frame.height
        if let visible=window.screen?.visibleFrame{side=max(Metrics.minimumFitted,min(side,visible.height,visible.width-drawers))}
        boardItem.minimumThickness=min(Metrics.minimum,max(Metrics.minimumFitted,side))
        let frame=NSRect(x:window.frame.minX,y:window.frame.maxY-side,width:side+drawers,height:side)
        fixedBoardWidth?.constant=side;window.setFrame(frame,display:true)
        coreFrame=NSRect(x:frame.minX+(sidebarItem.isCollapsed ? 0:leftExtent),y:frame.minY,width:side,height:side);fittedOrigin=window.frame.origin;rememberFrame()
    }
    func window(_ window:NSWindow,willUseFullScreenContentSize proposedSize:NSSize)->NSSize {window.screen?.frame.size ?? proposedSize}
    func windowWillEnterFullScreen(_ notification:Notification){(window as? BoardWindow)?.drawerOrigins=nil;(window as? BoardWindow)?.drawerViewport=nil;if NativePolicy.silent{print("fullscreen: will enter")};guard let window=window else{return};fullscreenTransition=true;fullscreen=true;normalCoreFrame=coreFrame;fixedBoardWidth?.isActive=false;installFullscreenLayout(window)}
    /// Fullscreen fixes the split view to the screen's width and the board area to what the open drawers leave.
    private func installFullscreenLayout(_ window:NSWindow){
        if let screen=window.screen{fixedBoardWidth?.constant=max(1,screen.frame.width-(sidebarItem.isCollapsed ? 0:leftExtent)-(inspectorItem.isCollapsed ? 0:rightExtent));fixedBoardWidth?.isActive=true;fullscreenWidth?.isActive=false;fullscreenWidth=split.view.widthAnchor.constraint(equalToConstant:screen.frame.width);fullscreenWidth?.isActive=true;sidebarItem.preferredThicknessFraction=Metrics.left/screen.frame.width;inspectorItem.preferredThicknessFraction=Metrics.right/screen.frame.width}
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView;inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
    }
    /// Minimised is away, like hidden (TX-5).
    func windowDidMiniaturize(_ notification:Notification){model.setAway(true)}
    func windowDidDeminiaturize(_ notification:Notification){model.setAway(NSApp.isHidden)}
    func windowDidEnterFullScreen(_ notification:Notification){if NativePolicy.silent{print("fullscreen: did enter")};fullscreenTransition=false;if let window=window,let screen=window.screen{window.setFrame(screen.frame,display:true)};split.view.autoresizingMask=[.width,.height];if fullscreen,let parent=split.view.superview{split.view.frame=parent.bounds};titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()};animateDrawers()}
    func windowDidFailToEnterFullScreen(_ window:NSWindow){fullscreenTransition=false;windowDidExitFullScreen(Notification(name:NSWindow.didExitFullScreenNotification,object:window))}
    /// Exit removed the fullscreen width (`windowWillExitFullScreen`); staying in fullscreen puts it back.
    func windowDidFailToExitFullScreen(_ window:NSWindow){fullscreenTransition=false;fullscreen=true;fixedBoardWidth?.isActive=true;installFullscreenLayout(window);if let parent=split.view.superview{split.view.frame=parent.bounds};titleView.syncCenter();animateDrawers()}
    func windowWillExitFullScreen(_ notification:Notification){if NativePolicy.silent{print("fullscreen: will exit")};fullscreenTransition=true;fullscreenWidth?.isActive=false;fullscreenWidth=nil;fixedBoardWidth?.isActive=false}
    func windowDidExitFullScreen(_ notification:Notification){
        fullscreenWidth?.isActive=false;fullscreenWidth=nil;fullscreen=false;fullscreenTransition=false
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings;inspectorItem.collapseBehavior=sidebarItem.collapseBehavior
        if let core=normalCoreFrame,let window=window {
            coreFrame=core
            let left=sidebarItem.isCollapsed ? 0:leftExtent,right=inspectorItem.isCollapsed ? 0:rightExtent
            let proposed=NSRect(x:core.minX-left,y:core.minY,width:core.width+left+right,height:core.height)
            let restored=WindowGeometry.restored([Double(proposed.minX),Double(proposed.minY),Double(proposed.width),Double(proposed.height)],screens:NSScreen.screens.map(\.visibleFrame),drawers:Double(left+right),minimumSide:Double(Metrics.minimumFitted))
            fittedLayout = abs(restored.width-proposed.width)>1 || abs(restored.height-proposed.height)>1
            let boardWidth=restored.width-left-right
            boardItem.minimumThickness=min(Metrics.minimum,max(Metrics.minimumFitted,boardWidth))
            fittedOrigin=nil;fixedBoardWidth?.constant=boardWidth;window.setFrame(restored,display:true);fixedBoardWidth?.isActive=true;fittedOrigin=window.frame.origin
        }
        titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()};animateDrawers()
    }

    private func rememberFrame(){guard !animating,!fullscreenTransition,let window=window,!window.styleMask.contains(.fullScreen) else{return};let frame=window.frame;if !fittedLayout{coreFrame?.origin=NSPoint(x:frame.minX+(sidebarItem.isCollapsed ? 0:leftExtent),y:frame.minY)}else if let placed=fittedOrigin{coreFrame?.origin.x+=frame.minX-placed.x;coreFrame?.origin.y+=frame.minY-placed.y};fittedOrigin=frame.origin;let preferred=coreFrame ?? frame;model.session.state.window.frame=[Double(preferred.minX),Double(preferred.minY),Double(preferred.width),Double(preferred.height)];model.session.emit(semantic:false,save:true)}
    func windowDidMove(_ notification:Notification){rememberFrame()}
    func windowDidEndLiveResize(_ notification:Notification){if let window=window{let side=min(main.view.frame.width,window.frame.height);coreFrame=NSRect(x:window.frame.minX+(sidebarItem.isCollapsed ? 0:leftExtent),y:window.frame.minY,width:side,height:side)};fittedLayout=false;rememberFrame()}
    func windowDidResize(_ notification:Notification){if fullscreen,let parent=split.view.superview{split.view.frame=parent.bounds};squareAfterResize();titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()}}
    /// Closing the window quits, so it asks the same questions as Quit; a cancelled quit keeps the window open.
    func windowShouldClose(_ sender:NSWindow)->Bool{NSApp.terminate(nil);return false}
    func snapshot(_ path:String){Task{do{try await capture(path)}catch{FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))}}}
    func capture(_ path:String) async throws {
        try await Self.captureWindow(window,path:path)
    }
    static func captureWindow(_ window:NSWindow?,path:String) async throws {
        guard let id=window?.windowNumber else{throw CheckmateError.unavailable(String(localized:"There is no window to capture.",bundle:.checkmate))}
        let content:SCShareableContent
        if #available(macOS 14.4,*) {content=try await SCShareableContent.currentProcess}
        else {content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)}
        guard let own=content.windows.first(where:{$0.windowID==CGWindowID(id)}) else{throw CheckmateError.unavailable(String(localized:"The window is not available for capture.",bundle:.checkmate))}
        // The image is the window alone at the display's own pixel scale: a fixed 2× scale left a 1× window in one corner.
        let filter=SCContentFilter(desktopIndependentWindow:own),scale=CGFloat(filter.pointPixelScale)
        let config=SCStreamConfiguration();config.width=Int((filter.contentRect.width*scale).rounded());config.height=Int((filter.contentRect.height*scale).rounded());config.showsCursor=false;config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw CheckmateError.invalid(String(localized:"The capture could not be encoded as PNG.",bundle:.checkmate))}
        try png.write(to:URL(fileURLWithPath:path))
    }
}
