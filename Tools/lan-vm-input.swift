// LAN-play spike (e): real pointer and key events at screen positions, to drive a virtual machine's window (its
// Setup Assistant and Terminal), where there are no accessibility elements to aim at.
//   lan-vm-input click <x> <y>          a left click at global display points
//   lan-vm-input type <text>            the text, typed as Unicode key events
//   lan-vm-input key <code> [cmd|shift|ctrl|opt ...]   one key press, with modifiers
// Run in the console session of a test host, never on the main Mac.
import CoreGraphics
import Foundation

// The test host carries ~/.config/checkmate/host-role naming "test" (alone or with "build"), the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else{fatalError("lan-vm-input runs on a test host only.")}

let arguments = CommandLine.arguments
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
guard arguments.count >= 3 else { fail("Usage: lan-vm-input click <x> <y> | type <text> | key <code> [modifiers]") }
let source = CGEventSource(stateID: .hidSystemState)

func post(_ event: CGEvent?) {
    guard let event else { fail("Cannot create the event") }
    event.post(tap: .cghidEventTap)
}

/// A modifier key going down or up. The virtual machine view follows these, not an event's flags.
func modifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    event?.type = .flagsChanged; event?.flags = flags
    post(event); usleep(40_000)
}

switch arguments[1] {
case "click":
    guard arguments.count == 4, let x = Double(arguments[2]), let y = Double(arguments[3]) else { fail("click needs x and y") }
    let point = CGPoint(x: x, y: y)
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    usleep(120_000)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
    usleep(80_000)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
case "type":
    // A virtual machine's keyboard forwards key codes and ignores the Unicode string, so each character becomes the
    // US-layout key that makes it, with Shift where needed.
    let plain = Array("asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\u{0}\u{20}`")
    let shifted = Array("ASDFHGZXCV\u{0}BQWERYT!@#$^%+(&_*)}OU{IP\u{0}LJ\"K:|<?NM>\u{0}\u{20}~")
    for character in arguments[2...].joined(separator: " ") {
        let shift = !plain.contains(character) && shifted.contains(character)
        guard character != "\u{0}", let index = (shift ? shifted : plain).firstIndex(of: character) else {
            fail("Cannot type \(character)")
        }
        if shift { modifier(56, down: true, flags: .maskShift) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(index), keyDown: down)
            if shift { event?.flags = .maskShift }
            post(event)
            usleep(25_000)
        }
        if shift { modifier(56, down: false, flags: []) }
    }
case "key":
    guard let code = CGKeyCode(arguments[2]) else { fail("Key code must be a number") }
    // Each modifier is pressed before the key and released after it, as a person's fingers do.
    var flags: CGEventFlags = [], modifiers: [CGKeyCode] = []
    for name in arguments.dropFirst(3) {
        switch name {
        case "cmd": flags.insert(.maskCommand); modifiers.append(55)
        case "shift": flags.insert(.maskShift); modifiers.append(56)
        case "ctrl": flags.insert(.maskControl); modifiers.append(59)
        case "opt": flags.insert(.maskAlternate); modifiers.append(58)
        default: fail("Unknown modifier \(name)")
        }
    }
    var held: CGEventFlags = []
    let masks: [CGKeyCode: CGEventFlags] = [55: .maskCommand, 56: .maskShift, 59: .maskControl, 58: .maskAlternate]
    for code in modifiers { held.insert(masks[code]!); modifier(code, down: true, flags: held) }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
        usleep(40_000)
    }
    for code in modifiers.reversed() { held.remove(masks[code]!); modifier(code, down: false, flags: held) }
default:
    fail("Unknown action \(arguments[1])")
}
usleep(150_000)
