// A native Accessibility driver for the transfer test bundles. File panels
// expose AXSelectedRows, which selects files without synthetic keyboard input
// or assuming that a Powerbox window belongs to the host process.
import AppKit
import ApplicationServices
import Foundation

struct DriverError: Error, CustomStringConvertible {
    let description: String
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func descendants(_ element: AXUIElement) -> [AXUIElement] {
    var pending = [element]
    var found: [AXUIElement] = []
    var visited = Set<AXUIElement>()
    while let node = pending.popLast(), found.count < 2_000 {
        guard visited.insert(node).inserted else { continue }
        found.append(node)
        pending.append(contentsOf: children(node))
    }
    return found
}

func drive(identifier: String, bundle: URL, action: String, filename: String?) throws {
    guard
        (identifier.hasPrefix("dev.m2na.backpocket.transfer-source.") && action == "save")
            || (identifier.hasPrefix("dev.m2na.backpocket.transfer-sandbox.")
                && ["open", "save", "cancel"].contains(action))
    else { throw DriverError(description: "Refusing a non-test app or unsupported action") }
    guard AXIsProcessTrusted() else {
        throw DriverError(description: "The invoking terminal needs macOS Accessibility permission")
    }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard apps.count <= 1 else { throw DriverError(description: "Ambiguous test process") }
        guard let app = apps.first else {
            Thread.sleep(forTimeInterval: 0.1)
            continue
        }
        guard app.bundleURL?.standardizedFileURL == bundle.standardizedFileURL else {
            throw DriverError(
                description: "The running bundle differs from the requested test bundle")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 2)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let nodes = windows.flatMap(descendants)
        // Find the native panel rather than a similarly labelled host button.
        let panels = nodes.filter {
            [kAXSheetRole, "AXDialog"].contains(string($0, kAXRoleAttribute) ?? "")
                || string($0, kAXSubroleAttribute) == kAXDialogSubrole
        }
        for panel in panels {
            let elements = descendants(panel)
            if action == "open" {
                guard let filename else {
                    throw DriverError(description: "Missing fixture filename")
                }
                let rows = elements.filter { string($0, kAXRoleAttribute) == kAXRowRole }
                guard
                    let row = rows.first(where: { row in
                        descendants(row).contains {
                            string($0, kAXRoleAttribute) == kAXTextFieldRole
                                && string($0, kAXValueAttribute) == filename
                        }
                    })
                else { continue }
                guard
                    let outline = elements.first(where: {
                        string($0, kAXRoleAttribute) == kAXOutlineRole
                            && descendants($0).contains(row)
                    })
                else { throw DriverError(description: "No outline owns the fixture row") }
                let result = AXUIElementSetAttributeValue(
                    outline, kAXSelectedRowsAttribute as CFString, [row] as CFArray)
                guard result == .success else {
                    throw DriverError(description: "Cannot select fixture row: \(result.rawValue)")
                }
                let selected = attribute(outline, kAXSelectedRowsAttribute) as? [AXUIElement] ?? []
                guard selected.contains(row) else {
                    throw DriverError(description: "File selection did not persist")
                }
            }
            let titles: [String]
            switch action {
            case "open": titles = ["Open", "열기"]
            case "save": titles = ["Save", "저장"]
            default: titles = ["Cancel", "취소"]
            }
            guard
                let button = elements.first(where: {
                    string($0, kAXRoleAttribute) == kAXButtonRole
                        && titles.contains(string($0, kAXTitleAttribute) ?? "")
                        && (attribute($0, kAXEnabledAttribute) as? Bool == true)
                })
            else { continue }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else {
                throw DriverError(description: "Native button action failed: \(result.rawValue)")
            }
            print("Native panel action: \(action)")
            return
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw DriverError(description: "The native test file panel was not ready before the deadline")
}

do {
    let args = CommandLine.arguments
    guard args.count == 4 || args.count == 5 else {
        throw DriverError(
            description: "Usage: helper bundle-id app-path open|save|cancel [filename]")
    }
    try drive(
        identifier: args[1], bundle: URL(fileURLWithPath: args[2]),
        action: args[3], filename: args.count == 5 ? args[4] : nil)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
