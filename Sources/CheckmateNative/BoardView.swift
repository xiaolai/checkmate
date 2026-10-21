import AppKit
import CheckmateCore
final class SquareAccessibility:NSAccessibilityElement,NSAccessibilityElementProtocol {
    weak var board:BoardView?;let square:String
    init(board:BoardView,square:String){self.board=board;self.square=square;super.init();setAccessibilityParent(board)}
    override func accessibilityRole()->NSAccessibility.Role? {.button}
    /// A rotor result names its square element, which needs a stable identifier.
    override func accessibilityIdentifier()->String {"board-square-"+square}
    override func accessibilityRowIndexRange()->NSRange {NSRange(location:board?.gridRow(square) ?? 0,length:1)}
    override func accessibilityColumnIndexRange()->NSRange {NSRange(location:board?.gridColumn(square) ?? 0,length:1)}
    override func accessibilityLabel()->String? {label(pressure:false)}
    /// `pressure` states the attack and defence counts even on a square the board does not mark as covered (the Attacked Pieces rotor).
    func label(pressure:Bool)->String {guard let board=board else{return square};var parts=[square];if let p=board.position[square]{parts.append(PieceName.listed(String(p.prefix(1)),String(p.suffix(1))))};if board.selected==square{parts.append(String(localized:"selected",bundle:.checkmate,comment:"A board square's state, in its spoken description"))};if board.destinations.contains(square){parts.append(!board.destinationsPlayable ? String(localized:"possible destination, not playable now",bundle:.checkmate):board.captures(on:square) ? String(localized:"capture destination",bundle:.checkmate):String(localized:"move destination",bundle:.checkmate))};if pressure || board.attacked.contains(square){parts.append(board.pressure(on:square))};for h in board.highlights where h.sq==square{parts.append(h.kind=="check" ? String(localized:"in check",bundle:.checkmate,comment:"A king's square, in its spoken description"):h.kind=="no" ? String(localized:"unavailable lesson destination",bundle:.checkmate):h.kind=="last" ? String(localized:"part of the last move",bundle:.checkmate):h.kind=="target" ? String(localized:"target square",bundle:.checkmate):h.kind=="answer" ? String(localized:"in your answer",bundle:.checkmate):h.kind=="hint" ? String(localized:"shown by a hint",bundle:.checkmate):String(localized:"highlighted by the coach",bundle:.checkmate))};for a in board.arrows where a.count==2{if a[0]==square{parts.append(String(localized:"suggested move to \(a[1])",bundle:.checkmate))};if a[1]==square{parts.append(String(localized:"suggested move from \(a[0])",bundle:.checkmate))}};for g in board.guards where g.count==2{if g[0]==square{parts.append(String(localized:"guards \(g[1])",bundle:.checkmate,comment:"A square's description: the square it guards"))};if g[1]==square{parts.append(String(localized:"guarded by \(g[0])",bundle:.checkmate,comment:"A square's description: the square guarding it"))}};for connection in board.relationshipConnectors {let description=connection.limited ? String(localized:"restricted or conditional",bundle:.checkmate):"";if connection.source==square{parts.append(board.relationshipMode == .protected ? String(localized:"protects \(connection.target) \(description)",bundle:.checkmate,comment:"A square's description: the piece it protects, then whether that is restricted"):String(localized:"attacks \(connection.target) \(description)",bundle:.checkmate,comment:"A square's description: the piece it attacks, then whether that is restricted"))};if connection.target==square{parts.append(board.relationshipMode == .protected ? String(localized:"protected by \(connection.source) \(description)",bundle:.checkmate,comment:"A square's description: the piece protecting it, then whether that is restricted"):String(localized:"attacked by \(connection.source) \(description)",bundle:.checkmate,comment:"A square's description: the piece attacking it, then whether that is restricted"))}};return parts.joined(separator:", ")}
    override func accessibilityFrame()->NSRect {guard let b=board,let w=b.window else{return .zero};return w.convertToScreen(b.convert(b.squareRect(square),to:nil))}
    override func isAccessibilityFocused()->Bool {board?.focus==square && board?.window?.firstResponder === board}
    override func setAccessibilityFocused(_ value:Bool){if value{board?.focus=square;board?.window?.makeFirstResponder(board);board?.keyboardFocusVisible=true;board?.needsDisplay=true;NSAccessibility.post(element:self,notification:.focusedUIElementChanged)}}
    override func accessibilityPerformPress()->Bool {guard let board=board else{return false};board.focus=square;board.window?.makeFirstResponder(board);board.keyboardFocusVisible=true;board.activate?(square);board.needsDisplay=true;return true}
}
/// A file or rank header of the board grid, in the order the board is drawn: "File a" or "Rank 8".
final class BoardHeaderAccessibility:NSAccessibilityElement {
    weak var board:BoardView?;let column:Bool,index:Int
    init(board:BoardView,column:Bool,index:Int){self.board=board;self.column=column;self.index=index;super.init();setAccessibilityParent(board)}
    override func accessibilityRole()->NSAccessibility.Role? {.staticText}
    override func accessibilityLabel()->String? {guard let board=board else{return nil};return column ? String(localized:"File \(board.gridFile(index))",bundle:.checkmate,comment:"A board column and its letter"):String(localized:"Rank \(board.gridRank(index))",bundle:.checkmate,comment:"A board row and its number")}
    override func accessibilityFrame()->NSRect {guard let b=board,let w=b.window else{return .zero};let r=b.boardRect,s=r.width/8,m=Metrics.boardMargin;return w.convertToScreen(b.convert(column ? NSRect(x:r.minX+CGFloat(index)*s,y:r.minY-m,width:s,height:m):NSRect(x:r.minX-m,y:r.maxY-CGFloat(index+1)*s,width:m,height:s),to:nil))}
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
    static let unreadable=String(localized:"This file could not be read.",bundle:.checkmate)
    @Sendable static func validated(_ url:URL)throws -> URL {
        let file=url.resolvingSymlinksInPath()
        let values:URLResourceValues;do{values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey])}catch{throw Rejection(reason:unreadable)}
        guard values.isRegularFile==true,let size=values.fileSize else{throw Rejection(reason:String(localized:"Drop a PGN or FEN file.",bundle:.checkmate))}
        if let status=values.ubiquitousItemDownloadingStatus,status != .current{throw Rejection(reason:String(localized:"This file is still in iCloud. Download it in Finder, then drop it again.",bundle:.checkmate))}
        guard size<=ReviewPolicy.maximumBytes else{throw Rejection(reason:tooLarge)}
        return file
    }
    static let tooLarge=String(localized:"This file is larger than the 16 MiB import limit.",bundle:.checkmate)
    /// The record files the board takes; the extension is matched without case.
    static let recordExtensions:Set<String>=["pgn","fen"]
    /// Whether a drag carries one game record: a single .pgn or .fen file, or, with no file, text that reads as one.
    static func accepts(_ pasteboard:NSPasteboard)->Bool {
        if let files=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!files.isEmpty{return files.count==1 && recordExtensions.contains(files[0].pathExtension.lowercased())}
        return pasteboard.string(forType:.string).map(looksLikeRecord) ?? false
    }
    /// Whether text reads as a game record: a FEN position, PGN tag pairs, or movetext from move one. It is only a first
    /// look; the importer still decides what the text holds.
    static func looksLikeRecord(_ text:String)->Bool {
        guard text.utf8.count<=ReviewPolicy.maximumBytes else{return false}
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines),fields=trimmed.split(whereSeparator:{$0.isWhitespace})
        if fields.count==4 || fields.count==6,fields[0].filter({$0=="/"}).count==7,fields[0].allSatisfy({"pnbrqkPNBRQK12345678/".contains($0)}),fields[1]=="w" || fields[1]=="b"{return true}
        return trimmed.range(of:#"^\[[A-Za-z0-9_]+\s+""#,options:.regularExpression) != nil || trimmed.range(of:#"^1\.\s*(\.\.\s*)?([KQRBN][a-h1-8]?x?[a-h][1-8]|[a-h](x[a-h])?[1-8]|O-O)"#,options:.regularExpression) != nil
    }
    /// The file's bytes, read from the one file opened (never a pipe or device, which could block or never end) and
    /// at most one byte past the import limit, so a file that grew or was replaced after its size was checked is refused unloaded.
    @Sendable static func bounded(_ url:URL)throws -> Data {
        let descriptor=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_CLOEXEC);guard descriptor>=0 else{throw Rejection(reason:unreadable)}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);var status=stat();guard fstat(descriptor,&status)==0,status.st_mode & S_IFMT == S_IFREG else{throw Rejection(reason:String(localized:"Drop a PGN or FEN file.",bundle:.checkmate))}
        var data=Data();while data.count<=ReviewPolicy.maximumBytes,let chunk=try handle.read(upToCount:ReviewPolicy.maximumBytes+1-data.count),!chunk.isEmpty{data.append(chunk)}
        guard data.count<=ReviewPolicy.maximumBytes else{throw Rejection(reason:tooLarge)};return data
    }
}
final class BoardView:NSView,NSAccessibilityCustomRotorItemSearchDelegate {
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
    var destinations:[String]=[],attacked:[String]=[],highlights:[Highlight]=[],counts:[String]=[],explicitMotion:PieceMotion?,theme="wood"
    var focus="e2" {didSet{if focus != oldValue{noteFocusRingMaskChanged()}}}
    var arrows:[[String]]=[] {didSet{if arrows != oldValue{arrowElapsed=0;arrowStart=ProcessInfo.processInfo.systemUptime;updateBreathing()}}}
    var primaryMoveArrow:[String]? {arrows.first{$0.count==2 && ChessRules.validSquare($0[0]) && ChessRules.validSquare($0[1]) && $0[0] != $0[1]}}
    /// A lesson's guard lines, [from, to]: drawn like the Inspector's protection connectors, under the arrows.
    var guards:[[String]]=[]
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
    /// Keyboard focus is shown with the system focus ring around the focused square; a pointer user sees none.
    var keyboardFocusVisible=false {didSet{if keyboardFocusVisible != oldValue{noteFocusRingMaskChanged()}}}
    override var focusRingMaskBounds:NSRect {keyboardFocusVisible ? squareRect(focus):.zero}
    override func drawFocusRingMask(){squareRect(focus).fill()}
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
    override func layout(){super.layout();noteFocusRingMaskChanged();onLayout?()}
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
    /// A grid of 64 square buttons, top row first as drawn, with file and rank headers: VoiceOver can read a row or a column.
    override func accessibilityRole()->NSAccessibility.Role? {.grid}
    override func accessibilityLabel()->String? {String(localized:"Chessboard",bundle:.checkmate)}
    override func accessibilityRowCount()->Int {8}
    override func accessibilityColumnCount()->Int {8}
    func gridRow(_ sq:String)->Int {let rank=Int(sq.suffix(1)) ?? 1;return blackAtBottom ? rank-1:8-rank}
    func gridColumn(_ sq:String)->Int {let file=Int(sq.utf8.first ?? 97)-97;return blackAtBottom ? 7-file:file}
    func gridFile(_ column:Int)->String {String(UnicodeScalar(UInt8(97+(blackAtBottom ? 7-column:column))))}
    func gridRank(_ row:Int)->String {String(blackAtBottom ? row+1:8-row)}
    override func accessibilityCell(forColumn column:Int,row:Int)->Any? {guard (0..<8).contains(column),(0..<8).contains(row) else{return nil};let sq=gridFile(column)+gridRank(row);return squares.first{$0.square==sq}}
    private lazy var columnHeaders=(0..<8).map{BoardHeaderAccessibility(board:self,column:true,index:$0)}
    private lazy var rowHeaders=(0..<8).map{BoardHeaderAccessibility(board:self,column:false,index:$0)}
    override func accessibilityColumnHeaderUIElements()->[Any]? {columnHeaders}
    override func accessibilityRowHeaderUIElements()->[Any]? {rowHeaders}
    /// "attacked by N, defended by M" for the side that owns the square: its piece's colour, or on an empty square the
    /// colour of the selected piece. Attackers are the other side's pieces reaching it, defenders the owner's.
    func pressure(on sq:String)->String {
        guard let owner=position[sq]?.first ?? selected.flatMap({position[$0]?.first}) else{let white=TrainingGeometry.attackers(of:sq,color:"w",board:position).count,black=TrainingGeometry.attackers(of:sq,color:"b",board:position).count;return String(localized:"reached by \(white) White and \(black) Black",bundle:.checkmate,comment:"An empty square's description: how many pieces of each side reach it")}
        let other:Character=owner=="w" ? "b":"w";return String(localized:"attacked by \(TrainingGeometry.attackers(of:sq,color:other,board:position).count), defended by \(TrainingGeometry.attackers(of:sq,color:owner,board:position).count)",bundle:.checkmate,comment:"A square's description: how many pieces attack and defend it")
    }
    enum Rotor {case pieces,attacked}
    private lazy var rotors=[NSAccessibilityCustomRotor(label:String(localized:"Pieces",bundle:.checkmate),itemSearchDelegate:self),NSAccessibilityCustomRotor(label:String(localized:"Attacked Pieces",bundle:.checkmate),itemSearchDelegate:self)]
    override func accessibilityCustomRotors()->[NSAccessibilityCustomRotor] {rotors}
    /// The rotor's squares in reading order (top row first, left to right): every piece, or every piece an enemy piece attacks.
    func rotorSquares(_ rotor:Rotor)->[String] {
        let pieces=position.keys.filter{ChessRules.validSquare($0)}.sorted{(gridRow($0),gridColumn($0))<(gridRow($1),gridColumn($1))}
        guard rotor == .attacked else{return pieces}
        return pieces.filter{sq in let other:Character=position[sq]?.first=="w" ? "b":"w";return !TrainingGeometry.attackers(of:sq,color:other,board:position).isEmpty}
    }
    func rotor(_ rotor:NSAccessibilityCustomRotor,resultFor parameters:NSAccessibilityCustomRotor.SearchParameters)->NSAccessibilityCustomRotor.ItemResult? {
        let kind:Rotor=rotor===rotors[1] ? .attacked:.pieces,filter=parameters.filterString.lowercased()
        let candidates=rotorSquares(kind).compactMap{sq in squares.first{$0.square==sq}}.filter{filter.isEmpty || $0.label(pressure:kind == .attacked).lowercased().contains(filter)}
        let forward=parameters.searchDirection == .next
        let target:SquareAccessibility?
        if let current=parameters.currentItem?.targetElement as? SquareAccessibility,let index=candidates.firstIndex(where:{$0===current}){let next=index+(forward ? 1:-1);target=candidates.indices.contains(next) ? candidates[next]:nil}
        else{target=forward ? candidates.first:candidates.last}
        guard let target else{return nil};let result=NSAccessibilityCustomRotor.ItemResult(targetElement:target);result.customLabel=target.label(pressure:kind == .attacked);return result
    }
    /// In a review's original game the plain arrow keys step through moves; Option with the arrow keys explores squares.
    var reviewNavigation=false
    override func accessibilityHelp()->String? {reviewNavigation ? String(localized:"Left and Right arrows step through the game. Hold Option with the arrow keys to explore squares, then press Return to choose a piece or destination. Escape clears your selection.",bundle:.checkmate):String(localized:"Use arrow keys to explore squares and Space or Return to choose a piece or destination. Escape clears your selection.",bundle:.checkmate)}
    override func isAccessibilityElement()->Bool {true}
    /// The 64 squares first, then the sixteen headers.
    override func accessibilityChildren()->[Any]? {squares+columnHeaders+rowHeaders}
    override var accessibilityFocusedUIElement:Any? {squares.first{$0.square==focus}}
    override func accessibilityHitTest(_ point:NSPoint)->Any? {guard let window=window else{return self};let local=convert(window.convertPoint(fromScreen:point),from:nil);guard let sq=square(at:local) else{return self};return squares.first{$0.square==sq}}
    var boardRect:NSRect {let side=max(0,min(bounds.width,bounds.height)-Metrics.boardMargin*2);return NSRect(x:(bounds.width-side)/2,y:(bounds.height-side)/2,width:side,height:side)}
    /// Black at the bottom: the learner's own side is always nearest them. Every square position, coordinate
    /// label and arrow-key direction follows it.
    var blackAtBottom=false {didSet{if blackAtBottom != oldValue{needsDisplay=true;noteFocusRingMaskChanged();onLayout?()}}}
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
    /// The theme in the window's appearance: a dark window gets the dimmed variant.
    var palette:BoardPalette {BoardPalette.theme(theme,dark:effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua)}
    @objc private func windowActivityChanged(_ notification:Notification){guard notification.object as? NSWindow === window else{return};updateBreathing(closing:notification.name == NSWindow.willCloseNotification)}
    @objc private func displayOptionsChanged(){if shouldReduceMotion{cancelAnimation()};updateBreathing()}
    func updateBreathing(closing:Bool=false){
        let active = !closing && (selected != nil || (primaryMoveArrow != nil && relationshipMode==nil)) && window?.isKeyWindow == true && window?.isVisible == true && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor && !shouldReduceMotion
        if !active {overlayTimer?.invalidate();overlayTimer=nil}
        else if overlayTimer==nil {breathStart=ProcessInfo.processInfo.systemUptime;arrowStart=breathStart-arrowElapsed;let timer=Timer(timeInterval:BoardOverlay.refreshInterval,repeats:true){[weak self] _ in guard let self=self else{return};if self.animatingArrow{self.arrowElapsed=ProcessInfo.processInfo.systemUptime-self.arrowStart};self.needsDisplay=true};overlayTimer=timer;RunLoop.main.add(timer,forMode:.common)}
        needsDisplay=true
    }
    /// The selected piece's breathing halo.
    private func halo(_ rect:NSRect,color:NSColor?=nil){
        let side=rect.width,pulse=breathing ? BoardOverlay.breath(at:ProcessInfo.processInfo.systemUptime-breathStart):0.5
        let inset=side*(BoardOverlay.haloInset-BoardOverlay.haloExpansion*pulse),path=NSBezierPath(ovalIn:rect.insetBy(dx:inset,dy:inset))
        let color=color ?? palette.ink
        color.withAlphaComponent(BoardOverlay.haloFillLow+(BoardOverlay.haloFillHigh-BoardOverlay.haloFillLow)*pulse).setFill();path.fill()
        color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.haloStrokeLow+(BoardOverlay.haloStrokeHigh-BoardOverlay.haloStrokeLow)*pulse).setStroke()
        path.lineWidth=side*BoardOverlay.haloWidth;path.stroke()
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
    /// Only a game record is taken (`ReviewDrop.accepts`); anything else shows no copy badge and cannot be dropped.
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {ReviewDrop.accepts(sender.draggingPasteboard) ? .copy:[]}
    /// A dropped file is checked and read off the main thread (`ReviewDrop.validated`); a refusal is reported with its reason.
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {let pasteboard=sender.draggingPasteboard;guard ReviewDrop.accepts(pasteboard) else{return false};if let url=NSURL(from:pasteboard) as URL?{guard url.isFileURL else{return false}
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
    /// Layers draw bottom to top: squares and their marks, guard lines and relationships, arrows, pieces, then coordinates.
    override func draw(_ dirty:NSRect){let s=boardRect.width/8;guard s>0 else{return}
        let palette=self.palette;drawSquares(palette,side:s);drawRelationships(palette,side:s);drawArrows(palette,side:s);drawPieces(side:s);drawLabels(palette,side:s)
    }
    private func drawSquares(_ palette:BoardPalette,side s:CGFloat){
        for sq in ChessRules.squares {let rect=squareRect(sq),parity=(Int(sq.utf8.first!-97)+Int(sq.suffix(1))!-1)%2; (parity==0 ? palette.darkSquare:palette.lightSquare).setFill();rect.fill()
            if sq==selected{let danger=highlights.contains{$0.sq==sq && ($0.kind=="check" || $0.kind=="no")};halo(rect,color:danger ? palette.danger:nil)}
            if let h=highlights.last(where:{$0.sq==sq}),sq != selected,h.kind=="check" {
                // Check (B-15): a saturated glow over the king's square, ringed in a dark red that stands out from it.
                let glow=NSGradient(colors:[BoardPalette.check.withAlphaComponent(BoardOverlay.checkGlow),BoardPalette.check.withAlphaComponent(BoardOverlay.checkGlow*0.6)]);glow?.draw(in:rect,relativeCenterPosition:.zero)
                let ring=NSBezierPath(ovalIn:rect.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset));BoardPalette.checkRing.setStroke();ring.lineWidth=s*BoardOverlay.haloWidth*1.5;ring.stroke()
            } else if let h=highlights.last(where:{$0.sq==sq}),sq != selected,h.kind=="last" {
                // The last move (B-15): a hue tint over both squares; Increase Contrast outlines it too so it stays findable.
                BoardPalette.lastMove.withAlphaComponent(BoardOverlay.lastMoveTint).setFill();rect.fill()
                if shouldIncreaseContrast{palette.ink.setStroke();let outline=NSBezierPath(rect:rect.insetBy(dx:s*BoardOverlay.haloWidth,dy:s*BoardOverlay.haloWidth));outline.lineWidth=s*BoardOverlay.haloWidth;outline.stroke()}
            } else if let h=highlights.last(where:{$0.sq==sq}),sq != selected {
                let color=h.kind=="no" ? palette.danger:palette.ink
                let path=NSBezierPath(ovalIn:rect.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset))
                color.withAlphaComponent(BoardOverlay.annotationFill).setFill();path.fill()
                color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.haloStrokeHigh).setStroke();path.lineWidth=s*BoardOverlay.haloWidth;path.stroke()
            }
            if attacked.contains(sq){palette.ink.withAlphaComponent(BoardOverlay.coverageOpacity).setStroke();let p=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.36,dy:s*0.36));p.lineWidth=max(1,s*0.025);p.stroke()}
            // Playable moves are solid; possibilities that a click cannot play are hollow or dashed.
            if destinations.contains(sq),position[sq]==nil{if destinationsPlayable{palette.ink.withAlphaComponent(BoardOverlay.destinationOpacity).setFill();NSBezierPath(ovalIn:rect.insetBy(dx:s*0.44,dy:s*0.44)).fill()}else{palette.ink.withAlphaComponent(BoardOverlay.destinationOpacity).setStroke();let dot=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.42,dy:s*0.42));dot.lineWidth=max(1,s*0.02);dot.stroke()}}
            if destinations.contains(sq),position[sq] != nil {palette.ink.setStroke();let ring=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.07,dy:s*0.07));ring.lineWidth=max(2,s*0.045);if !destinationsPlayable{let dash=BoardOverlay.relationshipDash.map{$0*s};ring.setLineDash(dash,count:dash.count,phase:0)};ring.stroke()}
        }
    }
    private func drawRelationships(_ palette:BoardPalette,side s:CGFloat){
        // A guard line is a protection connector the lesson draws: solid, since the lesson states the guard outright.
        var seen=Set<String>()
        for line in guards where line.count==2 && ChessRules.validSquare(line[0]) && ChessRules.validSquare(line[1]) && seen.insert(line.joined(separator:":")).inserted {
            connector(from:line[0],to:line[1],color:palette.protection,limited:false,side:s)
        }
        if let mode=relationshipMode {
            let color=mode == .protected ? palette.protection:palette.danger
            for connection in relationshipConnectors {connector(from:connection.source,to:connection.target,color:color,limited:connection.limited,side:s)}
        }
    }
    /// A curved line from the source square towards the target, with a ring on the source: the piece that acts.
    private func connector(from source:String,to target:String,color:NSColor,limited:Bool,side s:CGFloat){
        let a=squareRect(source),b=squareRect(target),dx=b.midX-a.midX,dy=b.midY-a.midY,length=hypot(dx,dy)
        guard length>0 else{return};let ux=dx/length,uy=dy/length,inset=s*BoardOverlay.relationshipInset,bend=min(length,s*2)*BoardOverlay.relationshipCurve
        let start=NSPoint(x:a.midX+ux*inset,y:a.midY+uy*inset),end=NSPoint(x:b.midX-ux*inset,y:b.midY-uy*inset)
        let curve=NSBezierPath();curve.move(to:start);curve.curve(to:end,controlPoint1:NSPoint(x:start.x+(end.x-start.x)/3-uy*bend,y:start.y+(end.y-start.y)/3+ux*bend),controlPoint2:NSPoint(x:start.x+2*(end.x-start.x)/3-uy*bend,y:start.y+2*(end.y-start.y)/3+ux*bend));curve.lineCapStyle = .round;curve.lineWidth=s*BoardOverlay.relationshipWidth
        if limited{let dash=BoardOverlay.relationshipDash.map{$0*s};curve.setLineDash(dash,count:dash.count,phase:0)}
        color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.relationshipOpacity).setStroke();curve.stroke()
        let halo=NSBezierPath(ovalIn:a.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset));color.withAlphaComponent(BoardOverlay.annotationFill).setFill();halo.fill();halo.lineWidth=s*BoardOverlay.haloWidth;halo.stroke()
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
            if let piece=position[sq],!moves.contains(where:{$0.to==sq}),explicitMotion?.from != sq {PieceArtwork.draw(piece,in:rect,alpha:drag?.from==sq ? BoardOverlay.dragOriginOpacity:1)}
            if let piece=captured[sq],progress<1{PieceArtwork.draw(piece,in:rect,alpha:CGFloat(1-progress))}
        }
        for m in moves {let a=squareRect(m.from),b=squareRect(m.to);PieceArtwork.draw(m.piece,in:NSRect(x:a.minX+(b.minX-a.minX)*ease,y:a.minY+(b.minY-a.minY)*ease,width:s,height:s))}
        if let m=explicitMotion,let piece=position[m.from]{let a=squareRect(m.from),b=squareRect(m.to),t=m.t*m.t*(3-2*m.t);PieceArtwork.draw(piece,in:NSRect(x:a.minX+(b.minX-a.minX)*t,y:a.minY+(b.minY-a.minY)*t,width:s,height:s))}
        if let d=drag,let piece=position[d.from]{PieceArtwork.draw(piece,in:NSRect(x:d.point.x-s/2,y:d.point.y-s/2,width:s,height:s))}
    }
    /// Coordinates grow with the squares, from the minimum size up to what the margin around the board can hold.
    static func coordinateFontSize(side s:CGFloat)->CGFloat {min(Metrics.boardMargin-6,max(Metrics.coordinateSize,(s*0.14).rounded()))}
    /// Coordinates (B-14): lowercase files under the board and ranks on its left, each centred on its square and in the
    /// margin by its measured size, in the order the board is shown.
    static func coordinateLabels(board r:NSRect,blackAtBottom:Bool,margin:CGFloat,size:(String)->NSSize)->[(text:String,origin:NSPoint)] {
        let s=r.width/8
        let files=(0..<8).map{i->(text:String,origin:NSPoint) in let text=String(UnicodeScalar(97+(blackAtBottom ? 7-i:i))!),m=size(text);return (text,NSPoint(x:r.minX+(CGFloat(i)+0.5)*s-m.width/2,y:r.minY-margin+(margin-m.height)/2))}
        let ranks=(0..<8).map{i->(text:String,origin:NSPoint) in let text=String(blackAtBottom ? 8-i:i+1),m=size(text);return (text,NSPoint(x:r.minX-margin+(margin-m.width)/2,y:r.minY+(CGFloat(i)+0.5)*s-m.height/2))}
        return files+ranks
    }
    private func drawLabels(_ palette:BoardPalette,side s:CGFloat){
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:Self.coordinateFontSize(side:s),weight:.medium),.foregroundColor:NativeColors.secondaryText]
        for label in Self.coordinateLabels(board:boardRect,blackAtBottom:blackAtBottom,margin:Metrics.boardMargin,size:{($0 as NSString).size(withAttributes:attrs)}){(label.text as NSString).draw(at:label.origin,withAttributes:attrs)}
        for (i,sq) in counts.enumerated(){let rect=squareRect(sq),label=String(i+1) as NSString;label.draw(at:NSPoint(x:rect.minX+s*0.08,y:rect.maxY-s*0.25),withAttributes:[.font:NSFont.systemFont(ofSize:s*0.16,weight:.bold),.foregroundColor:palette.ink])}
    }
}
