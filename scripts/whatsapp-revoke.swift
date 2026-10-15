#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Foundation

struct Options {
    var chat: String = ""
    var dryRun: Bool = false
    var limit: Int = Int.max
}

func usage(exitCode: Int32 = 1) -> Never {
    let text = """
    Usage:
      swift whatsapp-revoke.swift --chat "<Contact Name>" [--dry-run] [--limit <N>]

    Options:
      --chat <name>   Exact WhatsApp chat/contact header name (required)
      --dry-run       Inspect and list eligible outgoing messages without deleting
      --limit <N>     Maximum number of messages to delete for everyone
      --help, -h      Show this help message
    """
    if exitCode == 0 {
        print(text)
    } else {
        fputs(text + "\n", stderr)
    }
    exit(exitCode)
}

var opts = Options()
var idx = 1
let args = CommandLine.arguments
while idx < args.count {
    switch args[idx] {
    case "--chat":
        idx += 1
        guard idx < args.count else { usage(exitCode: 1) }
        opts.chat = args[idx]
    case "--dry-run":
        opts.dryRun = true
    case "--limit":
        idx += 1
        guard idx < args.count, let n = Int(args[idx]), n > 0 else { usage(exitCode: 1) }
        opts.limit = n
    case "--help", "-h":
        usage(exitCode: 0)
    default:
        usage(exitCode: 1)
    }
    idx += 1
}
guard !opts.chat.isEmpty else { usage(exitCode: 1) }

