import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit
import CheckmateCore
final class BoardWindow:NSWindow {
    /// Edit ▸ Undo (⌘Z): a text field in focus handles it first; otherwise the window would answer it with its own
    /// empty undo manager and the game never heard it. It goes to the game instead: take back, undo turn.
    @objc func undo(_ sender:Any?){(windowController as? GameWindow)?.undo()}
    override func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(undo(_:)),let controller=windowController as? GameWindow{return controller.validateMenuItem(item)}
        return super.validateMenuItem(item)
    }
    var drawerViewport:NSRect?,drawerOrigins:ClosedRange<CGFloat>?
    override func setFrame(_ frameRect:NSRect,display flag:Bool){var frame=frameRect;if let available=drawerViewport{frame.origin.x=max(available.minX,min(available.maxX-frame.width,frame.minX));frame.origin.y=max(available.minY,min(available.maxY-frame.height,frame.minY))};if let range=drawerOrigins{frame.origin.x=max(range.lowerBound,min(range.upperBound,frame.minX))};super.setFrame(frame,display:flag)}
}
/// Drawers have fixed widths and open only from their toolbar buttons. A dragged divider would collapse one
/// behind the controller's back: its toggle then needed two clicks and the board moved instead of the window edge.
final class DrawerSplitViewController:NSSplitViewController {
    override func splitView(_ splitView:NSSplitView,effectiveRect proposedEffectiveRect:NSRect,forDrawnRect drawnRect:NSRect,ofDividerAt dividerIndex:Int)->NSRect {.zero}
}
final class BoardTitleView:NSView {
    weak var board:NSView?
    let label=textLabel("Practice · White vs Stockfish",15,.semibold),tabs=NSSegmentedControl(labels:["Game","Demonstration"],trackingMode:.selectOne,target:nil,action:nil)
    override init(frame:NSRect){super.init(frame:frame);addSubview(label);addSubview(tabs);label.alignment = .center;tabs.isHidden=true}
    required init?(coder:NSCoder){fatalError()}
    override var mouseDownCanMoveWindow:Bool {true}
    override var intrinsicContentSize:NSSize {NSSize(width:300,height:28)}
    override func layout(){super.layout();syncCenter()}
    func syncCenter(){guard let board=board,let boardWindow=board.window,let ownWindow=window else{return};let screen=boardWindow.convertToScreen(NSRect(origin:board.convert(NSPoint(x:board.bounds.midX,y:0),to:nil),size:.zero)).origin;let center=convert(ownWindow.convertFromScreen(NSRect(origin:screen,size:.zero)).origin,from:nil).x;let reach=2*max(0,min(center,bounds.width-center)),labelWidth=min(300,reach,max(120,board.bounds.width-Metrics.padding*2)),tabWidth=min(280,labelWidth);label.frame=NSRect(x:center-labelWidth/2,y:4,width:labelWidth,height:20);tabs.frame=NSRect(x:center-tabWidth/2,y:0,width:tabWidth,height:28)}

}
@MainActor final class GameWindow:NSWindowController,NSWindowDelegate,NSToolbarDelegate,NSMenuItemValidation {
    let relationships=RelationshipController()
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
    private var coreFrame:NSRect?
    private var fittedLayout=false
    /// Where the window last stood when fitting or the learner placed it: while fitted, a move from here is the learner's
    /// and carries the preferred frame with it, so a later drawer change or relaunch keeps it.
    private var fittedOrigin:NSPoint?
    private var announcedReviewIdentity=""
    private(set) var errorBanner:NSHostingView<StorageErrorBanner>?
    func setCoreFrame(_ frame:NSRect){coreFrame=frame;fittedOrigin=nil;fixedBoardWidth?.constant=frame.width;fixedBoardWidth?.isActive=true;window?.setFrame(frame,display:true);fittedOrigin=window?.frame.origin;window?.contentView?.layoutSubtreeIfNeeded()}
    private let sidebarID=NSToolbarItem.Identifier("checkmate.sidebar"),inspectorID=NSToolbarItem.Identifier("checkmate.inspector"),titleID=NSToolbarItem.Identifier("checkmate.title"),settingsID=NSToolbarItem.Identifier("checkmate.settings")
    init(model:NativeModel){self.model=model
        let w=BoardWindow(contentRect:NSRect(x:0,y:0,width:Metrics.core,height:Metrics.core),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:w);w.title="Checkmate";w.isMovableByWindowBackground=true;w.titleVisibility = .hidden;w.titlebarSeparatorStyle = .none;w.titlebarAppearsTransparent=true;w.isReleasedWhenClosed=false;w.isRestorable=false;w.delegate=self;w.autorecalculatesKeyViewLoop=true;w.identifier=NSUserInterfaceItemIdentifier("main");w.collectionBehavior=[.fullScreenPrimary];w.tabbingMode = .disallowed
        main.view=BackgroundView();navigation=NSHostingController(rootView:SidebarContent(session:model.session,learning:model.learning,model:model,network:model.network));inspector=ToolbarInsetHostingController(rootView:DetailContent(session:model.session,learning:model.learning,model:model,voice:model.voice,relationships:relationships,inspect:{[weak self] mode in self?.toggleRelationship(mode)}))
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
        model.onImport={[weak self] in guard let self=self else{return};self.desiredLeft=self.model.session.state.window.left;self.desiredRight=self.model.session.state.window.right;self.animateDrawers()};board.onLayout={[weak self] in self?.titleView.needsLayout=true;self?.titleView.syncCenter()};board.activate={[weak self] square in self?.select(square)};board.canDrag={[weak self] square in self?.dragMoves(square) ?? false};model.movePlacedDirectly={[weak self] move in self?.board.isDropped(move) ?? false};board.inspectRelationship={[weak self] mode in self?.toggleRelationship(mode)};board.dismissRelationships={[weak self] in guard let self=self else{return false};let dismissed=self.relationships.dismiss();if dismissed{self.refresh()};return dismissed};board.clearSelection={[weak self] in guard let self=self else{return};if self.model.review.active{self.model.review.clearSelection();self.refresh()}else if self.model.session.mode == .network{self.model.network.clearSelection();self.refresh()}else if self.model.session.mode == .practice{self.model.session.clearSelection()}else if let training=self.model.training,self.trainingExercise != nil{training.clearSelection();self.refresh()}else{self.model.learning.clearSelection()}};titleView.board=board;titleView.tabs.target=self;titleView.tabs.action=#selector(selectTab)
    }
    /// The board area: transport, welcome card, puzzle and training libraries, error banner and playback line.
    private func buildBoardArea(){
        controls=VisibleHostingView(rootView:TransportContent(session:model.session,learning:model.learning,voice:model.voice,review:model.review,newGame:{[weak self] in self?.newGame()},showDetails:{[weak self] in self?.showDetails()},continueWithStockfish:{[weak model] in model?.companion.disable();model?.session.continueWithStockfish()},resumeGame:{[weak model] in model?.resumeAfterFailedRestore()},training:model.training,openTrainingLibrary:{[weak model] in model?.trainingLibrary()},continueLesson:{[weak self] in guard let self else{return};self.model.continueLesson();self.announceLesson()},previousLessonEnd:{[weak self] in guard let self else{return};self.model.previousLessonEnd();self.announceLesson()},returnToOriginal:{[weak model] in guard let model else{return};model.review.clearBranch();model.saveReview()},rowsChanged:{[weak self] rows in self?.setControlRows(rows)},framesChanged:{[weak self] frames in self?.barFrames=frames}));welcome=VisibleHostingView(rootView:WelcomeContent(title:""));puzzles=VisibleHostingView(rootView:PuzzleLibraryContent(learning:model.learning,session:model.session))
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
        // D11: the permission help appears only on the two denial signals, and goes once access comes back.
        model.network.$permissionHelp.removeDuplicates().receive(on:RunLoop.main).sink{[weak self] shown in self?.syncPermissionHelp(shown)}.store(in:&observations)
        // The network place's lobby and game chrome live in the details drawer: open it on arrival, as a lesson or review does.
        model.session.$activity.removeDuplicates().filter{$0 == .at(.network)}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.session.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations);model.learning.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        // A review read aloud keeps to its sheet: the drawer stays as it is.
        model.voice.$connected.removeDuplicates().filter{$0}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,self.model.voice.miniReviewSession==nil else{return};self.showDetails()}.store(in:&observations)
        // These messages are shown only in the details drawer, which starts closed; open it when one appears.
        model.session.$error.removeDuplicates().compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.session.$preview.map{$0?.error}.removeDuplicates().compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        model.learning.$feedback.removeDuplicates().filter{!$0.isEmpty}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,self.model.learning.activePuzzle != nil else{return};self.showDetails()}.store(in:&observations)
        // A connection attempt or a live connection that ends with a message other than "Disconnected" failed.
        model.voice.$connecting.merge(with:model.voice.$connected).removeDuplicates().filter{!$0}.receive(on:RunLoop.main).sink{[weak self] _ in guard let self,!self.model.voice.connected,!self.model.voice.connecting,self.model.voice.status != "Disconnected" else{return};self.showDetails()}.store(in:&observations)
        let undone=model.session.onUndo;model.session.onUndo={[weak self] in undone?();self?.board.cancelAnimation()}
        let sound=model.session.onMove;model.session.onMove={[weak self] move in sound?(move);guard let self=self else{return};self.board.animate(move,duration:Double(self.model.session.state.settings.pieceDuration)/1000);self.announce(move)}
        let miniSound=model.learning.onMiniMove;model.learning.onMiniMove={[weak self] move in miniSound?(move);guard let self else{return};self.board.animate(move,landing:self.model.learning.miniGame?.board,duration:Double(self.model.session.state.settings.pieceDuration)/1000);if self.model.learning.miniGame?.computer==true,move.color=="b"{self.announce("The computer played \(move.san).")}}
        let attemptSound=model.learning.onAttemptMove;model.learning.onAttemptMove={[weak self] move in attemptSound?(move);guard let self else{return};self.board.animate(move,landing:self.model.learning.attempt.board,duration:Double(self.model.session.state.settings.pieceDuration)/1000);self.announce(self.attemptAnnouncement(for:move))}
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
            let sheet=NSWindow(contentViewController:NSHostingController(rootView:MiniGameReviewSheet(review:review,voice:model.voice,close:{[weak reviewer] in reviewer?.dismissSheet()})))
            sheet.title="\(review.kind.title) review";miniReviewSheet=sheet;window.beginSheet(sheet)
        } else if let sheet=miniReviewSheet {miniReviewSheet=nil;window?.endSheet(sheet)}
    }
    /// The open mini-game review sheet's content, for the acceptance scenario.
    var miniReviewSheetShown:Bool {miniReviewSheet?.sheetParent != nil}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,sidebarID,.sidebarTrackingSeparator,.flexibleSpace,titleID,.flexibleSpace,settingsID,.inspectorTrackingSeparator,inspectorID,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem? {
        if id == .sidebarTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:0)};if id == .inspectorTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:1)}
        let item=NSToolbarItem(itemIdentifier:id)
        if id==titleID{item.view=titleView;item.isBordered=false;item.label="Current activity";return item}
        item.image=NSImage(systemSymbolName:id==sidebarID ? "sidebar.left":id==inspectorID ? "sidebar.right":"gearshape",accessibilityDescription:nil);item.label=id==sidebarID ? "Toggle Sidebar":id==inspectorID ? "Toggle Game Details":"Settings";item.toolTip=item.label;item.target=self;item.action=id==sidebarID ? #selector(toggleLeft):id==inspectorID ? #selector(toggleRight):#selector(showSettings);item.isBordered=true;return item
    }
    /// In lessons and puzzles the details drawer holds the guidance, and its toggle says so.
    var guidanceShown:Bool {!model.review.active && (model.session.mode == .lesson && !model.learning.mini || model.learning.activePuzzle != nil)}
    /// The toolbar's details toggle is named for what it holds: in lessons and puzzles it is the guidance, which is
    /// what lets the bar do without its own guidance button. Whether it is open shows in its tooltip and View menu title.
    private func syncGuidanceToggle(){
        guard let item=window?.toolbar?.items.first(where:{$0.itemIdentifier==inspectorID}) else{return}
        let label=guidanceShown ? "Lesson Guidance":"Toggle Game Details",tip=guidanceShown ? (desiredRight ? "Hide the lesson guidance (⌥⌘I)":"Show the lesson guidance (⌥⌘I)"):"Toggle Game Details"
        if item.label != label{item.label=label};if item.toolTip != tip{item.toolTip=tip}
    }
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
            context.allowsImplicitAnimation=true;context.duration=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:Metrics.animation;context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
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
        let attempt=model.learning.attemptStep ? model.learning.attempt:nil
        if relationships.mode != nil{let plays=s.mode == .practice && s.selected != sq && s.inspection?.legalNow==true && s.destinations.contains(sq) || attempt.map{$0.selected != sq && $0.destinations.contains(sq)} == true;if plays{relationships.dismiss()}else{if s.mode == .practice{try? s.inspectPiece(sq)};relationships.select(board.position[sq] == nil ? nil:sq);refresh();return}}
        if s.mode == .practice {
        if let from=s.selected,s.inspection?.legalNow==true,s.destinations.contains(sq),(s.presentationHidden || s.preview==nil && s.demonstration==nil) {let promotion=s.rules.moves(from).contains{$0.to==sq && $0.promotion != nil};if promotion {let shown=practiceGame;showPromotionMenu(at:sq,action:#selector(promote(_:))){PracticePromotion(from:from,to:sq,piece:$0,game:shown)};return}}
        do{try s.select(sq)}catch{showError(error)}
    }else if let training=model.training,trainingExercise != nil{training.click(sq)}
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
        if s.mode == .practice{return board.position[square]?.first.map(String.init)==s.humanSide}
        // Selecting squares is click-only; a piece the learner moves may be dragged.
        if let exercise=trainingExercise{return !exercise.finished && (exercise.task == .move || exercise.task == .game && model.training?.games.thinking == false) && board.position[square]?.first.map(String.init)==exercise.scenario.learner}
        if l.attemptStep{return l.attempt.learnerToMove && board.position[square]?.first=="w"}
        return l.mini || l.activePuzzle != nil && l.exercise?.kind=="move"
    }
    /// The promotion choices at a square; each item carries `payload(piece)` for its action.
    private func showPromotionMenu(at sq:String,action:Selector,payload:(String)->Any){
        let menu=NSMenu()
        for (title,piece) in [("Queen","q"),("Rook","r"),("Bishop","b"),("Knight","n")]{let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.image=promotionImage(piece);item.toolTip="Promote to a "+title.lowercased();item.representedObject=payload(piece);menu.addItem(item)}
        menu.popUp(positioning:nil,at:board.squareRect(sq).origin,in:board)
    }
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
        var text=(move.color==s.humanSide ? "You played ":"\(move.color=="w" ? "White":"Black") played ")+move.san+"."
        if s.rules.checkmate{text+=move.color==s.humanSide ? " Checkmate. You win.":" Checkmate."}else if s.rules.check{text+=move.color==s.humanSide ? " Check.":" Your king is in check."}else if s.rules.draw{text+=" The game is drawn."}
        return text
    }
    /// What VoiceOver hears when a lesson exercise move lands: the move, check or mate, and the exercise's outcome.
    func attemptAnnouncement(for move:MoveRecord)->String {
        let attempt=model.learning.attempt!,rules=attempt.rules
        var text=(move.color=="w" ? "You played ":"The computer played ")+move.san+"."
        if rules.checkmate{text+=" Checkmate."}else if rules.check{text+=move.color=="w" ? " Check.":" Your king is in check."}else if rules.draw{text+=" The game is drawn."}
        switch attempt.phase {case .achieved?:text+=" Well done! "+(attempt.judgement?.feedback ?? "");case .offTrack?,.failed?:text+=" "+(attempt.judgement?.feedback ?? "");default:break}
        return text
    }
    /// The bar takes a second row when its sides no longer fit beside the centre group; the board yields the height.
    private func setControlRows(_ rows:Int){let height=Metrics.header+CGFloat(max(0,rows-1))*(ControlBarView.rowHeight+Metrics.smallGap);if controlsHeight.constant != height{controlsHeight.constant=height}}
    /// An arrow that crossed into another lesson says where the learner now is.
    private func announceLesson(){announce("Now in \(model.learning.localizedTitle(index:model.learning.lessonIndex)).")}
    private func announce(_ text:String){NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:text,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    func refresh(){syncGuidanceToggle();syncMenus();let s=model.session,l=model.learning
        // The learner's own side sits nearest them in practice; reviews and lessons keep White at the bottom.
        board.blackAtBottom = !model.reviewWorkspace && !model.review.active && (s.mode == .practice && s.humanSide=="b" || trainingExercise?.scenario.learner=="b" || s.mode == .network && model.network.blackAtBottom)
        board.reviewNavigation=model.review.active && model.review.branch==nil
        reviewWorkspaceView.isHidden = !model.reviewWorkspace;controls.isHidden=model.reviewWorkspace;if workspaceFill.isActive != model.reviewWorkspace{workspaceAboveControls.isActive=false;workspaceFill.isActive=model.reviewWorkspace;workspaceAboveControls.isActive = !model.reviewWorkspace}
playbackLineView?.isHidden=model.reviewWorkspace
        trainingLibraryView.isHidden=true
        if model.reviewWorkspace{board.isHidden=true;welcome.isHidden=true;puzzles.isHidden=true;titleView.label.stringValue="Game review";titleView.label.isHidden=false;titleView.tabs.isHidden=true;return}
        board.theme=s.state.settings.boardTheme
        if model.review.active{let review=model.review;applyBoard(reviewPresentation(review));board.relationshipMode=nil;board.relationshipConnectors=[]
            if announcedReviewIdentity != review.identity{announcedReviewIdentity=review.identity;let node=review.document?.nodes[review.nodeID];let announcement=review.branch==nil ? "Review, \(node?.fullmove ?? 1), \(node?.side=="b" ? "Black":"White"), \(node?.san ?? "starting position")":"Imagined line, move \(review.branchPly)";NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:announcement,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
            board.isHidden=false;puzzles.isHidden=true;welcome.isHidden=true;titleView.label.stringValue=review.branch==nil ? "Review · Original game":"Review · Imagined moves";titleView.label.isHidden=false;titleView.tabs.isHidden=true;board.needsDisplay=true;return}

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
        titleView.label.stringValue=s.mode == .network ? model.network.boardTitle:s.mode == .practice ? "Practice · \(s.humanSide=="b" ? "Black":"White") vs Stockfish":s.mode == .puzzles ? "Quick puzzles":l.mini ? l.miniKind.title:s.mode == .training ? trainingExercise?.definition.title ?? "Training":l.localizedTitle(index:l.lessonIndex)+(l.attemptStatus.map{" · "+$0} ?? "")
        let temporary=s.preview != nil || s.demonstration != nil;titleView.label.isHidden=temporary;titleView.tabs.isHidden = !temporary;titleView.tabs.setLabel(s.demonstration != nil ? "Demonstration":"Try a move",forSegment:1);titleView.tabs.selectedSegment=s.presentationHidden ? 0:1;titleView.needsLayout=true
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
        // The network game's own items act on its controller (LAN-play plan D9); in network mode nothing else in the
        // Game or Lesson menu shows (`syncMenus`).
        if let action=item.action,let enabled=Self.networkItemEnabled(action,network:model.session.mode == .network,game:model.network){return enabled}
        if let action=item.action,[#selector(lessonPlayPause),#selector(lessonPrevious),#selector(lessonNext),#selector(lessonFromStart),#selector(barHint)].contains(action) {
            let shown=barItem(for:action)
            let fallback=[#selector(lessonPlayPause):"Play",#selector(lessonPrevious):"Previous Step",#selector(lessonNext):"Next Step",#selector(lessonFromStart):"Play Step from Start",#selector(barHint):"Hint"][action] ?? item.title
            // The title follows the control: Pause while playing, and the lesson's name where the arrow crosses into it.
            switch shown?.action {
            case .previousLesson?,.nextLesson?:item.title=shown!.label.replacingOccurrences(of:"Previous lesson:",with:"Previous Lesson:").replacingOccurrences(of:"Next lesson:",with:"Next Lesson:")
            case .playPause?,.reviewPlayPause?,.demoPlayPause?:item.title=shown!.symbol=="pause.fill" ? "Pause":"Play"
            case .attemptHint?,.trainingHint?:item.title=shown!.label
            default:item.title=fallback
            }
            return shown?.enabled ?? false
        }
        if item.action == #selector(toggleRight){item.title=guidanceShown ? (desiredRight ? "Hide Lesson Guidance":"Show Lesson Guidance"):"Toggle Game Details";return true}
        if item.action == #selector(undo as () -> Void) || item.action == NSSelectorFromString("undo:"),!model.review.active,!model.reviewWorkspace {
            if model.learning.attemptStep{if item.action == #selector(undo as () -> Void){item.title="Undo Turn"};return model.learning.attempt.hasMoves}
            if let exercise=trainingExercise{return model.training.map{ControlBarModel.canTakeBack($0,exercise)} ?? false}
            if item.action == #selector(undo as () -> Void){item.title=model.learning.mini ? "Undo Turn":"Take Back Move"}
        }
        if [#selector(showProtection),#selector(showAttacks),#selector(dismissInspection)].contains(item.action){if item.action == #selector(dismissInspection){return relationships.mode != nil};item.state=(item.action == #selector(showProtection) && relationships.mode == .protected || item.action == #selector(showAttacks) && relationships.mode == .attacked) ? .on:.off;return !model.review.active && trainingExercise==nil && (model.session.mode != .network || model.network.inspectable) && board.selected.flatMap{board.position[$0]} != nil && !board.isHidden};guard [#selector(newGame),#selector(undo as () -> Void),NSSelectorFromString("undo:"),#selector(restorePrevious),#selector(claimDraw),#selector(resign)].contains(item.action) else{return true};guard !model.review.active,!model.reviewWorkspace else{return false};if model.learning.mini,![#selector(restorePrevious),#selector(claimDraw),#selector(resign)].contains(item.action){return item.action == #selector(newGame) || model.learning.miniGame?.history.isEmpty == false};guard model.session.mode == .practice else{return false};if item.action == #selector(undo as () -> Void) || item.action == NSSelectorFromString("undo:"){return model.session.canTakeBack};if item.action == #selector(claimDraw){return model.session.claimableDraw != nil};if item.action == #selector(resign){return !model.session.finished && !model.session.rules.history.isEmpty};if item.action == #selector(restorePrevious){return !model.session.state.practice.previousGame.isEmpty};return true}
    @objc func newGame(){
        guard !model.review.active,!model.reviewWorkspace else{return}
        if model.learning.mini {
            if model.learning.miniGame?.history.isEmpty != false{model.learning.restartMini();return}
            // The sheet answers for the mini-game it was shown over: one replaced meanwhile (an agent, a restart) is kept.
            let shown=model.learning.miniGame.map{($0.kind,$0.opponentSeed)}
            let alert=NSAlert();alert.messageText="Start a new \(model.learning.miniKind.title) game?";alert.informativeText="This replaces the current mini-game.";alert.addButton(withTitle:"New Game");alert.addButton(withTitle:"Cancel");alert.beginSheetModal(for:window!){[weak self] response in guard response == .alertFirstButtonReturn,let self,self.model.learning.mini,let game=self.model.learning.miniGame,let shown,game.kind==shown.0,game.opponentSeed==shown.1 else{return};self.model.learning.restartMini()};return
        }
        guard model.session.mode == .practice else{return};let a=NSAlert();a.messageText="Start a new game?";a.informativeText=model.session.state.practice.previousGame.isEmpty ? "Your current game will be available under Restore Previous Game.":"Your current game will be available under Restore Previous Game, replacing the game kept there now."
        let side=NSPopUpButton(frame:NSRect(x:0,y:0,width:220,height:28));side.addItems(withTitles:["Play as White","Play as Black"]);side.selectItem(at:model.session.humanSide=="b" ? 1:0);side.setAccessibilityLabel("Your side");a.accessoryView=side
        let shown=practiceGame
        a.addButton(withTitle:"New Game");a.addButton(withTitle:"Cancel");a.beginSheetModal(for:window!){r in guard r == .alertFirstButtonReturn,self.stillShowing(shown) else{return};self.board.cancelAnimation();self.model.session.newGame(side:side.indexOfSelectedItem==1 ? "b":"w")}}
    @objc func claimDraw(){if model.session.mode == .network{model.network.claimDraw();return};guard !model.review.active,model.session.mode == .practice else{return};model.session.claimDraw();refresh()}
    // MARK: The network game's menu items (LAN-play plan D9)
    /// The Game menu's base items in network mode: Resign, Offer Draw, Claim Draw, Flip Board and Leave Game. The only
    /// others it shows are `inspectorActions`, and those only at board insight or more.
    static let networkActions:Set<Selector>=[#selector(resign),#selector(offerDraw),#selector(claimDraw),#selector(flipBoard),#selector(leaveGame)]
    /// The piece inspector's items, shown in network mode only when the agreed level allows it (assistance plan A1).
    static let inspectorActions:Set<Selector>=[#selector(showProtection),#selector(showAttacks),#selector(dismissInspection)]
    /// Items that exist only for the network game, hidden elsewhere.
    static let networkOnlyActions:Set<Selector>=[#selector(offerDraw),#selector(flipBoard),#selector(leaveGame)]
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
    @objc func flipBoard(){guard model.session.mode == .network else{return};model.network.flip();refresh()}
    @objc func leaveGame(){guard model.session.mode == .network else{return};model.leaveNetworkGame()}
    /// D11's help: a sheet whose button opens System Settings › Privacy & Security › Local Network.
    private func syncPermissionHelp(_ shown:Bool){
        if shown,permissionAlert==nil,let window {
            let alert=NSAlert();alert.messageText="Allow Checkmate on your local network"
            alert.informativeText="Finding and joining network games needs Local Network access. Turn on Checkmate in System Settings › Privacy & Security › Local Network; a game that is waiting carries on by itself once it is on."
            alert.addButton(withTitle:"Open Local Network Settings").setAccessibilityIdentifier("network-permission-open-settings")
            alert.addButton(withTitle:"Not Now").setAccessibilityIdentifier("network-permission-close")
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
        if reviewable{alert.addButton(withTitle:"Review").setAccessibilityIdentifier("network-crash-review")}
        alert.addButton(withTitle:reviewable ? "Not Now":"OK").setAccessibilityIdentifier("network-crash-dismiss")
        alert.window.setAccessibilityIdentifier("network-crash-notice")
        alert.beginSheetModal(for:window){[weak self] response in MainActor.assumeIsolated{if reviewable,response == .alertFirstButtonReturn{self?.model.reviewNetworkCrash(entry,moves:moves)}}}
    }
    @objc func resign(){
        if model.session.mode == .network{model.resignNetworkGame();return}
        guard !model.review.active,model.session.mode == .practice,!model.session.finished,let window=window else{return}
        let a=NSAlert();a.messageText="Resign this game?";a.informativeText="The game is recorded as a loss. Start a new game or review it afterwards.";a.addButton(withTitle:"Resign");let cancel=a.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r";a.window.defaultButtonCell=cancel.cell as? NSButtonCell
        let shown=practiceGame
        a.beginSheetModal(for:window){[weak self] r in guard r == .alertFirstButtonReturn,let self,self.stillShowing(shown) else{return};self.model.session.resign();self.refresh()}
    }
    /// The practice game a sheet or menu was shown over. Moves played meanwhile keep it the same game (`exactly` also
    /// requires the same position in it); a new, restored or forked game (an agent can start one while the sheet is
    /// up) or another activity does not, even when it reaches an identical position. The session's position counter
    /// advances on every position change, so `exactly` also refuses a move and its undo, which restore the history.
    var practiceGame:(generation:Int,position:Int,history:[String]) {let s=model.session;return (s.gameGeneration,s.position,s.rules.history)}
    func stillShowing(_ shown:(generation:Int,position:Int,history:[String]),exactly:Bool=false)->Bool {
        let now=practiceGame;return !model.review.active && !model.reviewWorkspace && model.session.mode == .practice && now.generation==shown.generation && (exactly ? now.position==shown.position && now.history==shown.history:now.history.starts(with:shown.history))}
    @objc func showSettings(){if settings==nil{settings=SettingsWindow(model:model)};settings?.showWindow(nil);settings?.window?.makeKeyAndOrderFront(nil)}
    @objc func showAbout(){showSettings();settings?.selectCategory("About")}
    /// Edit ▸ Undo (⌘Z) reaches here when no text field claims it: it takes back the move, as Game ▸ Take Back does.
    @objc func undo(_ sender:Any?){undo()}
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
    func showError(_ error:Error){
        // ROLE_FORBIDDEN is an MCP contract code; people see what it means.
        let message=(error as? CheckmateError).flatMap{if case .invalid("ROLE_FORBIDDEN")=$0{return "This move can’t be played now. Wait for your turn."};return nil} ?? userFacingMessage(error,fallback:"That action could not be completed.")
        let alert=NSAlert();alert.messageText=message;alert.beginSheetModal(for:window!)
    }
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
        guard let id=window?.windowNumber else{throw CheckmateError.unavailable("There is no window to capture.")}
        let content:SCShareableContent
        if #available(macOS 14.4,*) {content=try await SCShareableContent.currentProcess}
        else {content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)}
        guard let own=content.windows.first(where:{$0.windowID==CGWindowID(id)}) else{throw CheckmateError.unavailable("The window is not available for capture.")}
        // The image is the window alone at the display's own pixel scale: a fixed 2× scale left a 1× window in one corner.
        let filter=SCContentFilter(desktopIndependentWindow:own),scale=CGFloat(filter.pointPixelScale)
        let config=SCStreamConfiguration();config.width=Int((filter.contentRect.width*scale).rounded());config.height=Int((filter.contentRect.height*scale).rounded());config.showsCursor=false;config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw CheckmateError.invalid("The capture could not be encoded as PNG.")}
        try png.write(to:URL(fileURLWithPath:path))
    }
}
