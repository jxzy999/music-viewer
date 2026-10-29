import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import ScoreCore
import ScoreMedia
import OSLog

@MainActor @Observable
final class WorkspaceSession {
    var project: ProjectFile?
    var scene: ScenePlan?
    var sceneVersion = UUID()
    var plan: PerformancePlan?
    var layout: LayoutSnapshot?
    var audio: RenderedAudio?
    let transport = AudioTransport()
    var status = "导入曲谱，开始制作演奏影片"
    var progress = 0.0
    var isBusy = false
    var error: String?
    var savedURL: URL?
    var dirty = false
    var needsPreparation = true
    var exportResult: ExportResult?
    var selectedPart: String?
    var reportOpen = false
    var recoveryURL: URL?
    private(set) var isBuiltInExample = false
    private(set) var isLibraryProject = false
    var libraryProjects: [UserProjectSummary] = []
    var libraryError: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var openingURL: URL?
    private(set) var isClosing = false
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var autosaveJob: Task<Void, Never>?
    @ObservationIgnored private var cancelledJobs: [Task<Void, Never>] = []
    @ObservationIgnored private var closingTask: Task<Void, any Error>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var performedValidation = false
    @ObservationIgnored private let audioRenderer = OfflineAudioRenderer()
    @ObservationIgnored private let videoExporter = VideoExporter()
    @ObservationIgnored private let recoveryWorkspaceID = UUID()
    @ObservationIgnored private var recoverySourceURL: URL?
    @ObservationIgnored private var layoutKey: String?
    @ObservationIgnored private var audioKey: String?
    @ObservationIgnored private var jobID = UUID()
    @ObservationIgnored private var projectRevision = UUID()
    @ObservationIgnored private var readAndParseSeconds = 0.0
    @ObservationIgnored private var preparationMetrics: [String: Double] = [:]
    @ObservationIgnored private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreFilm-\(UUID().uuidString)", isDirectory: true)

    init() {
        recoveryURL = RecoveryStore.latest()
    }

