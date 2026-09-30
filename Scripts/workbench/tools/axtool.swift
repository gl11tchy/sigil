import ApplicationServices
import Foundation
// axtool <pid> dump            — roles and labels of the app's first window
// axtool <pid> press <prefix>  — AXPress the first button whose label starts with <prefix>
// axtool <pid> focused         — role, label and start of the value of the element with keyboard focus
let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else { print("usage"); exit(2) }
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success, let value else { return "" }
    return (value as? String) ?? ""
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return (value as? [AXUIElement]) ?? []
}
func label(_ e: AXUIElement) -> String {
    for name in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] as [String] {
        let v = attr(e, name); if !v.isEmpty { return v }
    }
    return ""
}
if args[2] == "focused" {
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
        let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { print("no focused element"); exit(1) }
    let element = focused as! AXUIElement
    // The value tells two terminals with the same label apart.
    let value = attr(element, kAXValueAttribute).split(whereSeparator: \.isNewline).joined(separator: " / ")
    print(attr(element, kAXRoleAttribute) + " | " + label(element) + " | " + String(value.prefix(160)))
    exit(0)
}
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
guard let window = (windows as? [AXUIElement])?.first else { print("no window"); exit(1) }
var found: AXUIElement?
func walk(_ e: AXUIElement, _ depth: Int) {
    for child in children(e) {
        let role = attr(child, kAXRoleAttribute)
        let text = label(child)
        if args[2] == "dump", !text.isEmpty || role == "AXButton" {
            print(String(repeating: " ", count: depth) + role + " | " + text)
        }
        if args[2] == "press", found == nil, ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role),
            text.hasPrefix(args[3]) { found = child }
        if depth < 30 { walk(child, depth + 1) }
    }
}
walk(window, 0)
if args[2] == "press" {
    guard let found else { print("not found: \(args[3])"); exit(1) }
    let result = AXUIElementPerformAction(found, kAXPressAction as CFString)
    print(result == .success ? "pressed \(label(found))" : "press failed \(result.rawValue)")
}
