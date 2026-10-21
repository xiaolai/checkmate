// Narrow native acceptance helper: inspect/press an accessible control in a named PID.
import AppKit
import ApplicationServices
let pid=Int32(CommandLine.arguments[1])!
let action=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "list"
let target=CommandLine.arguments.count>3 ? CommandLine.arguments[3] : ""
let windowName=CommandLine.arguments.count>4 ? CommandLine.arguments[4] : ""
let app=AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app,2)
func getWindows()->[AXUIElement]{var v:CFTypeRef?;AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&v);return v as? [AXUIElement] ?? []}
/// A window's title and its identifier: Settings is titled by its pane but always identified as "Settings".
func windowNames(_ w:AXUIElement)->[String]{var t:CFTypeRef?,i:CFTypeRef?;AXUIElementCopyAttributeValue(w,kAXTitleAttribute as CFString,&t);AXUIElementCopyAttributeValue(w,kAXIdentifierAttribute as CFString,&i);return [t as? String ?? "",i as? String ?? ""]}
if action=="windows" {let windows=getWindows();print(windows.count);for w in windows{let names=windowNames(w);print(names[1].isEmpty || names[1]==names[0] ? names[0]:names[0]+" | "+names[1])};exit(0)}
if action=="quit" {exit(NSRunningApplication(processIdentifier:pid)?.terminate() == true ? 0:1)}
func get(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
var found=false
var visited=0
// `list-complete` lists like `list`, then exits 3 if the walk was cut short (its depth or size bound) or a child list
// could not be read, so a caller checking that something is absent never trusts a partial read.
let listing=action=="list" || action=="list-complete"
var incomplete:[String]=[]
/// An element's name attribute as text. For `list-complete`, a read that failed for any reason but the attribute being
/// absent or the element gone is a gap in the listing, so text the element shows can never be missed silently.
func named(_ e:AXUIElement,_ k:String)->String?{
 var v:CFTypeRef?;let read=AXUIElementCopyAttributeValue(e,k as CFString,&v)
 if action=="list-complete" && ![.success,.noValue,.attributeUnsupported,.notImplemented,.invalidUIElement].contains(read){incomplete.append("\(k): AXError \(read.rawValue)")}
 return v as? String
}
func walk(_ e:AXUIElement,_ depth:Int=0){
 if depth>35 || found || visited>=5000{if action=="list-complete"{incomplete.append(depth>35 ? "deeper than 35":"more than 5000 elements")};return}
 visited += 1
 let role=get(e,kAXRoleAttribute) as? String ?? ""
 if depth>0 && role=="AXApplication" {return}
 let label=get(e,kAXTitleUIElementAttribute)
 let labelElement=label.map{$0 as! AXUIElement}
 let linkedNames=labelElement.map{[get($0,kAXTitleAttribute) as? String,get($0,kAXDescriptionAttribute) as? String,get($0,kAXValueAttribute) as? String]} ?? []
 let names=([named(e,kAXTitleAttribute),named(e,kAXDescriptionAttribute),named(e,kAXValueAttribute),named(e,kAXIdentifierAttribute)]+linkedNames).compactMap{$0}.filter{!$0.isEmpty}
 if listing && !names.isEmpty {print("\(role): \(names.joined(separator:" | "))")}
 if action=="select" && names.contains(target) {
  var row=e
  for _ in 0..<12 {
   if get(row,kAXRoleAttribute) as? String=="AXRow" {
    let result=AXUIElementSetAttributeValue(row,kAXSelectedAttribute as CFString,kCFBooleanTrue)
    print("select \(target): \(result.rawValue)");found=result == .success;return
   }
   guard let parent=get(row,kAXParentAttribute) else{break};row=parent as! AXUIElement
  }
 }
 if action=="focus" && names.contains(target){let result=AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue);print("focus \(target): \(result.rawValue)");found=result == .success;return}
 if action=="press" && names.contains(target) && ["AXButton","AXCheckBox","AXSwitch","AXPopUpButton","AXMenuButton","AXMenuItem","AXRadioButton"].contains(role) {let result=AXUIElementPerformAction(e,kAXPressAction as CFString);print("press \(target): \(result.rawValue)");found=result == .success;return}
 var children:CFTypeRef?;let read=AXUIElementCopyAttributeValue(e,kAXChildrenAttribute as CFString,&children)
 // No children, none supported, or an element that went away mid-read: nothing unread. Anything else is a gap.
 if action=="list-complete" && ![.success,.noValue,.attributeUnsupported,.notImplemented,.invalidUIElement].contains(read){incomplete.append("\(role) children: AXError \(read.rawValue)")}
 for c in children as? [AXUIElement] ?? [] {walk(c,depth+1)}
}
if action=="fullscreen" {guard let first=getWindows().first else{exit(1)};let current=get(first,"AXFullScreen") as? Bool ?? false;exit(AXUIElementSetAttributeValue(first,"AXFullScreen" as CFString,current ? kCFBooleanFalse:kCFBooleanTrue) == .success ? 0:1)}
if action=="position-x" {guard let first=getWindows().first,let raw=get(first,kAXPositionAttribute) else{exit(1)};var point=CGPoint.zero;AXValueGetValue(raw as! AXValue,.cgPoint,&point);print(point.x);exit(0)}
// Native titlebar dragging consumes a small gesture threshold before movement.
// Verify the requested displacement within that threshold; persistence is checked separately.
if action=="drag" {let gestureTolerance=3.0;guard let window=get(app,kAXWindowsAttribute) as? [AXUIElement],let first=window.first,let raw=get(first,kAXPositionAttribute) else{exit(1)};var point=CGPoint.zero;AXValueGetValue(raw as! AXValue,.cgPoint,&point);point.x+=180;point.y+=25;let source=CGEventSource(stateID:.hidSystemState);CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);for step in 1...10{Thread.sleep(forTimeInterval:0.03);CGEvent(mouseEventSource:source,mouseType:.leftMouseDragged,mouseCursorPosition:CGPoint(x:point.x+Double(step)*5,y:point.y+Double(step)*2),mouseButton:.left)?.post(tap:.cghidEventTap)};CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:CGPoint(x:point.x+50,y:point.y+20),mouseButton:.left)?.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.2);var moved=CGPoint.zero;if let value=get(first,kAXPositionAttribute){AXValueGetValue(value as! AXValue,.cgPoint,&moved)};print("drag delta: \(moved.x-(point.x-180)),\(moved.y-(point.y-25))");exit(abs(moved.x-(point.x-180)-50)<=gestureTolerance && abs(moved.y-(point.y-25)-20)<=gestureTolerance ? 0:1)}

if action=="close-main" || action=="close-settings" {
 for w in get(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
  if (windowNames(w).contains("Settings") == (action=="close-settings")), let value=get(w,kAXCloseButtonAttribute) {
   let button=value as! AXUIElement
   let result=AXUIElementPerformAction(button,kAXPressAction as CFString)
   print("close window: \(result.rawValue)");exit(result == .success ? 0:1)
  }
 }
 fputs("Requested window not found\n",stderr);exit(1)
}
if windowName.isEmpty {walk(app)} else {for w in get(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {if windowNames(w).contains(windowName) {walk(w)}}}
if ["press","focus","select"].contains(action) && !found {fputs("Control not found: \(target)\n",stderr);exit(1)}
if action=="list-complete" && !incomplete.isEmpty {fputs("Incomplete accessibility listing: \(incomplete.prefix(5).joined(separator:"; "))\n",stderr);exit(3)}
