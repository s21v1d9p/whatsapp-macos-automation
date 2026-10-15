---
name: whatsapp-macos-automation
description: Use when automating WhatsApp Desktop on macOS (Mac Catalyst), inspecting live chat UI trees, or batch-revoking ("Delete for everyone") outgoing messages in a specific chat when SIP/Hardened Runtime blocks process injection and SQLite edits only act locally.
---

# WhatsApp macOS Automation

## Overview

Drive WhatsApp Desktop on macOS (`net.whatsapp.WhatsApp`, Mac Catalyst) safely using native macOS Accessibility (`ApplicationServices` `AXUIElement`) with dynamic `AXIdentifier` lookup, window-relative viewport bounds, condition-based retries, and strict chat/sender guards—without brittle screen-coordinate clicking or local database corruption.

## When to Use

- Batch-revoking (`Delete for everyone`) outgoing messages in one specific WhatsApp chat on macOS
- Inspecting or automating WhatsApp Mac Catalyst UI when:
  - Direct SQLite edits (`ChatStorage.sqlite`) fail because server revoke stanzas are never sent
  - LLDB/Frida attachment fails due to macOS Hardened Runtime + SIP
  - Siri `Intents.appex` only exposes search/send/call intents (no message deletion)

## Core Pattern

### ❌ Naive Approach (Fails on Mac Catalyst)
- Hardcoding child index paths like `[0,0,1,2,1,0,1,1]` (shifts to index `2` whenever the floating `"Go to most recent message"` button appears)
- Limiting tree search to `maxDepth: 7` (`Toolbar_DeleteButton` lives at depth 8; `ActionSheet_TitleLabel` lives at depth 9)
- Firing `AXPress` once immediately after a menu/popover appears (Catalyst drops actions during slide-in animations)
- Hardcoding screen Y coordinates or calling `AXShowMenu` on rows clipped under `WDSNavigationBar`

### ✅ Resilient Pattern (`scripts/whatsapp-revoke.swift`)
```bash
# Preview outgoing messages in a chat without deleting:
swift ~/.agents/skills/whatsapp-macos-automation/scripts/whatsapp-revoke.swift --chat "<Contact Name>" --dry-run

# Delete eligible outgoing messages for everyone (optional --limit N):
swift ~/.agents/skills/whatsapp-macos-automation/scripts/whatsapp-revoke.swift --chat "<Contact Name>" --limit 20
```

Each iteration enforces five invariants before any action:
1. **Chat lock:** `NavigationBar_HeaderViewButton == targetChat` and `ChatMessagesTableView == "Messages in chat with \(targetChat)"`.
2. **Sender & state lock:** `AXIdentifier == "WAMessageBubbleTableViewCell"`, description contains `"Your message,"` and `"Sent to \(targetChat)"`, excludes `"Received from"` and `"You deleted this message"`.
3. **Dynamic viewport guard:** Computes `safeMinY` below `WDSNavigationBar` and `safeMaxY` above the compose bar from live element frames (works on any monitor/window size); calls `AXScrollUpByPage` on `ChatMessagesTableView` when needed.
4. **Condition-based retry:** Retries `AXPress` every `0.35s–0.4s` across all 4 transitions (`AXShowMenu` → `Delete` menu item → `Toolbar_DeleteButton` with `1 Selected` → `Delete for everyone` inside `Delete message?` popover).
5. **Fail-closed eligibility:** If `"Delete for everyone"` is absent (message >60h old), cancels the popover and selection—never clicks `"Delete for me"`, `"Clear chat"`, or `"Delete chat"`.

## Quick Reference

| UI Element | `AXIdentifier` / Role | Lookup / Action |
|---|---|---|
| Main Window | `SceneWindow` (`AXWindow`) | Root window for `net.whatsapp.WhatsApp` |
| Active Chat Header | `NavigationBar_HeaderViewButton` | Verify `label == targetChat` before every step |
| Message List | `ChatMessagesTableView` | `AXScrollUpByPage` to load earlier messages |
| Message Bubble | `WAMessageBubbleTableViewCell` | `kAXShowMenuAction` when inside dynamic viewport |
| Context Menu Delete | `AXMenuItem` (`label == "Delete"`) | `kAXPressAction` until `1 Selected` appears |
| Selection Counter | `Toolbar_SelectedMessageCount` | Must equal `"1 Selected"` before deleting |
| Toolbar Delete | `Toolbar_DeleteButton` | Search to `maxDepth >= 14`; `kAXPressAction` |
| Confirmation Popover | `ActionSheet_TitleLabel` (`"Delete message?"`) | Press `"Delete for everyone"` (`AXButton`) only |

## Common Mistakes

| Mistake | What Breaks | Fix |
|---|---|---|
| Hardcoded toolbar path `[0,0,1,2,1,0,1]` | Breaks when `"Go to most recent message"` button appears | Search by `AXIdentifier` (`maxDepth: 14`) |
| Single `AXPress` on menu/popover | Catalyst animation ignores first press | Poll target state; re-press every `0.35s–0.4s` |
| Selecting old + new messages together | One message >60h hides `"Delete for everyone"` for entire batch | Delete 1 message at a time (`1 Selected`) |
| Stripping Unicode bidi marks skipped | `\u{200E}`, `\u{200F}`, `\u{202F}` break string comparisons | Normalize all AX strings before matching |
