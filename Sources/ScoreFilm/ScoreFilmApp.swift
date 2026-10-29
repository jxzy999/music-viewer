import SwiftUI
import AppKit
import ScoreCore
import ScoreMedia
import OSLog
import Darwin
import Dispatch

@main
struct ScoreFilmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1360, height: 840)
        .commands { WorkspaceCommands() }
        Settings { CreditsView().frame(width: 500, height: 360) }
    }
}

struct SessionFocusKey: FocusedValueKey { typealias Value = WorkspaceSession }
extension FocusedValues { var workspace: WorkspaceSession? { get { self[SessionFocusKey.self] } set { self[SessionFocusKey.self] = newValue } } }

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) var session
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建工作窗口") { openWindow(id: "workspace") }.keyboardShortcut("n").disabled(SessionRegistry.shared.isTerminating)
            Button("打开曲谱或工程…") { session?.openPanel() }.keyboardShortcut("o").disabled(SessionRegistry.shared.isTerminating)
            Button("返回首页与示例库") { session?.returnHome() }.keyboardShortcut("h", modifiers: [.command,.shift]).disabled(session?.project == nil || SessionRegistry.shared.isTerminating)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存工程") { session?.save() }.keyboardShortcut("s").disabled(session?.project == nil)
            Button("另存为…") { session?.save(asNew: true) }.keyboardShortcut("s", modifiers: [.command,.shift]).disabled(session?.project == nil)
            Divider()
            Button("导出影片…") { session?.exportPanel() }.keyboardShortcut("e").disabled(session?.ready != true)
        }
        CommandMenu("演奏") {
            Button(session?.transport.isPlaying == true ? "暂停" : "播放") { session?.togglePlayback() }.keyboardShortcut(.space, modifiers: []).disabled(session?.ready != true)
            Button("停止") { session?.transport.stop() }.keyboardShortcut(".")
            Button("重新准备演奏") { session?.prepare() }.disabled(session?.project == nil || session?.isBusy == true)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "local.scorefilm.mac", category: "Documents")
    private var terminationSignal: (any DispatchSourceSignal)?
    private var terminationTask: Task<Void, Never>?
    private var readyToTerminate = false
    private func installTerminationSignal() {
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Logger(subsystem: "local.scorefilm.mac", category: "Documents").info("Received termination request")
                NSApp.terminate(nil)
            }
        }
        source.resume(); terminationSignal = source
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application ready")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Finder can send documents before SwiftUI finishes installing @State.
        Task { @MainActor in
            await Task.yield()
            installTerminationSignal()
            SessionRegistry.shared.applicationReady = true
            SessionRegistry.shared.openPendingFiles()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Received URL open: \(urls.count, privacy: .public) items")
        SessionRegistry.shared.openExternal(urls)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        logger.info("Received file open: \(filenames.count, privacy: .public) items")
        SessionRegistry.shared.openExternal(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !SessionRegistry.shared.isTerminating else { return false }
        if !flag, let newWindow = SessionRegistry.shared.newWindow { newWindow(); return false }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        guard terminationTask == nil else { return .terminateCancel }
        SessionRegistry.shared.beginTermination()
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await SessionRegistry.shared.finish()
                readyToTerminate = true
                sender.terminate(nil)
            }
            catch {
                terminationTask = nil
                let alert = NSAlert(); alert.messageText = "尚未退出"
                alert.informativeText = "恢复副本未能保存。请先另存工程，再退出。\n\(error.localizedDescription)"
                alert.addButton(withTitle: "返回应用"); alert.runModal()
            }
        }
        // Do not enter AppKit's nested modal loop while a MainActor caller is
        // still running. Cleanup re-enters terminate only when it can finish.
        return .terminateCancel
    }
}
