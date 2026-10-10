import AppKit
import CheckmateCore
final class SquareAccessibility:NSAccessibilityElement {
    weak var board:BoardView?;let square:String
    init(board:BoardView,square:String){self.board=board;self.square=square;super.init();setAccessibilityParent(board)}
    override func accessibilityRole()->NSAccessibility.Role? {.button}
    override func accessibilityLabel()->String? {guard let board=board else{return square};var parts=[square];if let p=board.position[square]{parts += [p.first=="w" ? "White":"Black",BoardView.names[String(p.suffix(1)),default:"piece"]]};if board.selected==square{parts.append("selected")};if board.destinations.contains(square){parts.append(board.position[square]==nil ? "move destination":"capture destination")};if board.attacked.contains(square){parts.append("attacked or defended")};for h in board.highlights where h.sq==square{parts.append(h.kind=="check" ? "in check":"highlighted")};for a in board.arrows where a.count==2{if a[0]==square{parts.append("suggested move to "+a[1])};if a[1]==square{parts.append("suggested move from "+a[0])}};for connection in board.relationshipConnectors {let description=connection.limited ? "restricted or conditional":"";if connection.source==square{parts.append("\(board.relationshipMode == .protected ? "protects":"attacks") \(connection.target) \(description)")};if connection.target==square{parts.append("\(board.relationshipMode == .protected ? "protected by":"attacked by") \(connection.source) \(description)")}};return parts.joined(separator:", ")}
    override func accessibilityFrame()->NSRect {guard let b=board,let w=b.window else{return .zero};return w.convertToScreen(b.convert(b.squareRect(square),to:nil))}
    override func isAccessibilityFocused()->Bool {board?.focus==square && board?.window?.firstResponder === board}
    override func setAccessibilityFocused(_ value:Bool){if value{board?.focus=square;board?.window?.makeFirstResponder(board);board?.keyboardFocusVisible=true;board?.needsDisplay=true;NSAccessibility.post(element:self,notification:.focusedUIElementChanged)}}
    override func accessibilityPerformPress()->Bool {guard let board=board else{return false};board.focus=square;board.window?.makeFirstResponder(board);board.keyboardFocusVisible=true;board.activate?(square);board.needsDisplay=true;return true}
}
final class BoardView:NSView {
    static let names=["p":"pawn","n":"knight","b":"bishop","r":"rook","q":"queen","k":"king"]
    var selected:String? {didSet{if selected != oldValue{breathStart=ProcessInfo.processInfo.systemUptime;updateBreathing()}}}
    var position:Position=[:],destinations:[String]=[],attacked:[String]=[],highlights:[Highlight]=[],counts:[String]=[],explicitMotion:PieceMotion?,theme="wood",focus="e2"
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
    var reviewKey:((UInt16)->Bool)?,dropReview:((Data)->Void)?
    var keyboardFocusVisible=false
    private var showsKeyboardFocus:Bool {keyboardFocusVisible && window?.isKeyWindow == true && window?.firstResponder === self}
    var activate:((String)->Void)?,clearSelection:(()->Void)?,onLayout:(()->Void)?
    override func layout(){super.layout();onLayout?()}
    private var moves:[(piece:String,from:String,to:String)]=[],captured:[String:String]=[:],animationStart:TimeInterval=0,animationDuration=0.0,timer:Timer?
    private lazy var squares=ChessRules.squares.map{SquareAccessibility(board:self,square:$0)}
    override var acceptsFirstResponder:Bool {true}
    override var mouseDownCanMoveWindow:Bool {false}
    override func accessibilityRole()->NSAccessibility.Role? {.group}
    override func accessibilityLabel()->String? {"Chessboard"}
    override func accessibilityHelp()->String? {"Use arrow keys to explore squares and Space or Return to choose a piece or destination. Escape clears your selection."}
    override func isAccessibilityElement()->Bool {true}
    override func accessibilityChildren()->[Any]? {squares}
    override var accessibilityFocusedUIElement:Any? {squares.first{$0.square==focus}}
    override func accessibilityHitTest(_ point:NSPoint)->Any? {guard let window=window else{return self};let local=convert(window.convertPoint(fromScreen:point),from:nil);guard let sq=square(at:local) else{return self};return squares.first{$0.square==sq}}
    var boardRect:NSRect {let side=max(0,min(bounds.width,bounds.height)-Metrics.boardMargin*2);return NSRect(x:(bounds.width-side)/2,y:(bounds.height-side)/2,width:side,height:side)}
    func squareRect(_ sq:String)->NSRect {guard ChessRules.validSquare(sq) else{return .zero};let r=boardRect,s=r.width/8,file=Int(sq.utf8.first!-97),rank=Int(sq.suffix(1))!-1;return NSRect(x:r.minX+CGFloat(file)*s,y:r.minY+CGFloat(rank)*s,width:s,height:s)}
    func square(at p:NSPoint)->String? {let r=boardRect;guard r.contains(p),r.width>0 else{return nil};return String(UnicodeScalar(97+min(7,Int((p.x-r.minX)/(r.width/8))))!)+String(min(7,Int((p.y-r.minY)/(r.height/8)))+1)}
    private var overlayTimer:Timer?,breathStart=ProcessInfo.processInfo.systemUptime
    var moveAnimationActive:Bool {timer != nil}
    var breathing:Bool {overlayTimer != nil && selected != nil}
    var animatingArrow:Bool {overlayTimer != nil && primaryMoveArrow != nil && relationshipMode==nil}
    private var arrowStart=ProcessInfo.processInfo.systemUptime,arrowElapsed:TimeInterval=0
    override init(frame:NSRect){super.init(frame:frame);registerForDraggedTypes([.fileURL,.string]);let click=NSClickGestureRecognizer(target:self,action:#selector(clicked(_:)));addGestureRecognizer(click)
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification]{NotificationCenter.default.addObserver(self,selector:#selector(windowActivityChanged(_:)),name:name,object:nil)}
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(displayOptionsChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
    }
    deinit {overlayTimer?.invalidate();NotificationCenter.default.removeObserver(self);NSWorkspace.shared.notificationCenter.removeObserver(self)}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();updateBreathing()}
    override var isHidden:Bool {didSet{updateBreathing()}}
    override func becomeFirstResponder()->Bool {let result=super.becomeFirstResponder();if NSApp.currentEvent?.type == .keyDown{keyboardFocusVisible=true};needsDisplay=true;return result}
    override func resignFirstResponder()->Bool {let result=super.resignFirstResponder();needsDisplay=true;return result}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    @objc private func windowActivityChanged(_ notification:Notification){guard notification.object as? NSWindow === window else{return};updateBreathing(closing:notification.name == NSWindow.willCloseNotification)}
    @objc private func displayOptionsChanged(){updateBreathing()}
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
    @objc private func clicked(_ gesture:NSClickGestureRecognizer){keyboardFocusVisible=false;window?.makeFirstResponder(self);if let sq=square(at:gesture.location(in:self)){focus=sq;activate?(sq)}}
    override func keyDown(with e:NSEvent){if e.modifierFlags.intersection([.command,.control,.option]).isEmpty,reviewKey?(e.keyCode)==true{return};if !e.modifierFlags.intersection([.command,.control,.option]).isEmpty{super.keyDown(with:e);return};if let char=e.charactersIgnoringModifiers?.lowercased(),char=="p" || char=="a"{inspectRelationship?(char=="p" ? .protected:.attacked);return};keyboardFocusVisible=true;if e.keyCode==36 || e.keyCode==49{activate?(focus);return};if e.keyCode==53{if dismissRelationships?()==true{return};selected=nil;destinations=[];clearSelection?();needsDisplay=true;return};var f=Int(focus.utf8.first!-97),r=Int(focus.suffix(1))!-1;switch e.keyCode{case 123:f-=1;case 124:f+=1;case 125:r-=1;case 126:r+=1;default:super.keyDown(with:e);return};focus=String(UnicodeScalar(97+max(0,min(7,f)))!)+String(max(0,min(7,r))+1);needsDisplay=true;if let square=squares.first(where:{$0.square==focus}){NSAccessibility.post(element:square,notification:.focusedUIElementChanged)}}
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {.copy}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {let pasteboard=sender.draggingPasteboard;if let url=NSURL(from:pasteboard) as URL?{guard url.isFileURL else{return false};do{let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=ReviewPolicy.maximumBytes else{return false};dropReview?(try Data(contentsOf:url));return true}catch{return false}};if let text=pasteboard.string(forType:.string),text.utf8.count<=ReviewPolicy.maximumBytes{dropReview?(Data(text.utf8));return true};return false}
    func cancelAnimation(){timer?.invalidate();timer=nil;moves=[];captured=[:];needsDisplay=true}
    func animate(_ m:MoveRecord,duration:Double){cancelAnimation();guard duration>0,!shouldReduceMotion else{return};moves=[(m.color+m.piece,m.from,m.to)];if m.flags.contains("k")||m.flags.contains("q"){let rank=String(m.from.suffix(1));moves.append((m.color+"r",(m.flags.contains("k") ? "h":"a")+rank,(m.flags.contains("k") ? "f":"d")+rank))};if let p=m.captured{captured[m.flags.contains("e") ? String(m.to.prefix(1))+String(m.from.suffix(1)):m.to]=(m.color=="w" ? "b":"w")+p};animationStart=Date.timeIntervalSinceReferenceDate;animationDuration=duration;timer=Timer.scheduledTimer(withTimeInterval:Metrics.frameInterval,repeats:true){[weak self] _ in guard let self=self else{return};self.needsDisplay=true;if Date.timeIntervalSinceReferenceDate-self.animationStart>=self.animationDuration{self.cancelAnimation()}}}
    private func glyph(_ piece:String,rect:NSRect,alpha:CGFloat=1){let symbols=["k":"♚","q":"♛","r":"♜","b":"♝","n":"♞","p":"♟"],white=piece.first=="w",size=rect.width*0.8
        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Arial Unicode MS",size:size) ?? NSFont.systemFont(ofSize:size),.foregroundColor:(white ? BoardPalette.lightPiece:BoardPalette.darkPiece).withAlphaComponent(alpha),.strokeColor:BoardPalette.pieceOutline.withAlphaComponent(alpha),.strokeWidth:white ? BoardOverlay.pieceOutlineWidth:0]
        let value=symbols[String(piece.suffix(1)),default:"♟"] as NSString,s=value.size(withAttributes:attrs);value.draw(at:NSPoint(x:rect.midX-s.width/2,y:rect.midY-s.height/2),withAttributes:attrs)
    }
    override func draw(_ dirty:NSRect){let r=boardRect,s=r.width/8;guard s>0 else{return}
        let palette=BoardPalette.theme(theme)
        let progress=animationDuration>0 ? min(1,(Date.timeIntervalSinceReferenceDate-animationStart)/animationDuration):1,ease=progress*progress*(3-2*progress)
        for sq in ChessRules.squares {let rect=squareRect(sq),parity=(Int(sq.utf8.first!-97)+Int(sq.suffix(1))!-1)%2; (parity==0 ? palette.darkSquare:palette.lightSquare).setFill();rect.fill()
            if sq==selected{let danger=highlights.contains{$0.sq==sq && ($0.kind=="check" || $0.kind=="no")};halo(rect,selected:true,color:danger ? palette.danger:nil)}
            if let h=highlights.last(where:{$0.sq==sq}),sq != selected {
                let color=h.kind=="check" || h.kind=="no" ? palette.danger:palette.ink
                let path=NSBezierPath(ovalIn:rect.insetBy(dx:s*BoardOverlay.annotationInset,dy:s*BoardOverlay.annotationInset))
                color.withAlphaComponent(BoardOverlay.annotationFill).setFill();path.fill()
                if h.kind != "last",!showsKeyboardFocus || focus != sq{color.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.haloStrokeHigh).setStroke();path.lineWidth=s*BoardOverlay.haloWidth;path.stroke()}
            }
            if attacked.contains(sq){palette.ink.withAlphaComponent(BoardOverlay.coverageOpacity).setStroke();let p=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.36,dy:s*0.36));p.lineWidth=max(1,s*0.025);p.stroke()}
            if destinations.contains(sq),position[sq]==nil{palette.ink.withAlphaComponent(BoardOverlay.destinationOpacity).setFill();NSBezierPath(ovalIn:rect.insetBy(dx:s*0.44,dy:s*0.44)).fill()}
            if destinations.contains(sq),position[sq] != nil {palette.ink.setStroke();let ring=NSBezierPath(ovalIn:rect.insetBy(dx:s*0.07,dy:s*0.07));ring.lineWidth=max(2,s*0.045);ring.stroke()}
            if showsKeyboardFocus,focus==sq,sq != selected {halo(rect,selected:false)}
        }
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
        var seen=Set<String>()
        for arrow in arrows where arrow.count==2 {
            guard seen.insert(arrow.joined(separator:":")).inserted,let geometry=BoardArrow(from:arrow[0],to:arrow[1],board:self) else{continue}
            let dash=BoardOverlay.arrowDash.map{$0*s}
            let phase=arrow==primaryMoveArrow ? BoardOverlay.arrowDashPhase(at:arrowElapsed,side:s):0
            geometry.shaft.setLineDash(dash,count:dash.count,phase:phase)
            let color=palette.ink.withAlphaComponent(shouldIncreaseContrast ? 1:BoardOverlay.arrowOpacity)
            color.setStroke();geometry.shaft.stroke();color.setFill();geometry.head.fill()
        }
        // Routes sit beneath the pieces, preserving both silhouettes and endpoint identity.
        for sq in ChessRules.squares {let rect=squareRect(sq)
            if let piece=position[sq],!moves.contains(where:{$0.to==sq}),explicitMotion?.from != sq {glyph(piece,rect:rect)}
            if let piece=captured[sq],progress<1{glyph(piece,rect:rect,alpha:CGFloat(1-progress))}
        }
        for m in moves {let a=squareRect(m.from),b=squareRect(m.to);glyph(m.piece,rect:NSRect(x:a.minX+(b.minX-a.minX)*ease,y:a.minY+(b.minY-a.minY)*ease,width:s,height:s))}
        if let m=explicitMotion,let piece=position[m.from]{let a=squareRect(m.from),b=squareRect(m.to),t=m.t*m.t*(3-2*m.t);glyph(piece,rect:NSRect(x:a.minX+(b.minX-a.minX)*t,y:a.minY+(b.minY-a.minY)*t,width:s,height:s))}

        let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:Metrics.coordinateSize,weight:.medium),.foregroundColor:NativeColors.secondaryText]
        for i in 0..<8 {let file=String(UnicodeScalar(65+i)!) as NSString,rank=String(i+1) as NSString;file.draw(at:NSPoint(x:r.minX+(CGFloat(i)+0.5)*s-4,y:r.minY-Metrics.padding),withAttributes:attrs);file.draw(at:NSPoint(x:r.minX+(CGFloat(i)+0.5)*s-4,y:r.maxY+4),withAttributes:attrs);rank.draw(at:NSPoint(x:r.minX-Metrics.padding,y:r.minY+(CGFloat(i)+0.5)*s-6),withAttributes:attrs);rank.draw(at:NSPoint(x:r.maxX+6,y:r.minY+(CGFloat(i)+0.5)*s-6),withAttributes:attrs)}
        for (i,sq) in counts.enumerated(){let rect=squareRect(sq),label=String(i+1) as NSString;label.draw(at:NSPoint(x:rect.minX+s*0.08,y:rect.maxY-s*0.25),withAttributes:[.font:NSFont.systemFont(ofSize:s*0.16,weight:.bold),.foregroundColor:palette.ink])}
    }
}