    var title: String { project?.score.title ?? "Music Viewer" }
    private var suggestedFileName: String {
        let value = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " - ")
        return value.isEmpty ? "Music Viewer" : String(value.prefix(80))
    }
    var ready: Bool { scene != nil && audio != nil && !isBusy && !needsPreparation && !isClosing }
    var documentSubtitle: String {
        if isBuiltInExample { return "内置示例 · 修改设置后自动创建副本" }
        if isLibraryProject { return dirty ? "我的工程 · 正在自动保存…" : "我的工程 · 已自动保存" }
        return dirty ? "尚未保存 · 已启用恢复副本" : (savedURL?.lastPathComponent ?? "乐谱演奏与可视化")
    }

    func refreshLibrary() async {
        do { libraryProjects = try await UserLibrary.store.projects(); libraryError = nil }
        catch { libraryError = "无法读取我的工程：\(error.localizedDescription)" }
        recoveryURL = RecoveryStore.latest()
    }

    func openExample(_ example: ExampleScore) {
        open((Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Resources/Examples/\(example.filename)"), example: true)
    }

    func returnHome() {
        guard !isClosing, project != nil else { return }
        let snapshot = dirty ? project : nil
        let managed = isLibraryProject
        let workspaceID = recoveryWorkspaceID
        cancel(); transport.stop()
        let autosave = autosaveJob; autosave?.cancel(); autosaveJob = nil
        let pending = cancelledJobs; cancelledJobs.removeAll()
        let id = UUID(); jobID = id; isBusy = true; status = "正在保存并返回首页…"
        job = Task { [self] in
            do {
                for task in pending { await task.value }
                await autosave?.value
                if let snapshot { _ = try await Self.persist(snapshot, managed: managed, workspaceID: workspaceID) }
                try Task.checkCancellation(); guard id == jobID, !isClosing else { return }
                transport.unload()
                try? FileManager.default.removeItem(at: cache)
                projectRevision = UUID()
                project = nil; scene = nil; plan = nil; layout = nil; audio = nil
                savedURL = nil; selectedPart = nil; openingURL = nil; recoverySourceURL = nil
                reportOpen = false
                isBuiltInExample = false; isLibraryProject = false
                layoutKey = nil; audioKey = nil; exportResult = nil
                dirty = false; needsPreparation = true; isBusy = false; progress = 0; error = nil
                status = "选择一首示例，或打开你的曲谱"
                await refreshLibrary()
            } catch { finishError(error, id: id) }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入曲谱或打开工程"
        panel.allowedContentTypes = ["musicxml", "xml", "mxl", "scorefilm"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }

    func openSample() {
        open((Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Resources/PaperAndLight.scorefilm"), example: true)
    }

    func restoreRecovery() {
        guard let url = recoveryURL else { return }
        open(url, recovered: true)
    }

    func open(_ url: URL, example: Bool = false, recovered: Bool = false) {
        guard !isClosing else { return }
        if !example && !recovered, let owner = SessionRegistry.shared.owner(of: url) {
            owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        openingURL = !example && !recovered ? url : nil
        let previous = dirty ? project : nil
        let previousManaged = isLibraryProject
        let recoveryWorkspaceID = self.recoveryWorkspaceID
        cancel(); transport.stop()
        let id = UUID(); jobID = id; isBusy = true; error = nil; progress = 0
        status = "正在读取曲谱…"
        job = Task {
            do {
                let readBegan = ProcessInfo.processInfo.systemUptime
                if let previous { _ = try await Self.persist(previous, managed: previousManaged, workspaceID: recoveryWorkspaceID) }
                let loaded = try await Task.detached(priority: .userInitiated) { try ProjectFile.load(url) }.value
                guard id == jobID else { return }
                readAndParseSeconds = ProcessInfo.processInfo.systemUptime - readBegan
                var configured = loaded
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "--fps"), args.indices.contains(i + 1), let fps = Int(args[i + 1]), [30,60].contains(fps) { configured.settings.export.fps.n = fps }
                if let i = args.firstIndex(of: "--preset"), args.indices.contains(i + 1), ["clear-score","cinematic-paper"].contains(args[i + 1]) { configured.settings.visual.preset = args[i + 1] }
                project = configured; selectedPart = loaded.score.parts.first?.id
                projectRevision = UUID()
                isBuiltInExample = example
                isLibraryProject = !example && UserLibrary.contains(url)
                savedURL = !example && !recovered && url.pathExtension.lowercased() == "scorefilm" ? url : nil
                openingURL = nil
                recoverySourceURL = recovered ? url : nil
                dirty = !example && (recovered || savedURL == nil)
                scene = nil; plan = nil; layout = nil; audio = nil; layoutKey = nil; audioKey = nil
                isBusy = false
                if dirty { scheduleAutosave() }
                prepare()
            } catch { finishError(error, id: id) }
        }
    }

    func prepare() {
        guard !isClosing, let snapshot = project else { return }
        cancel(); transport.stop()
        let id = UUID(); jobID = id; isBusy = true; needsPreparation = true; progress = 0; error = nil
        job = Task {
            do {
                let began = ProcessInfo.processInfo.systemUptime
                var checkpoint = began
                var metrics: [String: Double] = ["readAndParseSeconds":readAndParseSeconds]
                status = "正在解析演奏关系…"
                let compiled = try await Task.detached(priority: .userInitiated) { try PerformanceCompiler.compile(snapshot) }.value
                try Task.checkCancellation()
                guard id == jobID else { return }
                metrics["compileSeconds"] = ProcessInfo.processInfo.systemUptime - checkpoint
                checkpoint = ProcessInfo.processInfo.systemUptime
                plan = compiled
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let newLayoutKey = ProjectFile.digest(snapshot.score.originalXML + (try encoder.encode(snapshot.settings.layout)))
                let engraving: LayoutSnapshot
                if layoutKey == newLayoutKey, let layout { engraving = layout; metrics["layoutCacheHit"] = 1 }
                else {
                    status = "正在排版并定位符头…"; progress = 0.08
                    engraving = try await NotationEngine().layout(score: snapshot.score, settings: snapshot.settings.layout)
                    try Task.checkCancellation(); guard id == jobID else { return }
                    layout = engraving
                    if let folder = validationFolder {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try JSONEncoder().encode(engraving.mappingIssues).write(to: folder.appendingPathComponent("mapping-issues.json"))
                    }
                    guard engraving.missingNoteIDs.isEmpty else { throw ScoreError.unsupported("有 \(engraving.missingNoteIDs.count) 个符头未能可靠定位，已停止演奏：\(engraving.missingNoteIDs.prefix(4).joined(separator: "、"))") }
                    layout = engraving; layoutKey = newLayoutKey
                    metrics["layoutCacheHit"] = 0
                }
                metrics["layoutSeconds"] = ProcessInfo.processInfo.systemUptime - checkpoint
                checkpoint = ProcessInfo.processInfo.systemUptime
                let newScene = await Task.detached(priority: .userInitiated) { ScenePlan(layout: engraving, performance: compiled, settings: snapshot.settings) }.value
                try Task.checkCancellation(); guard id == jobID else { return }
                scene = newScene; sceneVersion = UUID()
                metrics["sceneSeconds"] = ProcessInfo.processInfo.systemUptime - checkpoint
                checkpoint = ProcessInfo.processInfo.systemUptime
                var soundSettings = snapshot.settings
                soundSettings.visual = ProjectSettings.defaults(for: snapshot.score).visual
                soundSettings.camera = ProjectSettings.defaults(for: snapshot.score).camera
                soundSettings.layout = ProjectSettings.defaults(for: snapshot.score).layout
                let newAudioKey = ProjectFile.digest(snapshot.score.originalXML + (try encoder.encode(soundSettings)))
                let rendered: RenderedAudio
                if audioKey == newAudioKey, let audio { rendered = audio; metrics["audioCacheHit"] = 1 }
                else {
                    status = "正在合成乐器声音…"; progress = 0.2
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    let target = cache.appendingPathComponent("\(UUID().uuidString).caf")
                    rendered = try await audioRenderer.render(plan: compiled, project: snapshot, to: target) { [weak self] value in
                        Task { @MainActor in guard let self, self.jobID == id else { return }; self.progress = 0.2 + value * 0.8 }
                    }
                    if Task.isCancelled || id != jobID { try? FileManager.default.removeItem(at: rendered.url); throw CancellationError() }
                    if let old = audio?.url { try? FileManager.default.removeItem(at: old) }
                    audio = rendered; audioKey = newAudioKey
                    metrics["audioCacheHit"] = 0
                }
                try Task.checkCancellation(); guard id == jobID else { return }
                try transport.load(rendered)
                metrics["audioSeconds"] = ProcessInfo.processInfo.systemUptime - checkpoint
                metrics["totalPrepareSeconds"] = ProcessInfo.processInfo.systemUptime - began
                preparationMetrics = metrics
                status = "已准备 · \(compiled.notes.count) 个发声音符 · \(engraving.pages.count) 页"
                progress = 1; isBusy = false; needsPreparation = false
                await runRequestedValidationIfNeeded()
            } catch { finishError(error, id: id) }
        }
    }

    func edit(_ mutation: (inout ProjectSettings) -> Void) {
        guard !isBusy, var value = project else { return }
        let previous = value.settings
        mutation(&value.settings)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard (try? encoder.encode(previous)) != (try? encoder.encode(value.settings)) else { return }
        if isBuiltInExample {
            value = value.userCopy()
            isBuiltInExample = false; isLibraryProject = true; savedURL = nil
        }
        projectRevision = UUID()
        var comparable = previous
        comparable.visual = value.settings.visual; comparable.camera = value.settings.camera
        comparable.export.width = value.settings.export.width; comparable.export.height = value.settings.export.height
        let visualOnly = ready && (try? encoder.encode(comparable)) == (try? encoder.encode(value.settings))
        project = value; dirty = true
        scheduleAutosave()
        if visualOnly, let layout { updateVisuals(value, layout: layout) }
        else { transport.pause(); prepare() }
    }

    private func updateVisuals(_ snapshot: ProjectFile, layout: LayoutSnapshot) {
        cancel()
        let id = UUID(); jobID = id; isBusy = true; error = nil; status = "正在更新画面…"
        job = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let plan = try PerformanceCompiler.compile(snapshot)
                    return ScenePlan(layout: layout, performance: plan, settings: snapshot.settings)
                }.value
                try Task.checkCancellation(); guard id == jobID else { return }
                plan = result.performance; scene = result; sceneVersion = UUID()
                isBusy = false; needsPreparation = false
                status = transport.isPlaying ? "画面已更新 · 正在演奏" : "画面已更新"
            } catch {
                guard id == jobID else { return }
                transport.pause(); finishError(error, id: id)
            }
        }
    }

    func cancel() {
        if let job { job.cancel(); cancelledJobs.append(job) }
        job = nil; jobID = UUID()
        isBusy = false; progress = 0
        status = project == nil ? "导入曲谱，开始制作演奏影片" : "操作已取消，可以重新准备"
    }

    func togglePlayback() {
        guard ready else { return }
        if transport.isPlaying { transport.pause() }
        else { do { try transport.play() } catch { self.error = "无法开始声音播放：\(error.localizedDescription)" } }
    }

    func save(asNew: Bool = false) {
        guard !isClosing, let current = project else { return }
        let project = isBuiltInExample ? current.userCopy() : current
        if let savedURL, !asNew { write(project, to: savedURL); return }
        let panel = NSSavePanel()
        panel.title = "保存演奏工程"; panel.nameFieldStringValue = suggestedFileName + ".scorefilm"
        panel.allowedContentTypes = [UTType(filenameExtension: "scorefilm") ?? .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.write(project, to: url)
        }
    }

    private func write(_ value: ProjectFile, to url: URL) {
        guard SessionRegistry.shared.owner(of: url, excluding: self) == nil else { error = "此文件已在另一个窗口打开，请切换到该窗口保存，或选择其他文件名。"; return }
        if UserLibrary.contains(url) {
            let previous = autosaveJob; previous?.cancel()
            let revision = projectRevision
            autosaveJob = Task {
                await previous?.value
                do {
                    let saved = try await UserLibrary.store.save(value)
                    guard !Task.isCancelled, projectRevision == revision else { return }
                    savedURL = saved; project?.sourceURL = saved; dirty = false
                    status = "我的工程已保存"
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            return
        }
        do {
            try value.save(to: url); autosaveJob?.cancel(); savedURL = url; dirty = false; status = "已保存 · \(url.lastPathComponent)"
            var saved = value; saved.sourceURL = url; project = saved
            isBuiltInExample = false; isLibraryProject = UserLibrary.contains(url); projectRevision = UUID()
            RecoveryStore.remove(value.id, workspaceID: recoveryWorkspaceID)
            if let recoverySourceURL { RecoveryStore.removeRecovery(at: recoverySourceURL); self.recoverySourceURL = nil }
        }
        catch { self.error = error.localizedDescription }
    }

    func exportPanel() {
        guard ready else { return }
        transport.pause()
        let panel = NSSavePanel(); panel.title = "导出演奏影片"
        panel.nameFieldStringValue = suggestedFileName + ".mp4"; panel.allowedContentTypes = [.mpeg4Movie]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func runMediaDiagnostics(to folder: URL, audioOnly: Bool = false) {
        performedValidation = true
        cancel(); transport.stop()
        let id = UUID(); jobID = id; isBusy = true; error = nil; status = "正在验证采样与画面同步…"
        job = Task { [self] in
            do {
                if audioOnly { try await AudioDiagnostics.run(to: folder) }
                else {
                    let args = ProcessInfo.processInfo.arguments
                    let fps = args.firstIndex(of: "--fps").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 60
                    try await MediaDiagnostics.run(to: folder, fps: fps) { [weak self] value in
                        Task { @MainActor in guard let self, self.jobID == id else { return }; self.progress = value }
                    }
                }
                guard id == jobID else { return }
                isBusy = false; status = audioOnly ? "音频边界检查完成" : "同步验证素材已生成，等待解码检查"; progress = 1
                try Data("completed".utf8).write(to: folder.appendingPathComponent("completed.txt"))
            } catch { finishError(error, id: id) }
        }
    }

    func export(to destination: URL) {
        guard let scene, let audio else { return }
        cancel(); transport.pause()
        let id = UUID(); jobID = id; isBusy = true; error = nil; status = "正在导出演奏影片…"
        job = Task {
            do {
                let result = try await videoExporter.export(scene: scene, audio: audio, to: destination) { [weak self] value in
                    Task { @MainActor in guard let self, self.jobID == id else { return }; self.progress = value }
                }
                guard id == jobID else { return }
                exportResult = result; isBusy = false; progress = 1
                status = "导出完成 · \(result.frameCount) 帧 · 用时 \(Int(result.elapsed)) 秒"
                if let folder = validationFolder {
                    let report: [String: Any] = ["frameCount": result.frameCount, "duration": result.duration, "elapsedSeconds": result.elapsed, "output": result.url.path]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("export.json"))
                }
            } catch { finishError(error, id: id) }
        }
    }

    private func finishError(_ value: any Error, id: UUID) {
        guard id == jobID else { return }
        openingURL = nil
        isBusy = false
        if value is CancellationError { status = "操作已取消" }
        else { error = value.localizedDescription; status = "需要处理的问题见详情"; writeValidationFailureIfNeeded(value) }
    }

    private func scheduleAutosave() {
        autosaveJob?.cancel()
        guard let snapshot = project, dirty else { return }
        let workspaceID = recoveryWorkspaceID
        let managed = isLibraryProject
        let revision = projectRevision
        autosaveJob = Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
                let url = try await Self.persist(snapshot, managed: managed, workspaceID: workspaceID)
                guard !Task.isCancelled, projectRevision == revision, project?.id == snapshot.id else { return }
                if let url { savedURL = url; project?.sourceURL = url; dirty = false }
            } catch is CancellationError {} catch {
                guard projectRevision == revision else { return }
                self.error = "自动保存失败：\(error.localizedDescription)"
            }
        }
    }

    private static func persist(_ project: ProjectFile, managed: Bool, workspaceID: UUID) async throws -> URL? {
        if managed { return try await UserLibrary.store.save(project) }
        let worker = Task.detached(priority: .utility) { try RecoveryStore.save(project, workspaceID: workspaceID) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        return nil
    }

    private var validationFolder: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "--validate"), arguments.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
    }

    private func runRequestedValidationIfNeeded() async {
        guard !performedValidation, let folder = validationFolder, let scene, let audio, let project, !FileManager.default.fileExists(atPath: folder.appendingPathComponent("report.json").path) else { return }
        performedValidation = true
        let invocation = jobID
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report: [String: Any] = ["title": title, "sourceSHA256": ProjectFile.digest(project.score.originalXML), "noteCount": project.score.noteCount, "anchors": scene.layout.anchors.count, "pages": scene.layout.pages.count, "systems": Set(scene.layout.anchors.values.map(\.system)).count, "missingAnchors": scene.layout.missingNoteIDs, "soundingNotes": scene.performance.notes.count, "slurTrails": scene.performance.trails.filter { $0.kind == .slur }.count, "tieTrails": scene.performance.trails.filter { $0.kind == .tie }.count, "musicDuration": scene.performance.duration, "audioDuration": audio.duration, "audioFrames": audio.frameCount, "sampleRate": audio.sampleRate,"preparation":preparationMetrics]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("report.json"))
            try FileManager.default.copyItem(at: audio.url, to: folder.appendingPathComponent("audio.caf"))
            for page in scene.layout.pages { try page.png.write(to: folder.appendingPathComponent("page-\(page.index).png")) }
            try JSONEncoder().encode(Array(scene.layout.anchors.values)).write(to: folder.appendingPathComponent("anchors.json"))
            isBusy = true; status = "正在比较顺序渲染与定位画面…"
            try await FrameVerifier().verify(scene: scene, to: folder)
            try Task.checkCancellation(); guard invocation == jobID else { return }
            isBusy = false
            export(to: folder.appendingPathComponent("sample.mp4"))
        } catch { finishError(error, id: invocation) }
    }

    private func writeValidationFailureIfNeeded(_ error: any Error) {
        guard let folder = validationFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(error.localizedDescription.utf8).write(to: folder.appendingPathComponent("failure.txt"))
    }

    func blockForAppTermination() { isClosing = true }

    func finishBeforeClosing() async throws {
        if closed { return }
        if let closingTask { return try await closingTask.value }
        let work = Task { [self] in
            isClosing = true
            cancel(); transport.pause()
            status = "正在保存并结束后台任务…"
            let pending = cancelledJobs; cancelledJobs.removeAll()
            let autosave = autosaveJob; autosave?.cancel(); autosaveJob = nil
            for task in pending { await task.value }
            await autosave?.value
            if dirty, let snapshot = project {
                let workspaceID = recoveryWorkspaceID
                _ = try await Self.persist(snapshot, managed: isLibraryProject, workspaceID: workspaceID)
            }
        }
        closingTask = work
        do { try await work.value; closingTask = nil }
        catch { closingTask = nil; isClosing = false; status = "恢复副本保存失败，请先另存工程"; throw error }
    }

    func commitClosing() {
        guard !closed else { return }
        transport.shutdown()
        try? FileManager.default.removeItem(at: cache)
        closed = true
    }

    func abortClosing() {
        guard !closed else { return }
        isClosing = false
        status = "已返回工作窗口，可以继续或另存工程"
    }
}

