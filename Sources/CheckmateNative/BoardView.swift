import AppKit
import CheckmateCore
final class SquareAccessibility:NSAccessibilityElement {
    weak var board:BoardView?;let square:String
    init(board:BoardView,square:String){self.board=board;self.square=square;super.init();setAccessibilityParent(board)}
    override func accessibilityRole()->NSAccessibility.Role? {.button}
    override func accessibilityLabel()->String? {guard let board=board else{return square};var parts=[square];if let p=board.position[square]{parts += [p.first=="w" ? "White":"Black",BoardView.names[String(p.suffix(1)),default:"piece"]]};if board.selected==square{parts.append("selected")};if board.destinations.contains(square){parts.append(!board.destinationsPlayable ? "possible destination, not playable now":board.captures(on:square) ? "capture destination":"move destination")};if board.attacked.contains(square){parts.append("attacked or defended")};for h in board.highlights where h.sq==square{parts.append(h.kind=="check" ? "in check":h.kind=="no" ? "unavailable lesson destination":h.kind=="last" ? "part of the last move":h.kind=="target" ? "target square":h.kind=="answer" ? "in your answer":h.kind=="hint" ? "shown by a hint":"highlighted by the coach")};for a in board.arrows where a.count==2{if a[0]==square{parts.append("suggested move to "+a[1])};if a[1]==square{parts.append("suggested move from "+a[0])}};for connection in board.relationshipConnectors {let description=connection.limited ? "restricted or conditional":"";if connection.source==square{parts.append("\(board.relationshipMode == .protected ? "protects":"attacks") \(connection.target) \(description)")};if connection.target==square{parts.append("\(board.relationshipMode == .protected ? "protected by":"attacked by") \(connection.source) \(description)")}};return parts.joined(separator:", ")}
    override func accessibilityFrame()->NSRect {guard let b=board,let w=b.window else{return .zero};return w.convertToScreen(b.convert(b.squareRect(square),to:nil))}
    override func isAccessibilityFocused()->Bool {board?.focus==square && board?.window?.firstResponder === board}
    override func setAccessibilityFocused(_ value:Bool){if value{board?.focus=square;board?.window?.makeFirstResponder(board);board?.keyboardFocusVisible=true;board?.needsDisplay=true;NSAccessibility.post(element:self,notification:.focusedUIElementChanged)}}
    override func accessibilityPerformPress()->Bool {guard let board=board else{return false};board.focus=square;board.window?.makeFirstResponder(board);board.keyboardFocusVisible=true;board.activate?(square);board.needsDisplay=true;return true}
}
/// Review files are read off the main thread, one at a time, shared by Finder opens and board drops: a newer read
/// replaces an older one, and a read that finishes after another activity was chosen is discarded, so a slow file
/// never replaces what the learner opened or chose since. Starting a read first supersedes any older open or import
/// still running, so that one cannot finish during the read and discard it.
@MainActor final class ReviewFileReader {
    var activity:()->Int={0},supersede:()->Void={},read:@Sendable (URL) throws->Data=ReviewDrop.bounded
    /// A synchronous read cannot be cancelled, so only one runs; a request made during it waits, and a newer one replaces it.
    private var reading=false,queued:(file:URL,prepare:@Sendable (URL) throws->URL,started:Int,deliver:(Data)->Void,failed:(Error)->Void)?
    func load(_ file:URL,deliver:@escaping (Data)->Void,failed:@escaping ()->Void){load(file,deliver:deliver,rejected:{_ in failed()})}
    /// `prepare` runs off the main thread before the read, so resolving and checking a file on a slow volume never blocks.
    func load(_ file:URL,prepare:@escaping @Sendable (URL) throws->URL={$0},deliver:@escaping (Data)->Void,rejected:@escaping (Error)->Void){supersede();queued=(file,prepare,activity(),deliver,rejected);if !reading{readNext()}}
    private func readNext(){guard let request=queued else{reading=false;return};queued=nil;guard activity()==request.started else{readNext();return};reading=true;let read=read,prepare=request.prepare
        Task{let result=await Task.detached{Result{try read(prepare(request.file))}}.value;guard queued==nil,activity()==request.started else{readNext();return};reading=false;switch result{case .success(let data):request.deliver(data);case .failure(let error):request.failed(error)}}}
}
/// A dropped file is accepted only if it is a downloaded regular file within the import limit: a symlink is followed to
/// its file, and a pipe or an iCloud placeholder is refused with a reason. It touches the file system, so it runs off the main thread.
enum ReviewDrop {
    struct Rejection:Error {let reason:String}
    static let unreadable="This file could not be read."
    @Sendable static func validated(_ url:URL)throws -> URL {
        let file=url.resolvingSymlinksInPath()
        let values:URLResourceValues;do{values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey])}catch{throw Rejection(reason:unreadable)}
        guard values.isRegularFile==true,let size=values.fileSize else{throw Rejection(reason:"Drop a PGN or FEN file.")}
        if let status=values.ubiquitousItemDownloadingStatus,status != .current{throw Rejection(reason:"This file is still in iCloud. Download it in Finder, then drop it again.")}
        guard size<=ReviewPolicy.maximumBytes else{throw Rejection(reason:tooLarge)}
        return file
    }
    static let tooLarge="This file is larger than the 16 MiB import limit."
    /// The file's bytes, read from the one file opened (never a pipe or device, which could block or never end) and
    /// at most one byte past the import limit, so a file that grew or was replaced after its size was checked is refused unloaded.
    @Sendable static func bounded(_ url:URL)throws -> Data {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_CLOEXEC);guard descriptor>=0 else{throw Rejection(reason:unreadable)}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);var status=stat();guard fstat(descriptor,&status)==0,status.st_mode & S_IFMT == S_IFREG else{throw Rejection(reason:"Drop a PGN or FEN file.")}
        var data=Data();while data.count<=ReviewPolicy.maximumBytes,let chunk=try handle.read(upToCount:ReviewPolicy.maximumBytes+1-data.count),!chunk.isEmpty{data.append(chunk)}
        guard data.count<=ReviewPolicy.maximumBytes else{throw Rejection(reason:tooLarge)};return data
    }
}
final class BoardView:NSView {
    static let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    var selected:String? {didSet{if selected != oldValue{breathStart=ProcessInfo.processInfo.systemUptime;updateBreathing()}}}
    /// False when a click on a destination cannot play now (opponent’s piece, opponent’s turn, imagined board).
    var destinationsPlayable=true
    /// Move puzzles show no destinations; a drop there is graded wherever it lands.
    var dropsAnywhere=false
    /// A move animation belongs to one transition, the board before the move and the exact board it lands on, and moves
    /// forward only: once the landing board is shown, any other board (the board before the move too, as an undo shows)
    /// cancels it, and so does any board but the landing one while it is awaited. A hypothetical board, a replacement game
    /// or another activity never keeps it, even one with a same-coloured piece on the destination.
    /// What the board is showing, apart from its pieces (see GameWindow's presentations). A move animation belongs to the
    /// source it started in: any change of source ends it, even to a board with identical pieces.
    var displaySource="" {didSet{if displaySource != oldValue{cancelAnimation()}}}
    var position:Position=[:] {didSet{if position != oldValue,let current=transition{if let next=current.advanced(to:position){transition=next}else{cancelAnimation()}}}}
    var destinations:[String]=[],attacked:[String]=[],highlights:[Highlight]=[],counts:[String]=[],explicitMotion:PieceMotion?,theme="wood",focus="e2"
    var arrows:[[String]]=[] {didSet{if arrows != oldValue{arrowElapsed=0;arrowStart=ProcessInfo.processInfo.systemUptime;updateBreathing()}}}
    var primaryMoveArrow:[String]? {arrows.first{$0.count==2 && ChessRules.validSquare($0[0]) && ChessRules.validSquare($0[1]) && $0[0] != $0[1]}}
    var relationshipConnectors:[RelationshipConnector]=[]
    var relationshipMode:RelationshipMode? {didSet{if relationshipMode != oldValue{updateBreathing()}}}
    var inspectRelationship:((RelationshipMode)->Void)?,dismissRelationships:(()->Bool)?
    // Preference injection is available only in isolated silent automation.
    var automationReduceMotion:Bool?
    var automationIncreaseContrast:Bool?
    var shouldReduceMotion:Bool {NativePolicy.silent ? automationReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion:NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    var shouldIncreaseContrast:Bool {NativePolicy.silent ? automationIncreaseContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast:NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast}
    var reviewKey:((UInt16)->Bool)?,dropReview:((Data)->Void)?,dropRejected:((String)->Void)?
    /// The application's reader replaces this one, so a drop and a Finder open supersede each other.
    var reviewFiles=ReviewFileReader()
    var keyboardFocusVisible=false
    private var showsKeyboardFocus:Bool {keyboardFocusVisible && window?.isKeyWindow == true && window?.firstResponder === self}
    var activate:((String)->Void)?,clearSelection:(()->Void)?,onLayout:(()->Void)?
    /// Whether a press on this square may drag its piece; elsewhere a press is only a click.
    var canDrag:((String)->Bool)?
    /// A dragged piece dropped on a square it cannot reach (it snaps back): the host may explain why.
    var refusedDrop:((String,String)->Void)?
    // A press that never becomes a drag is a click on the square it started on, however far the pointer drifts,
    // even across a square edge; only a release off the board cancels it. Dragging a piece selects it as the drag
    // starts and, on release over another square, activates that square, so drops reuse the click rules for
    // moves, promotion and lessons.
    private static let dragThreshold:CGFloat=4
    private var press:(square:String,origin:NSPoint)?,drag:(from:String,point:NSPoint)?,droppedMove:(from:String,to:String)?
    var dragging:Bool {drag != nil}
    /// A pawn moving diagonally always captures, even onto the empty square of an en passant capture.
    func captures(on square:String)->Bool {if position[square] != nil{return true};guard let from=selected,position[from]?.last=="p" else{return false};return from.first != square.first}
    func isDropped(_ m:MoveRecord)->Bool {droppedMove.map{$0.from==m.from && $0.to==m.to} ?? false}
    override func layout(){super.layout();onLayout?()}
    private var moves:[(piece:String,from:String,to:String)]=[],captured:[String:String]=[:],animationStart:TimeInterval=0,animationDuration=0.0,timer:Timer?
    /// The identity of the running animation: the boards on either side of the move it draws, and how far the displayed
    /// board has followed it. The move may be applied after `animate`, so the animation can start over the board before
    /// it (awaiting the landing board) or over the landing board itself (landed).
    struct MoveTransition:Equatable {let before:Position,landing:Position;let phase:Phase
        enum Phase:Equatable {case awaitingLanding,landed}
        /// The transition starting over `position`, or nil when that board is neither side of the move.
        static func starting(before:Position,landing:Position,over position:Position)->MoveTransition? {
            if position==landing{return MoveTransition(before:before,landing:landing,phase:.landed)}
            if position==before{return MoveTransition(before:before,landing:landing,phase:.awaitingLanding)}
            return nil
        }
        /// The transition once `position` replaces the displayed board, or nil when that board ends it: only the landing
        /// board, while it is still awaited, continues it.
        func advanced(to position:Position)->MoveTransition? {phase == .awaitingLanding && position==landing ? MoveTransition(before:before,landing:landing,phase:.landed):nil}
    }
    private(set) var transition:MoveTransition?
    private lazy var squares=ChessRules.squares.map{SquareAccessibility(board:self,square:$0)}
    override var acceptsFirstResponder:Bool {true}
    override var mouseDownCanMoveWindow:Bool {false}
    /// The click that brings the window forward also plays: the second click of a move is often that click.
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    /// Draggable pieces show an open hand and a piece being dragged a closed hand, so dragging is discoverable.
    func cursor(at point:NSPoint)->NSCursor {if drag != nil{return .closedHand};guard let sq=square(at:point),position[sq] != nil,canDrag?(sq)==true else{return .arrow};return .openHand}
    private var cursorArea:NSTrackingArea?
    override func updateTrackingAreas(){super.updateTrackingAreas();if let cursorArea{removeTrackingArea(cursorArea)};let area=NSTrackingArea(rect:.zero,options:[.mouseMoved,.cursorUpdate,.activeInKeyWindow,.inVisibleRect],owner:self);addTrackingArea(area);cursorArea=area}
    override func cursorUpdate(with e:NSEvent){cursor(at:convert(e.locationInWindow,from:nil)).set()}
    override func mouseMoved(with e:NSEvent){cursor(at:convert(e.locationInWindow,from:nil)).set()}
    override func accessibilityRole()->NSAccessibility.Role? {.group}
    override func accessibilityLabel()->String? {"Chessboard"}
    /// In a review's original game the plain arrow keys step through moves; Option with the arrow keys explores squares.
    var reviewNavigation=false
    override func accessibilityHelp()->String? {reviewNavigation ? "Left and Right arrows step through the game. Hold Option with the arrow keys to explore squares, then press Return to choose a piece or destination. Escape clears your selection.":"Use arrow keys to explore squares and Space or Return to choose a piece or destination. Escape clears your selection."}
    override func isAccessibilityElement()->Bool {true}
    override func accessibilityChildren()->[Any]? {squares}
    override var accessibilityFocusedUIElement:Any? {squares.first{$0.square==focus}}
    override func accessibilityHitTest(_ point:NSPoint)->Any? {guard let window=window else{return self};let local=convert(window.convertPoint(fromScreen:point),from:nil);guard let sq=square(at:local) else{return self};return squares.first{$0.square==sq}}
    var boardRect:NSRect {let side=max(0,min(bounds.width,bounds.height)-Metrics.boardMargin*2);return NSRect(x:(bounds.width-side)/2,y:(bounds.height-side)/2,width:side,height:side)}
    /// Black at the bottom: the learner's own side is always nearest them. Every square position, coordinate
    /// label and arrow-key direction follows it.
    var blackAtBottom=false {didSet{if blackAtBottom != oldValue{needsDisplay=true;onLayout?()}}}
    func squareRect(_ sq:String)->NSRect {guard ChessRules.validSquare(sq) else{return .zero};let r=boardRect,s=r.width/8,file=Int(sq.utf8.first!-97),rank=Int(sq.suffix(1))!-1,column=blackAtBottom ? 7-file:file,row=blackAtBottom ? 7-rank:rank;return NSRect(x:r.minX+CGFloat(column)*s,y:r.minY+CGFloat(row)*s,width:s,height:s)}
    func square(at p:NSPoint)->String? {let r=boardRect;guard r.contains(p),r.width>0 else{return nil};let column=min(7,Int((p.x-r.minX)/(r.width/8))),row=min(7,Int((p.y-r.minY)/(r.height/8)));return String(UnicodeScalar(97+(blackAtBottom ? 7-column:column))!)+String((blackAtBottom ? 7-row:row)+1)}
    private var overlayTimer:Timer?,breathStart=ProcessInfo.processInfo.systemUptime
    var moveAnimationActive:Bool {timer != nil}
    var breathing:Bool {overlayTimer != nil && selected != nil}
    var animatingArrow:Bool {overlayTimer != nil && primaryMoveArrow != nil && relationshipMode==nil}
    private var arrowStart=ProcessInfo.processInfo.systemUptime,arrowElapsed:TimeInterval=0
    override init(frame:NSRect){super.init(frame:frame);registerForDraggedTypes([.fileURL,.string])
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]{NotificationCenter.default.addObserver(self,selector:#selector(windowActivityChanged(_:)),name:name,object:nil)}
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(displayOptionsChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    deinit {overlayTimer?.invalidate();timer?.invalidate();NotificationCenter.default.removeObserver(self);NSWorkspace.shared.notificationCenter.removeObserver(self)}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateBreathing()}
    override var isHidden:Bool {didSet{updateBreathing()}}
    override func becomeFirstResponder()->Bool {let result=super.becomeFirstResponder();if NSApp.currentEvent?.type == .keyDown{keyboardFocusVisible=true};needsDisplay=true;return result}
    override func resignFirstResponder()->Bool {let result=super.resignFirstResponder();needsDisplay=true;return result}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    @objc private func windowActivityChanged(_ notification:Notification){guard notification.object as? NSWindow === window else{return};updateBreathing(closing:notification.name == NSWindow.willCloseNotification)}
    @objc private func displayOptionsChanged(){if shouldReduceMotion{cancelAnimation()};updateBreathing()}
    func updateBreathing(closing:Bool=false){
        let active = !closing && (selected != nil || (primaryMoveArrow != nil && relationshipMode==nil)) && window?.isKeyWindow == true && window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor && !shouldReduceMotion
        if !active {overlayTimer?.invalidate();overlayTimer=nil}
        else if overlayTimer==nil {breathStart=ProcessInfo.processInfo.systemUptime;arrowStart=breathStart-arrowElapsed;let timer=Timer(timeInterval:BoardOverlay.refreshInterval,repeats:true){[weak self] _ in guard let self=self else{return};if self.animatingArrow{self.arrowElapsed=ProcessInfo.processInfo.systemUptime-self.arrowStart};self.needsDisplay=true};overlayTimer=timer;RunLoop.main.add(timer,forMode:.common)}
        needsDisplay=true
    }
    private func halo(_ rect:NSRect,selected:Bool,color:NSColor?=nil){
        let side=rect.width,pulse=selected && breathing ? BoardOverlay.breath(at:ProcessInfo.processInfo.systemUptime-breathStart):0.5
        let inset=side*(BoardOverlay.haloInset-BoardOverlay.haloExpansion*pulse),path=NSBezierPath(ovalIn:rect.insetBy(dx:inset,dy:inset))
        let color=color ?? (BoardPalette.theme(theme).ink)
        if selected{color.withAlphaComponent(BoardOverlay.haloFillLow+(BoardOverlay.haloFillHigh-BoardOverlay.haloFillLow)*pulse).setFill();path.fill()}
        color.withAlphaComponent(shouldIncreaseContrast || !selected ? 1:BoardOverlay.haloStrokeLow+(BoardOverlay.haloStrokeHigh-BoardOverlay.haloStrokeLow)*pulse).setStroke()
        path.lineWidth=side*(selected ? BoardOverlay.haloWidth:BoardOverlay.focusWidth);path.stroke()
    }
    required init?(coder:NSCoder){fatalError()}
    override func mouseDown(with e:NSEvent){keyboardFocusVisible=false;window?.makeFirstResponder(self);drag=nil;let point=convert(e.locationInWindow,from:nil);press=square(at:point).map{($0,point)};if let sq=press?.square{focus=sq};needsDisplay=true}
    override func mouseDragged(with e:NSEvent){
        guard let press=press else{return};let point=convert(e.locationInWindow,from:nil)
        if drag==nil {
            // A press on the selected piece’s capture target is a click on that target, never a drag of the captured piece.
            guard hypot(point.x-press.origin.x,point.y-press.origin.y)>=Self.dragThreshold,position[press.square] != nil,canDrag?(press.square)==true,selected==press.square || !destinations.contains(press.square) else{return}
            if selected != press.square{activate?(press.square)}
            guard selected==press.square,position[press.square] != nil else{self.press=nil;return}
        }
        if drag==nil{NSCursor.closedHand.set()};drag=(press.square,point);needsDisplay=true
    }
    override func mouseUp(with e:NSEvent){
        let point=convert(e.locationInWindow,from:nil)
        defer{press=nil;drag=nil;cursor(at:point).set();needsDisplay=true}
        guard let press=press else{return};let target=square(at:point)
        guard let drag=drag else{if target != nil{activate?(press.square)};return}
        // A drop anywhere but a playable destination snaps back and keeps the piece selected.
        guard let target=target,target != drag.from,selected==drag.from,dropsAnywhere || destinationsPlayable && destinations.contains(target) else{if let target,target != drag.from{refusedDrop?(drag.from,target)};return}
        focus=target;droppedMove=(drag.from,target);activate?(target);droppedMove=nil
    }
    override func keyDown(with e:NSEvent){if e.modifierFlags.intersection([.command,.control,.option]).isEmpty,reviewKey?(e.keyCode)==true{return};let modifiers=e.modifierFlags.intersection([.command,.control,.option]);if !modifiers.isEmpty && !(modifiers == .option && (123...126).contains(e.keyCode)){super.keyDown(with:e);return};if let char=e.charactersIgnoringModifiers?.lowercased(),char=="p" || char=="a"{inspectRelationship?(char=="p" ? .protected:.attacked);return};keyboardFocusVisible=true;if e.keyCode==36 || e.keyCode==49{activate?(focus);return};if e.keyCode==53{if press != nil || drag != nil{press=nil;drag=nil;if let window{cursor(at:convert(window.mouseLocationOutsideOfEventStream,from:nil)).set()}};if dismissRelationships?()==true{needsDisplay=true;return};selected=nil;destinations=[];clearSelection?();needsDisplay=true;return};var f=Int(focus.utf8.first!-97),r=Int(focus.suffix(1))!-1;let step=blackAtBottom ? -1:1;switch e.keyCode{case 123:f-=step;case 124:f+=step;case 125:r-=step;case 126:r+=step;default:super.keyDown(with:e);return};focus=String(UnicodeScalar(97+max(0,min(7,f)))!)+String(max(0,min(7,r))+1);needsDisplay=true;if let square=squares.first(where:{$0.square==focus}){NSAccessibility.post(element:square,notification:.focusedUIElementChanged)}}
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {.copy}
    /// A dropped file is checked and read off the main thread (`ReviewDrop.validated`); a refusal is reported with its reason.
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {let pasteboard=sender.draggingPasteboard;if let url=NSURL(from:pasteboard) as URL?{guard url.isFileURL else{return false}
            reviewFiles.load(url,prepare:ReviewDrop.validated,deliver:{[weak self] in self?.dropReview?($0)},rejected:{[weak self] error in self?.dropRejected?((error as? ReviewDrop.Rejection)?.reason ?? ReviewDrop.unreadable)});return true};if let text=pasteboard.string(forType:.string),text.utf8.count<=ReviewPolicy.maximumBytes{dropReview?(Data(text.utf8));return true};return false}
    func cancelAnimation(){timer?.invalidate();timer=nil;moves=[];captured=[:];transition=nil;needsDisplay=true}
    /// Animates `m` onto `landing`, the exact board the move produces (by default the placement of `m.after`). The board
    /// before the move is derived from `landing` by undoing the drawn moves and captures, so the animation runs only
    /// while the displayed board follows that transition (`MoveTransition`): a move whose landing board is unknown, or
    /// that does not belong to the board now shown, is not animated at all.
    func animate(_ m:MoveRecord,landing:Position?=nil,duration:Double){cancelAnimation();guard duration>0,!shouldReduceMotion,!isDropped(m),let landing=landing ?? TrainingMaterial.board(fen:m.after) else{return}
        var drawn=[(piece:m.color+m.piece,from:m.from,to:m.to)],taken:[String:String]=[:]
        if m.flags.contains("k")||m.flags.contains("q"){let rank=String(m.from.suffix(1));drawn.append((m.color+"r",(m.flags.contains("k") ? "h":"a")+rank,(m.flags.contains("k") ? "f":"d")+rank))}
        if let p=m.captured{taken[m.flags.contains("e") ? String(m.to.prefix(1))+String(m.from.suffix(1)):m.to]=(m.color=="w" ? "b":"w")+p}
        var before=landing;for move in drawn{before[move.to]=nil};for move in drawn{before[move.from]=move.piece};for (square,piece) in taken{before[square]=piece}
        guard let transition=MoveTransition.starting(before:before,landing:landing,over:position) else{return}
        self.transition=transition;moves=drawn;captured=taken
        animationStart=ProcessInfo.processInfo.systemUptime;animationDuration=duration;let timer=Timer(timeInterval:Metrics.frameInterval,repeats:true){[weak self] _ in guard let self=self else{return};self.needsDisplay=true;if self.animationProgress>=1{self.cancelAnimation()}};self.timer=timer;RunLoop.main.add(timer,forMode:.common)}
    /// Monotonic, so a clock change never stalls or skips a move.
    private var animationProgress:Double {animationDuration>0 ? min(1,max(0,(ProcessInfo.processInfo.systemUptime-animationStart)/animationDuration)):1}
    private func glyph(_ piece:String,rect:NSRect,alpha:CGFloat=1){let symbols=["k":"♚","q":"♛","r":"♜","b":"♝","n":"♞","p":"♟"],white=piece.first=="w",size=rect.width*0.8
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Arial Unicode MS",size:size) ?? NSFont.systemFont(ofSize:size),.foregroundColor:(white ? BoardPalette.lightPiece:BoardPalette.darkPiece).withAlphaComponent(alpha),.strokeColor:BoardPalette.pieceOutline.withAlphaComponent(alpha),.strokeWidth:white ? BoardOverlay.pieceOutlineWidth:0]
        let value=symbols[String(piece.suffix(1)),default:"♟"] as NSString,s=value.size(withAttributes:attrs);value.draw(at:NSPoint(x:rect.midX-s.width/2,y:rect.midY-s.height/2),withAttributes:attrs)
    }
    /// Layers draw bottom to top: squares and their marks, relationships, arrows, pieces, then coordinates.
    override func draw(_ dirty:NSRect){let s=boardRect.width/8;guard s>0 else{return}
        let palette=BoardPalette.theme(theme)
        drawSquares(palette,side:s);drawRelationships(palette,side:s);drawArrows(palette,side:s);drawPieces(side:s);drawLabels(palette,side:s)
    }
    private func drawSquares(_ palette:BoardPalette,side s:CGFloat){
        for sq in ChessRules.squares {let rect=squareRect(sq),parity=(Int(sq.utf8.first!-97)+Int(sq.suffix(1))!-1)%2; (parity==0 ? palette.darkSquare:palette.lightSquare).setFill();rect.fill()
            if sq==selected{let danger=highlights.contains{$0.sq==sq && ($0.kind=="check" || $0.kind=="no")};halo(rect,selected:true,color:danger ? palette.danger:nil)}
            if let h=highlights.last(where:{$0.sq==sq}),sq != selected {
                let color=h.kind=="check" || h.kind=="no" ? palette.danger:palette.ink
                let path=NSBezierPath(ovalIn:rect.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset))
                color.withAlphaComponent(BoardOverlay.annotationFill).setFill();path.fill()
                // The last move is a quiet fill, but Increase Contrast outlines it too so it stays findable.
                if h.kind != "last" || shouldIncreaseContrast,!showsKeyboardFocus || focus != sq{color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.haloStrokeHigh).setStroke();path.lineWidth=s*BoardOverlay.haloWidth;path.stroke()}
            }
            if attacked.contains(sq){palette.ink.withAlphaComponent(BoardOverlay.coverageOpacity).setStroke();let p=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.36,dy:s*0.36));p.lineWidth=max(1,s*0.025);p.stroke()}
            // Playable moves are solid; possibilities that a click cannot play are hollow or dashed.
            if destinations.contains(sq),position[sq]==nil{if destinationsPlayable{palette.ink.withAlphaComponent(BoardOverlay.destinationOpacity).setFill();NSBezierPath(ovalIn:rect.insetBy(dx:s*0.44,dy:s*0.44)).fill()}else{palette.ink.withAlphaComponent(BoardOverlay.destinationOpacity).setStroke();let dot=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.42,dy:s*0.42));dot.lineWidth=max(1,s*0.02);dot.stroke()}}
            if destinations.contains(sq),position[sq] != nil {palette.ink.setStroke();let ring=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.07,dy:s*0.07));ring.lineWidth=max(2,s*0.045);if !destinationsPlayable{let dash=BoardOverlay.relationshipDash.map{$0*s};ring.setLineDash(dash,count:dash.count,phase:0)};ring.stroke()}
            if showsKeyboardFocus,focus==sq,sq != selected {halo(rect,selected:false)}
        }
    }
    private func drawRelationships(_ palette:BoardPalette,side s:CGFloat){
        if let mode=relationshipMode {
            let color=mode == .protected ? palette.protection:palette.danger
            for connection in relationshipConnectors {
                let a=squareRect(connection.source),b=squareRect(connection.target),dx=b.midX-a.midX,dy=b.midY-a.midY,length=hypot(dx,dy)
                guard length>0 else{continue};let ux=dx/length,uy=dy/length,inset=s*BoardOverlay.relationshipInset,bend=min(length,s*2)*BoardOverlay.relationshipCurve
                let start=NSPoint(x:a.midX+ux*inset,y:a.midY+uy*inset),end=NSPoint(x:b.midX-ux*inset,y:b.midY-uy*inset)
                let curve=NSBezierPath();curve.move(to:start);curve.curve(to:end,controlPoint1:NSPoint(x:start.x+(end.x-start.x)/3-uy*bend,y:start.y+(end.y-start.y)/3+ux*bend),controlPoint2:NSPoint(x:start.x+2*(end.x-start.x)/3-uy*bend,y:start.y+2*(end.y-start.y)/3+ux*bend));curve.lineCapStyle = .round;curve.lineWidth=s*BoardOverlay.relationshipWidth
                if connection.limited{let dash=BoardOverlay.relationshipDash.map{$0*s};curve.setLineDash(dash,count:dash.count,phase:0)}
                color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.relationshipOpacity).setStroke();curve.stroke()
                let halo=NSBezierPath(ovalIn:a.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset));color.withAlphaComponent(BoardOverlay.annotationFill).setFill();halo.fill();halo.lineWidth=s*BoardOverlay.haloWidth;halo.stroke()
            }
        }
    }
    private func drawArrows(_ palette:BoardPalette,side s:CGFloat){
        var seen=Set<String>()
        let joints=BoardArrow.joints(arrows,position:position)
        for arrow in arrows where arrow.count==2 {
            guard seen.insert(arrow.joined(separator:":")).inserted,let geometry=BoardArrow(from:arrow[0],to:arrow[1],board:self,through:joints.contains(arrow[1])) else{continue}
            let dash=BoardOverlay.arrowDash.map{$0*s}
            let phase=arrow==primaryMoveArrow ? BoardOverlay.arrowDashPhase(at:arrowElapsed,side:s):0
            geometry.shaft.setLineDash(dash,count:dash.count,phase:phase)
            let color=palette.ink.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.arrowOpacity)
            color.setStroke();geometry.shaft.stroke();color.setFill();geometry.head.fill()
        }
    }
    private func drawPieces(side s:CGFloat){
        let progress=animationProgress,ease=progress*progress*(3-2*progress)
        // Routes sit beneath the pieces, preserving both silhouettes and endpoint identity.
        for sq in ChessRules.squares {let rect=squareRect(sq)
            if let piece=position[sq],!moves.contains(where:{$0.to==sq}),explicitMotion?.from != sq {glyph(piece,rect:rect,alpha:drag?.from==sq ? BoardOverlay.dragOriginOpacity:1)}
            if let piece=captured[sq],progress<1{glyph(piece,rect:rect,alpha:CGFloat(1-progress))}
        }
        for m in moves {let a=squareRect(m.from),b=squareRect(m.to);glyph(m.piece,rect:NSRect(x:a.minX+(b.minX-a.minX)*ease,y:a.minY+(b.minY-a.minY)*ease,width:s,height:s))}
        if let m=explicitMotion,let piece=position[m.from]{let a=squareRect(m.from),b=squareRect(m.to),t=m.t*m.t*(3-2*m.t);glyph(piece,rect:NSRect(x:a.minX+(b.minX-a.minX)*t,y:a.minY+(b.minY-a.minY)*t,width:s,height:s))}
        if let d=drag,let piece=position[d.from]{glyph(piece,rect:NSRect(x:d.point.x-s/2,y:d.point.y-s/2,width:s,height:s))}
    }
    private func drawLabels(_ palette:BoardPalette,side s:CGFloat){let r=boardRect
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:Metrics.coordinateSize,weight:.medium),.foregroundColor:NativeColors.secondaryText]
        for i in 0..<8 {let file=String(UnicodeScalar(65+(blackAtBottom ? 7-i:i))!) as NSString,rank=String(blackAtBottom ? 8-i:i+1) as NSString;file.draw(at:NSPoint(x:r.minX+(CGFloat(i)+0.5)*s-4,y:r.minY-Metrics.padding),withAttributes:attrs);file.draw(at:NSPoint(x:r.minX+(CGFloat(i)+0.5)*s-4,y:r.maxY+4),withAttributes:attrs);rank.draw(at:NSPoint(x:r.minX-Metrics.padding,y:r.minY+(CGFloat(i)+0.5)*s-6),withAttributes:attrs);rank.draw(at:NSPoint(x:r.maxX+6,y:r.minY+(CGFloat(i)+0.5)*s-6),withAttributes:attrs)}
        for (i,sq) in counts.enumerated(){let rect=squareRect(sq),label=String(i+1) as NSString;label.draw(at:NSPoint(x:rect.minX+s*0.08,y:rect.maxY-s*0.25),withAttributes:[.font:NSFont.systemFont(ofSize:s*0.16,weight:.bold),.foregroundColor:palette.ink])}
    }
}
