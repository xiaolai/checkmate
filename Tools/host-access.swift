// What a UI gate needs from a test Mac, as JSON: Accessibility and Screen Recording for the SSH session's responsible
// process (sshd-keygen-wrapper), and an unlocked console session. Run over SSH on the host being checked; the LAN pair
// receives a copy built on the test host (it does not build). Exit 0 only when all three hold.
// The console's lock state comes from the IORegistry (IOConsoleUsers): an SSH session has no window-server session of
// its own to ask.
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
let root=IORegistryGetRootEntry(kIOMainPortDefault)
let users=IORegistryEntryCreateCFProperty(root,"IOConsoleUsers" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [[String:Any]] ?? []
IOObjectRelease(root)
let console=users.first{($0["kCGSSessionOnConsoleKey"] as? Bool)==true}
let unlocked=console.map{($0["CGSSessionScreenIsLocked"] as? Bool) != true} ?? false
let result:[String:Any]=["accessibility":AXIsProcessTrusted(),"screenCapture":CGPreflightScreenCaptureAccess(),"consoleUnlocked":unlocked]
let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
print(String(decoding:data,as:UTF8.self))
exit(result.values.allSatisfy{$0 as? Bool==true} ? 0:1)