@MainActor @Observable final class SessionRegistry {
    static let shared = SessionRegistry()
    private let logger = Logger(subsystem: "local.scorefilm.mac", category: "Documents")
    private let sessions = NSHashTable<WorkspaceSession>.weakObjects()
    var newWindow: (() -> Void)?
    var applicationReady = false
    private(set) var isTerminating = false
    private var pendingFiles: [URL] = []
    private var waitingForWindow = false
    private var hasPresentedWindow = false
    private var lastExternal: [URL: Date] = [:]
    // Register only the session retained by a mounted window. SwiftUI can
    // construct and discard @State initial values while reconciling views.
    func add(_ session: WorkspaceSession) {
        if isTerminating { session.blockForAppTermination() }
        for old in sessions.allObjects where old !== session && old.window === session.window {
            sessions.remove(old)
        }
        guard !sessions.contains(session) else { return }
        sessions.add(session); hasPresentedWindow = true; waitingForWindow = false
        openPendingFiles()
    }
    func remove(_ session: WorkspaceSession) { sessions.remove(session) }
    func owner(of url: URL, excluding current: WorkspaceSession? = nil) -> WorkspaceSession? {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        return sessions.allObjects.first { session in
            guard session !== current, !session.isClosing, let opened = session.openingURL ?? session.savedURL ?? session.project?.sourceURL else { return false }
            return opened.standardizedFileURL.resolvingSymlinksInPath() == canonical
        }
    }
    func openExternal(_ urls: [URL]) {
        logger.info("Dispatching external open: \(urls.count, privacy: .public) items, \(urls.filter(\.isFileURL).count, privacy: .public) files, \(self.sessions.allObjects.count, privacy: .public) workspaces")
        let now = Date()
        lastExternal = lastExternal.filter { now.timeIntervalSince($0.value) < 2 }
        for url in urls where url.isFileURL && ["musicxml","xml","mxl","scorefilm"].contains(url.pathExtension.lowercased()) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if lastExternal[canonical] != nil { continue }
            lastExternal[canonical] = now; pendingFiles.append(url)
        }
        openPendingFiles()
    }
    func openPendingFiles() {
        guard applicationReady, !isTerminating else { return }
        while let url = pendingFiles.first {
            if let open = owner(of: url) {
                logger.debug("Focusing existing document")
                pendingFiles.removeFirst(); open.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            } else if let blank = sessions.allObjects.first(where: { $0.window != nil && !$0.isClosing && !$0.isBusy && $0.project == nil }) {
                logger.debug("Loading into blank workspace")
                pendingFiles.removeFirst(); blank.open(url)
            } else {
                logger.debug("Waiting for workspace: \(self.waitingForWindow, privacy: .public)")
                if hasPresentedWindow, !waitingForWindow, let newWindow { waitingForWindow = true; newWindow() }
                return
            }
        }
    }
    func beginTermination() {
        isTerminating = true
        for session in sessions.allObjects { session.blockForAppTermination() }
    }
    func finish() async throws {
        beginTermination()
        let open = sessions.allObjects
        do {
            for session in open { try await session.finishBeforeClosing() }
            for session in open { session.commitClosing() }
        } catch {
            for session in open { session.abortClosing() }
            isTerminating = false
            throw error
        }
    }
}

enum RecoveryStore {
    private static let lock = NSLock()
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScoreFilm/Recovery", isDirectory: true) }
    static func save(_ project: ProjectFile, workspaceID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try project.save(to: root.appendingPathComponent(project.id.uuidString + "-" + workspaceID.uuidString + ".scorefilm"))
    }
    static func remove(_ id: UUID, workspaceID: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + "-" + workspaceID.uuidString + ".scorefilm"))
    }
    static func removeRecovery(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL, url.pathExtension == "scorefilm" else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
    static func latest() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "scorefilm" }.max { a, b in
            ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }
}
