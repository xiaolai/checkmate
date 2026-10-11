// Board click acceptance helper: real pointer events at chosen points of a square, element frames, and focus control.
// Usage: board-click-helper <pid> square-frame <square> | frame <identifier> | click-in <square> <fraction-from-top>
//        | activate | active | hold-focus <seconds>
import AppKit
import ApplicationServices

let pid=Int32(CommandLine.arguments[1])!
let action=CommandLine.arguments[2]
let argument=CommandLine.arguments.count>3 ? CommandLine.arguments[3]:""
let app=AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app,2)
func get(_ e:AXUIElement,_ k:String)->CFTypeRef? {var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
func names(_ e:AXUIElement)->[String] {[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute,kAXIdentifierAttribute].compactMap{get(e,$0) as? String}.filter{!$0.isEmpty}}
func find(_ e:AXUIElement,_ depth:Int=0,_ match:(AXUIElement)->Bool)->AXUIElement? {
    if depth>35{return nil};if match(e){return e}
    for child in get(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] {if let hit=find(child,depth+1,match){return hit}}
    return nil
}
func frame(_ e:AXUIElement)->CGRect? {
    guard let p=get(e,kAXPositionAttribute),let s=get(e,kAXSizeAttribute) else{return nil}
    var point=CGPoint.zero,size=CGSize.zero;AXValueGetValue(p as! AXValue,.cgPoint,&point);AXValueGetValue(s as! AXValue,.cgSize,&size)
    return CGRect(origin:point,size:size)
}
/// Squares are labelled "<square>, …"; the board itself is "Chessboard".
func square(_ name:String)->AXUIElement? {find(app){e in names(e).contains{$0==name || $0.hasPrefix(name+",")}}}
func describe(_ r:CGRect)->String {"\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))"}
// A click meant for Checkmate must land on Checkmate: another app's window or a system prompt over the point would
// take it silently. (Not activated here: inactive-window clicks are a scenario under test.)
func owner(at point:CGPoint)->pid_t?{var hit:AXUIElement?;guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&hit) == .success,let hit else{return nil};var owner:pid_t=0;AXUIElementGetPid(hit,&owner);return owner}
func click(_ point:CGPoint,checkingOwner:Bool=true){
    if checkingOwner,let other=owner(at:point),other != pid{fputs("Click at \(point) is covered by \(NSRunningApplication(processIdentifier:other)?.localizedName ?? "pid \(other)")\n",stderr);exit(3)}
    let source=CGEventSource(stateID:.hidSystemState)
    for type in [CGEventType.mouseMoved,.leftMouseDown,.leftMouseUp] {CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);usleep(60_000)}
}
switch action {
case "square-frame":guard let e=square(argument),let r=frame(e) else{fputs("Not found: \(argument)\n",stderr);exit(2)};print(describe(r))
case "frame":guard let e=find(app,0,{names($0).contains(argument)}),let r=frame(e) else{fputs("Not found: \(argument)\n",stderr);exit(2)};print(describe(r))
case "click-in":
    guard let e=square(argument),let r=frame(e) else{fputs("Not found: \(argument)\n",stderr);exit(2)}
    let fraction=Double(CommandLine.arguments[4]) ?? 0.5;click(CGPoint(x:r.midX,y:r.minY+r.height*fraction))
case "activate":
    // Bring the window forward (another app's window may cover it), then click the board's empty margin, which
    // activates the window and selects nothing.
    NSRunningApplication(processIdentifier:pid)?.activate(options:[.activateAllWindows]);usleep(300_000)
    guard let e=find(app,0,{names($0).contains("Chessboard")}),let r=frame(e) else{fputs("Not found: Chessboard\n",stderr);exit(2)}
    click(CGPoint(x:r.minX+4,y:r.midY))
case "active":print(NSRunningApplication(processIdentifier:pid)?.isActive == true)
case "hold-focus":
    // Takes focus as a person does: a real click on another app's window, placed clear of Checkmate's window.
    // (A process started from a shell may not activate itself; a click on its window always activates it.)
    NSApplication.shared.setActivationPolicy(.regular);NSApp.finishLaunching()
    guard let screen=NSScreen.screens.first,let checkmate=(get(app,kAXWindowsAttribute) as? [AXUIElement])?.first.flatMap(frame) else{fputs("No Checkmate window\n",stderr);exit(2)}
    let full=screen.frame,visible=screen.visibleFrame.insetBy(dx:40,dy:40),side:CGFloat=120
    let covered=NSRect(x:checkmate.minX,y:full.maxY-checkmate.maxY,width:checkmate.width,height:checkmate.height)
    let corners=[NSPoint(x:visible.minX,y:visible.minY),NSPoint(x:visible.maxX-side,y:visible.minY),NSPoint(x:visible.minX,y:visible.maxY-side),NSPoint(x:visible.maxX-side,y:visible.maxY-side)]
    guard let spot=corners.map({NSRect(origin:$0,size:NSSize(width:side,height:side))}).first(where:{!$0.intersects(covered)}) else{fputs("No screen space clear of Checkmate's window\n",stderr);exit(2)}
    let window=NSWindow(contentRect:spot,styleMask:[.titled],backing:.buffered,defer:false);window.title="Focus holder";window.orderFrontRegardless()
    func pump(_ seconds:Double){let end=Date().addingTimeInterval(seconds);while Date()<end{if let event=NSApp.nextEvent(matching:.any,until:Date().addingTimeInterval(0.05),inMode:.default,dequeue:true){NSApp.sendEvent(event)}}}
    pump(0.3);click(CGPoint(x:spot.midX,y:full.maxY-spot.midY),checkingOwner:false);pump(Double(argument) ?? 5)
default:fputs("Unknown action\n",stderr);exit(2)
}
