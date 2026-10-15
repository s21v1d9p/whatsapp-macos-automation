# WhatsApp macOS Automation (`whatsapp-macos-automation`)

Reusable skill and native Swift CLI for safely inspecting and automating **WhatsApp Desktop on macOS** (`net.whatsapp.WhatsApp`, Mac Catalyst) via the macOS Accessibility (`ApplicationServices` `AXUIElement`) API—including batch-revoking (`Delete for everyone`) outgoing messages in a specific chat.

---

## Why This Exists

When automating WhatsApp on macOS, common approaches fail:

1. **Direct SQLite edits (`ChatStorage.sqlite`) only delete locally ("Delete for me")** — revoking a message for everyone requires sending a signed, Signal-encrypted `REVOKE` stanza over WhatsApp's live Noise/XMPP session.
2. **Process injection (`lldb` / `frida`) is blocked by macOS SIP & Hardened Runtime** — `WhatsApp.app` is signed with Hardened Runtime + App Sandbox and lacks the `get-task-allow` entitlement.
3. **Siri / AppleScript lacks delete coverage** — `Intents.appex` only exposes `INSearchForMessagesIntent`, `INSendMessageIntent`, `INSetMessageAttributeIntent`, and call intents.
4. **Naive Accessibility scripts break on Mac Catalyst**:
   - Floating UI controls (such as `"Go to most recent message"`) dynamically shift sibling indices (`WAToolbar` moves from `[0,0,1,2,1,0,1]` to `[0,0,1,2,1,0,2]`).
   - Catalyst ignores single `AXPress` calls fired while context menus, toolbars, or confirmation popovers are animating in.
   - Calling `AXShowMenu` on message cells partially obscured beneath `WDSNavigationBar` silently fails.
   - Selecting an older (>60h) message in a multi-select batch hides `"Delete for everyone"` for the entire selection.

This skill provides the verified Mac Catalyst `AXIdentifier` map and a self-contained, zero-dependency Swift CLI (`scripts/whatsapp-revoke.swift`) that solves all four issues.

---

## Installation

### Option 1: Install via `skills.sh`
```bash
npx skills add s21v1d9p/whatsapp-macos-automation
```

### Option 2: Clone & install locally
```bash
git clone https://github.com/s21v1d9p/whatsapp-macos-automation.git
cd whatsapp-macos-automation
./install.sh
```
`./install.sh` links the skill into `~/.agents/skills/whatsapp-macos-automation` (and any additional directories passed via `SKILL_TARGET_DIRS`).

---

## Prerequisites

1. **macOS** with **WhatsApp Desktop** (`/Applications/WhatsApp.app`) installed and running.
2. **Xcode Command Line Tools** (`swift` available on `PATH`).
3. **Accessibility Permission** granted to your terminal app (`System Settings → Privacy & Security → Accessibility`).

---

## Usage

### 1. Dry-Run (Preview Eligible Outgoing Messages Without Deleting)
```bash
swift ~/.agents/skills/whatsapp-macos-automation/scripts/whatsapp-revoke.swift \
  --chat "<Contact Name>" \
  --dry-run
```

### 2. Batch "Delete for Everyone" in a Specific Chat
```bash
# Delete all eligible outgoing messages in "<Contact Name>"
swift ~/.agents/skills/whatsapp-macos-automation/scripts/whatsapp-revoke.swift \
  --chat "<Contact Name>"

# Or cap the maximum number of deletions in one run
swift ~/.agents/skills/whatsapp-macos-automation/scripts/whatsapp-revoke.swift \
  --chat "<Contact Name>" \
  --limit 20
```

---

## Safety Guarantees

Every iteration of `scripts/whatsapp-revoke.swift` enforces five strict invariants:

1. **Exact Chat Lock:** Verifies `NavigationBar_HeaderViewButton == <Contact Name>` and `ChatMessagesTableView == "Messages in chat with <Contact Name>"` before every action; aborts immediately if the active chat changes.
2. **Outgoing Sender Lock:** Only acts on `WAMessageBubbleTableViewCell` elements whose normalized `AXDescription` starts with `"Your message,"` (or contains `"\nYour message,"`) and includes `"Sent to <Contact Name>"`, never `"Received from <Contact Name>"`.
3. **Dynamic Window-Relative Viewport Guard:** Computes `safeMinY` below `WDSNavigationBar` and `safeMaxY` above the compose bar from live window geometry (works on any display size or window position) and scrolls up via `AXScrollUpByPage` when needed.
4. **Condition-Based Animation Retry:** Polls for the target UI state and retries `AXPress` every `0.35s–0.4s` across all 4 transitions (`AXShowMenu` → `Delete` menu item → `Toolbar_DeleteButton` with `1 Selected` → `Delete for everyone`).
5. **Fail-Closed Eligibility:** Inspects each message individually (`1 Selected`). If WhatsApp does not offer `"Delete for everyone"` (e.g., messages older than WhatsApp's ~60-hour revoke window), the script cancels the popover and skips the message—it **never** clicks `"Delete for me"`, `"Clear chat"`, or `"Delete chat"`.

---

## License

MIT — see [LICENSE](LICENSE).
