import SwiftUI
import AppKit

/// SwiftUI owns the workspace. This bridge only delays NSWindow's close until
/// the workspace has saved recovery data and stopped its own workers.
struct WorkspaceWindowBridge: NSViewRepresentable {
    let session: WorkspaceSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.update(session: session, window: view.window)
        view.window?.isDocumentEdited = session.dirty
        view.window?.representedURL = session.savedURL
    }
    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class AttachmentView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }

    // NSObject selector forwarding is nonisolated; NSWindowDelegate's UI
    // callbacks and all state transitions remain explicitly on MainActor.
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var previous: (any NSWindowDelegate)?
        @MainActor private weak var window: NSWindow?
        @MainActor private weak var session: WorkspaceSession?
        @MainActor private var mayClose = false
        @MainActor private var pending = false
        @MainActor init(session: WorkspaceSession) { self.session = session }
        @MainActor func update(session: WorkspaceSession, window: NSWindow?) {
            if self.session !== session {
                if let old = self.session { SessionRegistry.shared.remove(old); old.window = nil }
                self.session = session
            }
            attach(window)
            if let window {
                session.window = window
                SessionRegistry.shared.add(session)
            }
        }
        @MainActor func attach(_ window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach(); self.window = window; session?.window = window; previous = window.delegate; window.delegate = self
            if let session { SessionRegistry.shared.add(session) }
        }
        @MainActor func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            if session?.window === window { session?.window = nil }
            window = nil
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
        @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool {
            if mayClose { return true }
            guard !pending, let session else { return false }
            guard previous?.windowShouldClose?(sender) ?? true else { return false }
            pending = true
            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender else { return }
                do { try await session.finishBeforeClosing(); session.commitClosing(); mayClose = true; sender.performClose(nil) }
                catch { pending = false; session.error = error.localizedDescription }
            }
            return false
        }
        @MainActor func windowWillClose(_ notification: Notification) { previous?.windowWillClose?(notification) }
    }
}