func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func norm(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{200E}", with: "")
     .replacingOccurrences(of: "\u{200F}", with: "")
     .replacingOccurrences(of: "\u{202F}", with: " ")
}
func label(_ e: AXUIElement) -> String {
    for k in [kAXDescriptionAttribute, kAXTitleAttribute, "AXIdentifier"] {
        if let s = attr(e, k) as? String, !s.isEmpty { return norm(s) }
    }
    return ""
}
func at(_ root: AXUIElement, _ path: [Int]) -> AXUIElement? {
    var cur = root
    for i in path {
        let ch = children(cur)
        guard ch.indices.contains(i) else { return nil }
        cur = ch[i]
    }
    return cur
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero; var sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}
func findAll(_ root: AXUIElement, maxDepth: Int = 14, pred: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    while let (el, d) = stack.popLast() {
        if pred(el) { out.append(el) }
        if d < maxDepth {
            for c in children(el).reversed() { stack.append((c, d + 1)) }
        }
    }
    return out
}
func isOutgoingActive(_ el: AXUIElement, chat: String) -> Bool {
    guard (attr(el, "AXIdentifier") as? String) == "WAMessageBubbleTableViewCell" else { return false }
    let desc = norm(attr(el, kAXDescriptionAttribute) as? String ?? "")
    return (desc.hasPrefix("Your message,") || desc.contains("\nYour message,"))
        && desc.contains("Sent to \(chat)")
        && !desc.contains("Received from \(chat)")
        && !desc.contains("You deleted this message")
        && !desc.contains("This message was deleted")
}
func resetModalAndSelection(_ win: AXUIElement) {
    if let pop = at(win, [4]), (attr(pop, kAXRoleAttribute) as? String) == "AXPopover" {
        _ = AXUIElementPerformAction(pop, kAXCancelAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }
    let menus = findAll(win, maxDepth: 4) { (attr($0, kAXRoleAttribute) as? String) == "AXMenu" }
    for m in menus {
        _ = AXUIElementPerformAction(m, kAXCancelAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    if let cancelBtn = at(win, [0,0,1,2,0,3]), label(cancelBtn) == "Cancel" {
        _ = AXUIElementPerformAction(cancelBtn, kAXPressAction as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    }
}

guard AXIsProcessTrusted() else {
    fputs("ERROR: Grant Accessibility permission to your terminal in System Settings > Privacy & Security > Accessibility.\n", stderr)
    exit(1)
}
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp")
guard apps.count == 1, let app = apps.first else {
    fputs("ERROR: WhatsApp.app is not uniquely running.\n", stderr)
    exit(1)
}
_ = app.activate(options: [])
RunLoop.current.run(until: Date().addingTimeInterval(0.3))

let axApp = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(axApp, 2.0)

guard let wins = attr(axApp, kAXWindowsAttribute) as? [AXUIElement],
      let win0 = wins.first(where: { (attr($0, "AXIdentifier") as? String) == "SceneWindow" }) else {
    fputs("ERROR: WhatsApp SceneWindow not found.\n", stderr)
    exit(1)
}
resetModalAndSelection(win0)

// Switch to target chat in sidebar if not already active
if let hdr = at(win0, [0,0,1,2,0,0]), label(hdr) != opts.chat {
    if let listPane = at(win0, [0,0,1,0]) {
        let matches = findAll(listPane, maxDepth: 10) {
            (attr($0, kAXRoleAttribute) as? String) == "AXButton"
                && norm(attr($0, kAXDescriptionAttribute) as? String ?? "").hasPrefix(opts.chat)
        }
        guard let row = matches.first else {
            fputs("ERROR: Chat '\(opts.chat)' is not currently open or visible in the sidebar. Open it in WhatsApp first.\n", stderr)
            exit(1)
        }
        _ = AXUIElementPerformAction(row, kAXPressAction as CFString)
        let waitDeadline = Date().addingTimeInterval(4.0)
        while Date() < waitDeadline {
            if let h = at(win0, [0,0,1,2,0,0]), label(h) == opts.chat { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

guard let hdr0 = at(win0, [0,0,1,2,0,0]), label(hdr0) == opts.chat,
      let tbl0 = at(win0, [0,0,1,2,1,0,0]), label(tbl0) == "Messages in chat with \(opts.chat)" else {
    fputs("ERROR: Active chat does not match '\(opts.chat)'. Aborting.\n", stderr)
    exit(1)
}

if opts.dryRun {
    let rows = children(tbl0).filter { isOutgoingActive($0, chat: opts.chat) }
    print("DRY RUN: \(rows.count) active outgoing message(s) visible in '\(opts.chat)':")
    for (i, r) in rows.enumerated() {
        let desc = norm(attr(r, kAXDescriptionAttribute) as? String ?? "").replacingOccurrences(of: "\n", with: " | ")
        print("  [\(i + 1)] \(desc.prefix(110))")
    }
    exit(0)
}

var deletedCount = 0
var ineligibleDescs = Set<String>()
var scrollUpAttemptsWithoutNew = 0

while deletedCount < opts.limit {
    _ = app.activate(options: [])
    guard let wins = attr(axApp, kAXWindowsAttribute) as? [AXUIElement],
          let win = wins.first(where: { (attr($0, "AXIdentifier") as? String) == "SceneWindow" }),
          let hdr = at(win, [0,0,1,2,0,0]), label(hdr) == opts.chat,
          let tbl = at(win, [0,0,1,2,1,0,0]), label(tbl) == "Messages in chat with \(opts.chat)" else {
        fputs("ERROR: Active chat changed away from '\(opts.chat)' — aborting immediately.\n", stderr)
        exit(1)
    }
    let chatPane = at(win, [0,0,1,2]) ?? win
    let tblRect = frame(tbl)
    let navMaxY = at(win, [0,0,1,2,0]).flatMap(frame)?.maxY ?? ((tblRect?.minY ?? 30.0) + 70.0)
    let safeMinY = max(tblRect?.minY ?? 0.0, navMaxY) + 12.0
    let safeMaxY = (tblRect?.maxY ?? 860.0) - 20.0

    let rows = children(tbl)
    let allActive = rows.filter {
        isOutgoingActive($0, chat: opts.chat)
            && !ineligibleDescs.contains(norm(attr($0, kAXDescriptionAttribute) as? String ?? ""))
    }
    let visibleActive = allActive.filter {
        guard let f = frame($0) else { return false }
        return f.origin.y >= safeMinY && f.maxY <= safeMaxY
    }

    var chosenTarget = visibleActive.last
    if chosenTarget == nil {
        if scrollUpAttemptsWithoutNew < 6 {
            let beforeSummary = rows.map { "\(norm(attr($0, kAXDescriptionAttribute) as? String ?? "")):\(Int(frame($0)?.origin.y ?? -999))" }
            _ = AXUIElementPerformAction(tbl, "AXScrollUpByPage" as CFString)
            RunLoop.current.run(until: Date().addingTimeInterval(0.75))
            let afterRows = children(tbl)
            let afterSummary = afterRows.map { "\(norm(attr($0, kAXDescriptionAttribute) as? String ?? "")):\(Int(frame($0)?.origin.y ?? -999))" }
            if afterSummary != beforeSummary {
                scrollUpAttemptsWithoutNew = 0
                continue
            } else {
                scrollUpAttemptsWithoutNew += 1
                if scrollUpAttemptsWithoutNew < 2 { continue }
            }
        }
        let topVisible = allActive.filter {
            guard let f = frame($0) else { return false }
            return f.maxY > (navMaxY + 5.0) && f.origin.y <= safeMaxY
        }
        if let topCandidate = topVisible.last {
            chosenTarget = topCandidate
        } else {
            break
        }
    }
    guard let target = chosenTarget else { break }

    let targetDesc = norm(attr(target, kAXDescriptionAttribute) as? String ?? "")
    let firstLine = targetDesc.replacingOccurrences(of: "\n", with: " | ").prefix(95)

    // Step 1 + 2: Open context menu and press Delete until "1 Selected" toolbar appears
    let selDeadline = Date().addingTimeInterval(5.0)
    var lastMenuTrigger = Date.distantPast
    var lastMenuPress = Date.distantPast
    var inSelection = false
    while Date() < selDeadline {
        let counts = findAll(chatPane, maxDepth: 8) {
            (attr($0, "AXIdentifier") as? String) == "Toolbar_SelectedMessageCount" && label($0) == "1 Selected"
        }
        let delBtns = findAll(chatPane, maxDepth: 8) {
            (attr($0, "AXIdentifier") as? String) == "Toolbar_DeleteButton" && label($0) == "Delete"
        }
        if counts.count == 1 && delBtns.count == 1 {
            inSelection = true
            break
        }
        let items = findAll(win, maxDepth: 6) {
            (attr($0, kAXRoleAttribute) as? String) == "AXMenuItem" && label($0) == "Delete"
        }
        if items.count == 1 {
            if Date().timeIntervalSince(lastMenuPress) >= 0.35 {
                _ = AXUIElementPerformAction(items[0], kAXPressAction as CFString)
                lastMenuPress = Date()
            }
        } else if Date().timeIntervalSince(lastMenuTrigger) >= 0.8 {
            if let liveTarget = children(tbl).last(where: { norm(attr($0, kAXDescriptionAttribute) as? String ?? "") == targetDesc }) {
                _ = AXUIElementPerformAction(liveTarget, "AXScrollToVisible" as CFString)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                _ = AXUIElementPerformAction(liveTarget, kAXShowMenuAction as CFString)
            }
            lastMenuTrigger = Date()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !inSelection {
        resetModalAndSelection(win)
        _ = AXUIElementPerformAction(tbl, "AXScrollUpByPage" as CFString)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        continue
    }

    // Step 3: Press Toolbar_DeleteButton until "Delete message?" popover appears
    var dfePresent = false
    var popFound = false
    let popDeadline = Date().addingTimeInterval(5.0)
    var lastTbPress = Date.distantPast
    while Date() < popDeadline {
        let titles = findAll(win) {
            (attr($0, "AXIdentifier") as? String) == "ActionSheet_TitleLabel" && label($0) == "Delete message?"
        }
        if titles.count == 1 {
            popFound = true
            let btns = findAll(win) {
                (attr($0, kAXRoleAttribute) as? String) == "AXButton" && label($0) == "Delete for everyone"
            }
            dfePresent = (btns.count == 1)
            break
        }
        if Date().timeIntervalSince(lastTbPress) >= 0.4 {
            let counts = findAll(chatPane, maxDepth: 8) {
                (attr($0, "AXIdentifier") as? String) == "Toolbar_SelectedMessageCount" && label($0) == "1 Selected"
            }
            let delBtns = findAll(chatPane, maxDepth: 8) {
                (attr($0, "AXIdentifier") as? String) == "Toolbar_DeleteButton" && label($0) == "Delete"
            }
            if counts.count == 1 && delBtns.count == 1 {
                _ = AXUIElementPerformAction(delBtns[0], kAXPressAction as CFString)
                lastTbPress = Date()
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }
    guard popFound else {
        fputs("ERROR: Delete message? popover did not appear.\n", stderr)
        exit(1)
    }
    if !dfePresent {
        print("SKIPPED (ineligible for Delete for everyone): \(firstLine)")
        ineligibleDescs.insert(targetDesc)
        resetModalAndSelection(win)
        continue
    }

    // Step 4: Press "Delete for everyone" and verify deletion
    let verDeadline = Date().addingTimeInterval(6.0)
    var lastDfePress = Date.distantPast
    var gone = false
    while Date() < verDeadline {
        let btns = findAll(win) {
            (attr($0, kAXRoleAttribute) as? String) == "AXButton" && label($0) == "Delete for everyone"
        }
        if btns.count == 1 {
            if Date().timeIntervalSince(lastDfePress) >= 0.35 {
                _ = AXUIElementPerformAction(btns[0], kAXPressAction as CFString)
                lastDfePress = Date()
            }
        } else if let tblNow = at(win, [0,0,1,2,1,0,0]) {
            let stillActive = children(tblNow).contains {
                norm(attr($0, kAXDescriptionAttribute) as? String ?? "") == targetDesc
            }
            if !stillActive { gone = true; break }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    }
    guard gone else {
        fputs("ERROR: Message did not transition to deleted state.\n", stderr)
        exit(1)
    }
    deletedCount += 1
    print("Deleted [\(deletedCount)]: \(firstLine)")
    fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
}
print("DONE. Deleted: \(deletedCount), Ineligible skipped: \(ineligibleDescs.count)")
