import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit
import CheckmateCore
final class BoardWindow:NSWindow {
    var drawerViewport:NSRect?,drawerOrigins:ClosedRange<CGFloat>?
    override func setFrame(_ frameRect:NSRect,display flag:Bool){var frame=frameRect;if let available=drawerViewport{frame.origin.x=max(available.minX,min(available.maxX-frame.width,frame.minX));frame.origin.y=max(available.minY,min(available.maxY-frame.height,frame.minY))};if let range=drawerOrigins{frame.origin.x=max(range.lowerBound,min(range.upperBound,frame.minX))};super.setFrame(frame,display:flag)}
}
final class BoardTitleView:NSView {
    weak var board:NSView?
    let label=textLabel("Practice · White vs Stockfish",15,.semibold),tabs=NSSegmentedControl(labels:["Game","Demonstration"],trackingMode:.selectOne,target:nil,action:nil)
    override init(frame:NSRect){super.init(frame:frame);addSubview(label);addSubview(tabs);label.alignment = .center;tabs.isHidden=true}
    required init?(coder:NSCoder){fatalError()}
    override var mouseDownCanMoveWindow:Bool {true}
    override var intrinsicContentSize:NSSize {NSSize(width:300,height:28)}
    override func layout(){super.layout();syncCenter()}
    func syncCenter(){guard let board=board,let boardWindow=board.window,let ownWindow=window else{return};let screen=boardWindow.convertToScreen(NSRect(origin:board.convert(NSPoint(x:board.bounds.midX,y:0),to:nil),size:.zero)).origin;let center=convert(ownWindow.convertFromScreen(NSRect(origin:screen,size:.zero)).origin,from:nil).x;let labelWidth=min(300,max(120,board.bounds.width-Metrics.padding*2)),tabWidth=min(280,labelWidth);label.frame=NSRect(x:center-labelWidth/2,y:4,width:labelWidth,height:20);tabs.frame=NSRect(x:center-tabWidth/2,y:0,width:tabWidth,height:28)}

}
@MainActor final class GameWindow:NSWindowController,NSWindowDelegate,NSToolbarDelegate,NSMenuItemValidation {
    let relationships=RelationshipController()
    let model:NativeModel,board=BoardView(),split=NSSplitViewController(),main=NSViewController()
    var navigation:NSViewController!,inspector:NSViewController!
    let titleView=BoardTitleView(frame:NSRect(x:0,y:0,width:300,height:28))
    var sidebarItem:NSSplitViewItem!,boardItem:NSSplitViewItem!,inspectorItem:NSSplitViewItem!,controls:NSHostingView<TransportContent>!,welcome:NSHostingView<WelcomeContent>!,puzzles:NSHostingView<PuzzleLibraryContent>!
    var availableFrameOverride:NSRect?
    private var fullscreen=false,fullscreenTransition=false
    private var normalCoreFrame:NSRect?
    private var fullscreenWidth:NSLayoutConstraint?
    var desiredLeft=false,desiredRight=false,animating=false,fixedBoardWidth:NSLayoutConstraint?,settings:SettingsWindow?
    private var observations:Set<AnyCancellable>=[]
    private var coreFrame:NSRect?
    private var fittedLayout=false
    private var announcedReviewIdentity=""
    private(set) var errorBanner:NSHostingView<StorageErrorBanner>?
    func setCoreFrame(_ frame:NSRect){coreFrame=frame;fixedBoardWidth?.constant=frame.width;fixedBoardWidth?.isActive=true;window?.setFrame(frame,display:true);window?.contentView?.layoutSubtreeIfNeeded()}
    private let sidebarID=NSToolbarItem.Identifier("checkmate.sidebar"),inspectorID=NSToolbarItem.Identifier("checkmate.inspector"),titleID=NSToolbarItem.Identifier("checkmate.title"),settingsID=NSToolbarItem.Identifier("checkmate.settings")
    init(model:NativeModel){self.model=model
        let w=BoardWindow(contentRect:NSRect(x:0,y:0,width:Metrics.core,height:Metrics.core),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:w);w.title="Checkmate";w.isMovableByWindowBackground=true;w.titleVisibility = .hidden;w.titlebarSeparatorStyle = .none;w.titlebarAppearsTransparent=true;w.isReleasedWhenClosed=false;w.isRestorable=false;w.delegate=self;w.autorecalculatesKeyViewLoop=true;w.identifier=NSUserInterfaceItemIdentifier("main");w.collectionBehavior=[.fullScreenPrimary]
        main.view=BackgroundView();navigation=NSHostingController(rootView:SidebarContent(session:model.session,learning:model.learning,model:model));inspector=NSHostingController(rootView:DetailContent(session:model.session,learning:model.learning,model:model,voice:model.voice,relationships:relationships,inspect:{[weak self] mode in self?.toggleRelationship(mode)}))
        split.splitView=ContentSplitView();split.splitView.autoresizingMask=[.width,.height];split.splitView.isVertical=true;split.splitView.dividerStyle = .thin
        sidebarItem=NSSplitViewItem(sidebarWithViewController:navigation);boardItem=NSSplitViewItem(viewController:main);inspectorItem=NSSplitViewItem(inspectorWithViewController:inspector)
        for (item,width) in [(sidebarItem!,Metrics.left),(inspectorItem!,Metrics.right)] {item.minimumThickness=width;item.maximumThickness=width;item.automaticMaximumThickness=width;item.preferredThicknessFraction=NSSplitViewItem.unspecifiedDimension;item.holdingPriority = .defaultHigh;item.canCollapse=true;item.canCollapseFromWindowResize=false;item.allowsFullHeightLayout=true;item.collapseBehavior = .preferResizingSplitViewWithFixedSiblings;item.titlebarSeparatorStyle = .none;item.isCollapsed=true}
        boardItem.minimumThickness=Metrics.minimum;boardItem.titlebarSeparatorStyle = .none;split.addSplitViewItem(sidebarItem);split.addSplitViewItem(boardItem);split.addSplitViewItem(inspectorItem);w.contentViewController=split
        let leftLimit=navigation.view.widthAnchor.constraint(lessThanOrEqualToConstant:Metrics.left),rightLimit=inspector.view.widthAnchor.constraint(lessThanOrEqualToConstant:Metrics.right);leftLimit.priority=NSLayoutConstraint.Priority(999);rightLimit.priority=NSLayoutConstraint.Priority(999);NSLayoutConstraint.activate([leftLimit,rightLimit])
        let toolbar=NSToolbar(identifier:"Checkmate.Native.Toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false;w.toolbar=toolbar;w.toolbarStyle = .unified
        model.learning.onLessonOpened={[weak self] in self?.relationships.dismiss();self?.board.cancelAnimation();self?.showDetails();self?.refresh()}
        model.onReview={[weak self] in self?.relationships.dismiss();self?.board.cancelAnimation();self?.showDetails();self?.refresh()}
        board.reviewKey={[weak self] key in guard let self=self,self.model.review.active,self.model.review.branch==nil else{return false};switch key{case 123:self.model.review.step(-1);case 124:self.model.review.step(1);case 125:self.model.review.last();case 126:self.model.review.first();case 49:self.model.review.playing ? self.model.review.pause():self.model.review.play();default:return false};self.refresh();return true}
        board.dropReview={[weak self] data in self?.model.importReviewData(data)}
        model.review.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        model.onImport={[weak self] in guard let self=self else{return};self.desiredLeft=model.session.state.window.left;self.desiredRight=model.session.state.window.right;self.animateDrawers()};board.onLayout={[weak self] in self?.titleView.needsLayout=true;self?.titleView.syncCenter()};board.activate={[weak self] square in self?.select(square)};board.inspectRelationship={[weak self] mode in self?.toggleRelationship(mode)};board.dismissRelationships={[weak self] in guard let self=self else{return false};let dismissed=self.relationships.dismiss();if dismissed{self.refresh()};return dismissed};board.clearSelection={[weak self] in guard let self=self else{return};if self.model.session.mode == .practice{self.model.session.clearSelection()}else{self.model.learning.clearSelection()}};titleView.board=board;titleView.tabs.target=self;titleView.tabs.action=#selector(selectTab)
        controls=NSHostingView(rootView:TransportContent(session:model.session,learning:model.learning,voice:model.voice,review:model.review,newGame:{[weak self] in self?.newGame()},showDetails:{[weak self] in self?.showDetails()},resumeGame:{[weak model] in model?.resumeAfterFailedRestore()}));welcome=NSHostingView(rootView:WelcomeContent(title:"",goals:[]));puzzles=NSHostingView(rootView:PuzzleLibraryContent(learning:model.learning,session:model.session))
        for v in [board,controls!,welcome!,puzzles!] {main.view.addSubview(v);v.translatesAutoresizingMaskIntoConstraints=false}
        NSLayoutConstraint.activate([controls.leadingAnchor.constraint(equalTo:main.view.leadingAnchor),controls.trailingAnchor.constraint(equalTo:main.view.trailingAnchor),controls.bottomAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.bottomAnchor),controls.heightAnchor.constraint(equalToConstant:Metrics.header)])
        // Errors overlay the top of the fixed board area; the board's size and layout are unaffected.
        let banner=NSHostingView(rootView:StorageErrorBanner(model:model));errorBanner=banner;banner.isHidden=model.storageError==nil
        main.view.addSubview(banner);banner.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([banner.leadingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.leadingAnchor),banner.trailingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.trailingAnchor),banner.topAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.topAnchor)])
        model.$storageError.removeDuplicates().receive(on:RunLoop.main).sink{[weak self] message in guard let self=self else{return};self.errorBanner?.isHidden=message==nil;if let message=message{NSAccessibility.post(element:self.errorBanner as Any,notification:.announcementRequested,userInfo:[.announcement:message,.priority:NSAccessibilityPriorityLevel.high.rawValue])}}.store(in:&observations)
        let playbackLine=NSHostingView(rootView:LessonProgressContent(review:model.review,session:model.session,learning:model.learning))
        main.view.addSubview(playbackLine);playbackLine.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([playbackLine.leadingAnchor.constraint(equalTo:main.view.leadingAnchor),playbackLine.trailingAnchor.constraint(equalTo:main.view.trailingAnchor),playbackLine.bottomAnchor.constraint(equalTo:main.view.bottomAnchor),playbackLine.heightAnchor.constraint(equalToConstant:Metrics.playbackLineHeight)])
        for v in [board,welcome!,puzzles!] {NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.leadingAnchor,constant:Metrics.padding),v.trailingAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.trailingAnchor,constant:-Metrics.padding),v.topAnchor.constraint(equalTo:main.view.safeAreaLayoutGuide.topAnchor,constant:Metrics.smallGap),v.bottomAnchor.constraint(equalTo:controls.topAnchor,constant:-Metrics.smallGap)])}
        model.session.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations);model.learning.objectWillChange.sink{[weak self] _ in DispatchQueue.main.async{self?.refresh()}}.store(in:&observations)
        model.voice.$connected.removeDuplicates().filter{$0}.receive(on:RunLoop.main).sink{[weak self] _ in self?.showDetails()}.store(in:&observations)
        let sound=model.session.onMove;model.session.onMove={[weak self] move in sound?(move);guard let self=self else{return};self.board.animate(move,duration:Double(model.session.state.settings.pieceDuration)/1000)}
        let miniSound=model.learning.onMiniMove;model.learning.onMiniMove={[weak self] move in miniSound?(move);self?.board.animate(move,duration:Double(model.session.state.settings.pieceDuration)/1000)}
        let miniReset=model.learning.onMiniReset;model.learning.onMiniReset={[weak self] in miniReset?();self?.board.cancelAnimation()}
        let restored=WindowGeometry.restored(model.session.state.window.frame,screens:NSScreen.screens.map(\.visibleFrame),size:Double(Metrics.core),minimum:Double(Metrics.minimum))
        fixedBoardWidth=main.view.widthAnchor.constraint(equalToConstant:restored.width);fixedBoardWidth!.isActive=true
        coreFrame=restored;w.setFrame(restored,display:false);refresh()
        desiredLeft=model.session.state.window.left;desiredRight=model.session.state.window.right
        DispatchQueue.main.async{self.boardItem.minimumThickness=Metrics.minimum;self.animateDrawers();self.model.session.reply()}
    }
    required init?(coder:NSCoder){fatalError()}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,sidebarID,.sidebarTrackingSeparator,.flexibleSpace,titleID,.flexibleSpace,settingsID,.inspectorTrackingSeparator,inspectorID,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem? {
        if id == .sidebarTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:0)};if id == .inspectorTrackingSeparator{return NSTrackingSeparatorToolbarItem(identifier:id,splitView:split.splitView,dividerIndex:1)}
        let item=NSToolbarItem(itemIdentifier:id)
        if id==titleID{item.view=titleView;item.isBordered=false;item.label="Current activity";return item}
        item.image=NSImage(systemSymbolName:id==sidebarID ? "sidebar.left":id==inspectorID ? "sidebar.right":"gearshape",accessibilityDescription:nil);item.label=id==sidebarID ? "Toggle Sidebar":id==inspectorID ? "Toggle Game Details":"Settings";item.toolTip=item.label;item.target=self;item.action=id==sidebarID ? #selector(toggleLeft):id==inspectorID ? #selector(toggleRight):#selector(showSettings);item.isBordered=true;return item
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
        let core=coreFrame ?? window.frame,left=desiredLeft ? Metrics.left:0,right=desiredRight ? Metrics.right:0
        var target=NSRect(x:core.minX-left,y:core.minY,width:core.width+left+right,height:core.height)
        fittedLayout=fullscreen || !available.contains(target)
        if !fullscreen {
            target.size.width=min(target.width,available.width);target.origin.x=max(available.minX,min(available.maxX-target.width,target.minX));target.size.height=min(target.height,available.height);target.origin.y=max(available.minY,min(available.maxY-target.height,target.minY))
        }
        let targetWidth=fullscreen ? split.view.bounds.width:target.width
        let targetCore=targetWidth-left-right
        boardItem.minimumThickness=min(Metrics.minimum,max(Metrics.minimumFitted,targetCore))
        let outward = !fullscreen && !fittedLayout && abs(main.view.frame.width-core.width)<1
        sidebarItem.collapseBehavior = fullscreen ? .preferResizingSiblingsWithFixedSplitView:.preferResizingSplitViewWithFixedSiblings
        inspectorItem.collapseBehavior=sidebarItem.collapseBehavior
        sidebarItem.preferredThicknessFraction=outward ? NSSplitViewItem.unspecifiedDimension:Metrics.left/targetWidth
        inspectorItem.preferredThicknessFraction=outward ? NSSplitViewItem.unspecifiedDimension:Metrics.right/targetWidth
        width.isActive = !fullscreen
        if !fullscreen,let native=window as? BoardWindow{native.drawerViewport=available;native.drawerOrigins=min(window.frame.minX,target.minX)...max(window.frame.minX,target.minX)}
        NSAnimationContext.runAnimationGroup{context in
            context.allowsImplicitAnimation=true;context.duration=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:Metrics.animation;context.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
            if !self.fullscreen{width.constant=targetCore;}
            if changeLeft{sidebarItem.animator().isCollapsed = !desiredLeft}
            if changeRight{inspectorItem.animator().isCollapsed = !desiredRight}
        } completionHandler:{[weak self] in guard let self=self else{return};self.window?.contentView?.layoutSubtreeIfNeeded();self.titleView.syncCenter();(self.window as? BoardWindow)?.drawerOrigins=nil;(self.window as? BoardWindow)?.drawerViewport=nil;self.animating=false;self.animateDrawers()}
    }

    @objc func selectTab(){model.session.selectPresentation(titleView.tabs.selectedSegment==1)}
    func select(_ sq:String){
        if model.review.active{if let from=model.review.selected,model.review.branch != nil,model.review.displayRules?.moves(from).contains(where:{$0.to==sq && $0.promotion != nil})==true{let menu=NSMenu();for (title,piece) in [("Queen","q"),("Rook","r"),("Bishop","b"),("Knight","n")]{let item=NSMenuItem(title:title,action:#selector(promoteReview(_:)),keyEquivalent:"");item.target=self;item.representedObject=[sq,piece];menu.addItem(item)};menu.popUp(positioning:nil,at:board.squareRect(sq).origin,in:board);return};try? model.review.selectSquare(sq);refresh();return}

        if relationships.mode != nil{if model.session.mode == .practice{try? model.session.inspectPiece(sq)};relationships.select(board.position[sq] == nil ? nil:sq);refresh();return}
        let s=model.session;if s.mode == .practice {
        if let from=s.selected,s.inspection?.legalNow==true,s.destinations.contains(sq),(s.presentationHidden || s.preview==nil && s.demonstration==nil) {let promotion=s.rules.moves(from).contains{$0.to==sq && $0.promotion != nil};if promotion {let menu=NSMenu();for (title,piece) in [("Queen","q"),("Rook","r"),("Bishop","b"),("Knight","n")] {let item=NSMenuItem(title:title,action:#selector(promote(_:)),keyEquivalent:"");item.target=self;item.representedObject=[from,sq,piece];menu.addItem(item)};menu.popUp(positioning:nil,at:board.squareRect(sq).origin,in:board);return}}
        do{try s.select(sq)}catch{showError(String(describing:error))}
    }else{model.learning.click(sq)};refresh()}
    @objc func promoteReview(_ item:NSMenuItem){guard let values=item.representedObject as? [String] else{return};try? model.review.selectSquare(values[0],promotion:values[1]);refresh()}
    @objc func promote(_ item:NSMenuItem){guard let value=item.representedObject as? [String] else{return};try? model.session.playWhite(from:value[0],to:value[1],promotion:value[2]);refresh()}
    func toggleRelationship(_ mode:RelationshipMode){guard let selected=board.selected,board.position[selected] != nil else{return};relationships.toggle(mode,selected:selected);refresh();if relationships.mode != nil{showDetails()}}
    @objc func showProtection(){toggleRelationship(.protected)}
    @objc func showAttacks(){toggleRelationship(.attacked)}
    @objc func dismissInspection(){relationships.dismiss();refresh()}
    func refresh(){let s=model.session,l=model.learning
        if model.review.active{let review=model.review;board.position=review.board;board.theme=s.state.settings.boardTheme;board.selected=review.selected;board.destinations=review.branch==nil ? []:review.destinations;board.attacked=[];board.highlights=[];board.arrows=[];board.counts=[];board.explicitMotion=nil;board.relationshipMode=nil;board.relationshipConnectors=[];
            let move=review.branch.flatMap{branch in review.branchPly>0 ? branch.moves[review.branchPly-1]:nil} ?? review.document?.nodes[review.nodeID].uci
            if let move=move {let from=String(move.prefix(2)),to=String(move.dropFirst(2).prefix(2));board.highlights=[Highlight(sq:from,kind:"last"),Highlight(sq:to,kind:"last")];if review.branch != nil{board.arrows=[[from,to]]}}
            if let rules=review.displayRules,rules.check,let king=rules.board.first(where:{$0.value==rules.turn+"k"})?.key{board.highlights.append(Highlight(sq:king,kind:"check"))}
            board.highlights += review.highlights+s.voiceFocus.map{Highlight(sq:$0,kind:"focus")};board.arrows += review.arrows
            if announcedReviewIdentity != review.identity{announcedReviewIdentity=review.identity;let node=review.document?.nodes[review.nodeID];let announcement=review.branch==nil ? "Review, \(node?.fullmove ?? 1), \(node?.side=="b" ? "Black":"White"), \(node?.san ?? "starting position")":"Imagined line, move \(review.branchPly)";NSAccessibility.post(element:board,notification:.announcementRequested,userInfo:[.announcement:announcement,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
            board.isHidden=false;puzzles.isHidden=true;welcome.isHidden=true;titleView.label.stringValue=review.branch==nil ? "Review · Original game":"Review · Imagined moves";titleView.label.isHidden=false;titleView.tabs.isHidden=true;board.needsDisplay=true;return}

        board.position=s.displayBoard;board.theme=s.state.settings.boardTheme;board.selected=s.mode == .practice ? s.selected:l.picked.first;board.destinations=s.mode == .practice ? s.destinations:l.destinations;board.attacked=s.mode == .practice ? s.inspection?.attacks ?? []:[]
        board.highlights=s.highlights+s.voiceFocus.map{Highlight(sq:$0,kind:"focus")};if s.mode == .practice,s.displayView=="game" {if let last=s.rules.records.last{board.highlights += [Highlight(sq:last.from,kind:"last"),Highlight(sq:last.to,kind:"last")]};if s.rules.check,let king=s.rules.board.first(where:{$0.value==s.rules.turn+"k"})?.key{board.highlights.append(Highlight(sq:king,kind:"check"))}};var moveArrows=s.arrows;board.counts=[];board.explicitMotion=nil
        if s.mode != .practice {board.highlights+=l.frame.hl+l.picked.map{Highlight(sq:$0,kind:"focus")};moveArrows=l.frame.arrows+moveArrows;board.counts=l.frame.counts ?? [];board.explicitMotion=l.frame.motion}
        if !s.presentationHidden,let d=s.demonstration {let frame=d.lines[d.line].frames[d.ply];moveArrows=frame.arrows+moveArrows;board.highlights+=frame.highlights}
        relationships.update(board:board.position,fen:s.mode == .practice ? s.displayFen:nil,selected:board.selected,identity:s.displayIdentity)
        board.relationshipMode=relationships.report?.mode
        board.relationshipConnectors=relationships.report?.relations.map{RelationshipConnector(source:$0.square,target:relationships.report!.square,limited:$0.limited)} ?? []
        if let report=relationships.report{board.selected=report.square;board.destinations=[];board.attacked=[];moveArrows=[];board.highlights.removeAll{$0.kind != "check" && $0.kind != "no"}}
        board.arrows=moveArrows
        board.needsDisplay=true
        let library=s.mode == .puzzles && l.activePuzzle==nil,titlecard=s.mode == .lesson && l.frame.board==nil
        board.isHidden=library || titlecard;puzzles.isHidden = !library;welcome.isHidden = !titlecard
        if titlecard {welcome.rootView=WelcomeContent(title:l.library.stepTitles[l.lessonIndex][l.step],goals:l.current.teaches ?? [])}
        titleView.label.stringValue=s.mode == .practice ? "Practice · \(s.humanSide=="b" ? "Black":"White") vs Stockfish":s.mode == .puzzles ? "Quick puzzles":l.mini ? l.miniKind.title:l.current.title
        let temporary=s.preview != nil || s.demonstration != nil;titleView.label.isHidden=temporary;titleView.tabs.isHidden = !temporary;titleView.tabs.setLabel(s.demonstration != nil ? "Demonstration":"Try a move",forSegment:1);titleView.tabs.selectedSegment=s.presentationHidden ? 0:1;titleView.needsLayout=true
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {if [#selector(showProtection),#selector(showAttacks),#selector(dismissInspection)].contains(item.action){if item.action == #selector(dismissInspection){return relationships.mode != nil};item.state=(item.action == #selector(showProtection) && relationships.mode == .protected || item.action == #selector(showAttacks) && relationships.mode == .attacked) ? .on:.off;return board.selected.flatMap{board.position[$0]} != nil && !board.isHidden};guard [#selector(newGame),#selector(undo),#selector(restorePrevious)].contains(item.action) else{return true};guard !model.review.active,model.session.mode == .practice else{return false};if item.action == #selector(undo){return !model.session.rules.history.isEmpty};if item.action == #selector(restorePrevious){return !model.session.state.practice.previousGame.isEmpty};return true}
    @objc func newGame(){
        guard !model.review.active else{return}
        if model.learning.mini,model.session.mode == .lesson {
            if model.learning.miniGame?.history.isEmpty != false{model.learning.restartMini();return}
            let alert=NSAlert();alert.messageText="Start a new \(model.learning.miniKind.title) game?";alert.informativeText="This replaces the current mini-game.";alert.addButton(withTitle:"New Game");alert.addButton(withTitle:"Cancel");alert.beginSheetModal(for:window!){[weak self] response in if response == .alertFirstButtonReturn{self?.model.learning.restartMini()}};return
        }
        guard model.session.mode == .practice else{return};let a=NSAlert();a.messageText="Start a new game?";a.informativeText="Your current game will be available under Restore Previous Game.";a.addButton(withTitle:"New Game");a.addButton(withTitle:"Cancel");a.beginSheetModal(for:window!){r in if r == .alertFirstButtonReturn{self.board.cancelAnimation();self.model.session.newGame()}}}
    @objc func showSettings(){if settings==nil{settings=SettingsWindow(model:model)};settings?.showWindow(nil);settings?.window?.makeKeyAndOrderFront(nil)}
    @objc func undo(){guard !model.review.active else{return};board.cancelAnimation();if model.learning.mini,model.session.mode == .lesson{model.learning.undoMini()}else{model.session.undo()}}
    @objc func restorePrevious(){guard !model.review.active else{return};try? model.session.restorePrevious()}
    func showError(_ message:String){let alert=NSAlert();alert.messageText=message;alert.beginSheetModal(for:window!)}
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize)->NSSize {if sender.inLiveResize && !animating && !fullscreen && !fullscreenTransition{fixedBoardWidth?.constant=max(Metrics.minimum,frameSize.width-(sidebarItem.isCollapsed ? 0:Metrics.left)-(inspectorItem.isCollapsed ? 0:Metrics.right))};return sender.inLiveResize && sidebarItem.isCollapsed && inspectorItem.isCollapsed && !fullscreen && !fullscreenTransition && !animating ? NSSize(width:frameSize.width,height:frameSize.width):frameSize}
    func window(_ window:NSWindow,willUseFullScreenContentSize proposedSize:NSSize)->NSSize {window.screen?.frame.size ?? proposedSize}
    func windowWillEnterFullScreen(_ notification:Notification){(window as? BoardWindow)?.drawerOrigins=nil;(window as? BoardWindow)?.drawerViewport=nil;if NativePolicy.silent{print("fullscreen: will enter")};guard let window=window else{return};fullscreenTransition=true;fullscreen=true;normalCoreFrame=coreFrame;fixedBoardWidth?.isActive=false;if let screen=window.screen{fullscreenWidth=split.view.widthAnchor.constraint(equalToConstant:screen.frame.width);fullscreenWidth?.isActive=true;sidebarItem.preferredThicknessFraction=Metrics.left/screen.frame.width;inspectorItem.preferredThicknessFraction=Metrics.right/screen.frame.width};sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView;inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView}
    func windowDidEnterFullScreen(_ notification:Notification){if NativePolicy.silent{print("fullscreen: did enter")};fullscreenTransition=false;if let window=window,let screen=window.screen{window.setFrame(screen.frame,display:true)};split.view.autoresizingMask=[.width,.height];if fullscreen,let parent=split.view.superview{split.view.frame=parent.bounds};titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()};animateDrawers()}
    func windowDidFailToEnterFullScreen(_ window:NSWindow){fullscreenTransition=false;windowDidExitFullScreen(Notification(name:NSWindow.didExitFullScreenNotification,object:window))}
    func windowDidFailToExitFullScreen(_ window:NSWindow){fullscreenTransition=false;fullscreen=true;fixedBoardWidth?.isActive=false;sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView;inspectorItem.collapseBehavior=sidebarItem.collapseBehavior;animateDrawers()}
    func windowWillExitFullScreen(_ notification:Notification){if NativePolicy.silent{print("fullscreen: will exit")};fullscreenTransition=true;fullscreenWidth?.isActive=false;fullscreenWidth=nil;fixedBoardWidth?.isActive=false}
    func windowDidExitFullScreen(_ notification:Notification){
        fullscreenWidth?.isActive=false;fullscreenWidth=nil;fullscreen=false;fullscreenTransition=false
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings;inspectorItem.collapseBehavior=sidebarItem.collapseBehavior
        if let core=normalCoreFrame,let window=window {
            coreFrame=core
            let left=sidebarItem.isCollapsed ? 0:Metrics.left,right=inspectorItem.isCollapsed ? 0:Metrics.right
            let proposed=NSRect(x:core.minX-left,y:core.minY,width:core.width+left+right,height:core.height)
            let restored=WindowGeometry.restored([Double(proposed.minX),Double(proposed.minY),Double(proposed.width),Double(proposed.height)],screens:NSScreen.screens.map(\.visibleFrame))
            fittedLayout = abs(restored.width-proposed.width)>1 || abs(restored.height-proposed.height)>1
            let boardWidth=restored.width-left-right
            boardItem.minimumThickness=min(Metrics.minimum,max(Metrics.minimumFitted,boardWidth))
            fixedBoardWidth?.constant=boardWidth;window.setFrame(restored,display:true);fixedBoardWidth?.isActive=true
        }
        titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()};animateDrawers()
    }

    private func rememberFrame(){guard !animating,!fullscreenTransition,let window=window,!window.styleMask.contains(.fullScreen) else{return};let frame=window.frame;if !fittedLayout{coreFrame?.origin=NSPoint(x:frame.minX+(sidebarItem.isCollapsed ? 0:Metrics.left),y:frame.minY)};let preferred=coreFrame ?? frame;model.session.state.window.frame=[Double(preferred.minX),Double(preferred.minY),Double(preferred.width),Double(preferred.height)];model.session.emit(semantic:false,save:true)}
    func windowDidMove(_ notification:Notification){rememberFrame()}
    func windowDidEndLiveResize(_ notification:Notification){if let window=window{coreFrame=NSRect(x:window.frame.minX+(sidebarItem.isCollapsed ? 0:Metrics.left),y:window.frame.minY,width:main.view.frame.width,height:window.frame.height)};fittedLayout=false;rememberFrame()}
    func windowDidResize(_ notification:Notification){if fullscreen,let parent=split.view.superview{split.view.frame=parent.bounds};titleView.syncCenter();DispatchQueue.main.async{[weak self] in self?.titleView.syncCenter()}}
    func windowWillClose(_ notification:Notification){NSApp.terminate(nil)}
    func snapshot(_ path:String){Task{try? await capture(path)}}
    func capture(_ path:String) async throws {
        try await Self.captureWindow(window,path:path)
    }
    static func captureWindow(_ window:NSWindow?,path:String) async throws {
        guard let id=window?.windowNumber else{return}
        let content:SCShareableContent
        if #available(macOS 14.4,*) {content=try await SCShareableContent.currentProcess}
        else {content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)}
        guard let own=content.windows.first(where:{$0.windowID==CGWindowID(id)}) else{return}
        let config=SCStreamConfiguration();config.width=Int(own.frame.width*2);config.height=Int(own.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
    }
}
