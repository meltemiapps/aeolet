import AppKit
import SwiftUI

/// The menu bar. Message commands act on the conversation selected in the front viewer window.
struct MailCommands: Commands {
    @ObservedObject var app: AppModel
    @FocusedObject private var window: MailWindowModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { newMessage() }
                .keyboardShortcut("n")
                .disabled(app.accounts.isEmpty || app.isLocked)
            Button("New Viewer Window") { openWindow(id: WindowID.main) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandMenu("Mailbox") {
            Button("Get New Mail") { Task { await window?.refresh(); await MailWatcher.shared.check() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window?.mailbox == nil || app.isLocked)
            Button("Search Mail") { TextInput.beginSearch() }
                .keyboardShortcut("f")
                .disabled(window?.mailbox == nil || app.isLocked)
        }

        CommandMenu("Message") {
            Group {
                Button("Reply") { window?.compose(.reply) }
                    .keyboardShortcut("r")
                Button("Reply All") { window?.compose(.replyAll) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forward") { window?.compose(.forward) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            .disabled(!(window?.canReply ?? false) || app.isLocked)

            Divider()

            Group {
                // Single-key and ⌘⌫ shortcuts must still type and delete while a text field is being edited.
                Button("Archive") {
                    if !TextInput.forward("e") { Task { await window?.archive() } }
                }
                .keyboardShortcut("e", modifiers: [])
                Button("Move to Bin") {
                    if !TextInput.forwardDeleteToLineStart() { Task { await window?.trash() } }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(!(window?.hasThread ?? false) || app.isLocked)

            Group {
                Button(window?.selectedSummary?.isUnread == true ? "Mark as Read" : "Mark as Unread") {
                    Task { await window?.toggleRead() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Button(window?.selectedSummary?.isStarred == true ? "Remove Star" : "Star") {
                    Task { await window?.toggleStar() }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Report Spam") { Task { await window?.markSpam() } }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("Open in New Window") { window?.openInNewWindow() }
                    .keyboardShortcut("o")
            }
            .disabled(window?.selectedSummary == nil || app.isLocked)
        }
    }

    private func newMessage() {
        guard let account = window?.account ?? app.currentAccount ?? app.accounts.first else { return }
        openWindow(id: WindowID.compose, value: ComposeRegistry.register(.new, account: account))
    }
}

/// Helpers for commands whose shortcuts would otherwise take keys away from text being typed.
@MainActor
enum TextInput {
    private static var editor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    /// Types the character into the focused text field, if there is one. Returns true when it did.
    static func forward(_ text: String) -> Bool {
        guard let editor, editor.isEditable else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    static func forwardDeleteToLineStart() -> Bool {
        guard let editor, editor.isEditable else { return false }
        editor.deleteToBeginningOfLine(nil)
        return true
    }

    /// Puts the cursor in the front window's toolbar search field.
    static func beginSearch() {
        guard let toolbar = NSApp.keyWindow?.toolbar else { return }
        if let search = toolbar.items.compactMap({ $0 as? NSSearchToolbarItem }).first {
            search.beginSearchInteraction()
            return
        }
        // Older layouts host a plain search field in the toolbar.
        for item in toolbar.items {
            if let field = item.view as? NSSearchField ?? item.view?.firstSubview(of: NSSearchField.self) {
                field.window?.makeFirstResponder(field)
                return
            }
        }
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for view in subviews {
            if let match = view as? T ?? view.firstSubview(of: type) { return match }
        }
        return nil
    }
}
