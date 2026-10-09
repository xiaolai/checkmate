// Narrow native acceptance helper: inspect/press an accessible control in a named PID.
import AppKit
import ApplicationServices
let pid=Int32(CommandLine.arguments[1])!
let action=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "list"
let target=CommandLine.arguments.count>3 ? CommandLine.arguments[3] : ""
let windowName=CommandLine.arguments.count>4 ? CommandLine.arguments[4] : ""
let app=AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app,2)
if action=="windows" {let windows=getWindows();print(windows.count);for w in windows{var v:CFTypeRef?;AXUIElementCopyAttributeValue(w,kAXTitleAttribute as CFString,&v);print(v as? String ?? "")};exit(0)}
func getWindows()->[AXUIElement]{var v:CFTypeRef?;AXUIElementCopyAttributeValue(app,kAXWindowsAttribute as CFString,&v);return v as? [AXUIElement] ?? []}
if action=="quit" {exit(NSRunningApplication(processIdentifier:pid)?.terminate() == true ? 0:1)}
func get(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(e,k as CFString,&v);return v}
var found=false
var visited=0
func walk(_ e:AXUIElement,_ depth:Int=0){
 if depth>35 || found || visited>=5000{return}
 visited += 1
 let role=get(e,kAXRoleAttribute) as? String ?? ""
 if depth>0 && role=="AXApplication" {return}
 let names=[get(e,kAXTitleAttribute) as? String,get(e,kAXDescriptionAttribute) as? String,get(e,kAXValueAttribute) as? String].compactMap{$0}.filter{!$0.isEmpty}
 if action=="list" && !names.isEmpty {print("\(role): \(names.joined(separator:" | "))")}
 if action=="focus" && names.contains(target){let result=AXUIElementSetAttributeValue(e,kAXFocusedAttribute as CFString,kCFBooleanTrue);print("focus \(target): \(result.rawValue)");found=result == .success;return}
 if action=="press" && names.contains(target) && ["AXButton","AXCheckBox","AXPopUpButton","AXMenuItem","AXRadioButton"].contains(role) {let result=AXUIElementPerformAction(e,kAXPressAction as CFString);print("press \(target): \(result.rawValue)");found=result == .success;return}
 for c in get(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] {walk(c,depth+1)}
}
if action=="fullscreen" {guard let first=getWindows().first else{exit(1)};let current=get(first,"AXFullScreen") as? Bool ?? false;exit(AXUIElementSetAttributeValue(first,"AXFullScreen" as CFString,current ? kCFBooleanFalse:kCFBooleanTrue) == .success ? 0:1)}
if action=="position-x" {guard let first=getWindows().first,let raw=get(first,kAXPositionAttribute) else{exit(1)};var point=CGPoint.zero;AXValueGetValue(raw as! AXValue,.cgPoint,&point);print(point.x);exit(0)}
if action=="drag" {guard let window=get(app,kAXWindowsAttribute) as? [AXUIElement],let first=window.first,let raw=get(first,kAXPositionAttribute) else{exit(1)};var point=CGPoint.zero;AXValueGetValue(raw as! AXValue,.cgPoint,&point);point.x+=180;point.y+=25;let source=CGEventSource(stateID:.hidSystemState);CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);for step in 1...10{Thread.sleep(forTimeInterval:0.03);CGEvent(mouseEventSource:source,mouseType:.leftMouseDragged,mouseCursorPosition:CGPoint(x:point.x+Double(step)*5,y:point.y+Double(step)*2),mouseButton:.left)?.post(tap:.cghidEventTap)};CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:CGPoint(x:point.x+50,y:point.y+20),mouseButton:.left)?.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.2);var moved=CGPoint.zero;if let value=get(first,kAXPositionAttribute){AXValueGetValue(value as! AXValue,.cgPoint,&moved)};print("drag delta: \(moved.x-(point.x-180)),\(moved.y-(point.y-25))");exit(abs(moved.x-(point.x-180)-50)<=1 && abs(moved.y-(point.y-25)-20)<=1 ? 0:1)}

if action=="close-main" || action=="close-settings" {
 for w in get(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
  if ((get(w,kAXTitleAttribute) as? String == "Settings") == (action=="close-settings")), let value=get(w,kAXCloseButtonAttribute) {
   let button=value as! AXUIElement
   let result=AXUIElementPerformAction(button,kAXPressAction as CFString)
   print("close window: \(result.rawValue)");exit(result == .success ? 0:1)
  }
 }
 fputs("Requested window not found\n",stderr);exit(1)
}
if windowName.isEmpty {walk(app)} else {for w in get(app,kAXWindowsAttribute) as? [AXUIElement] ?? [] {if get(w,kAXTitleAttribute) as? String==windowName {walk(w)}}}
if ["press","focus"].contains(action) && !found {fputs("Control not found: \(target)\n",stderr);exit(1)}
