import SwiftUI
import AppKit
import ScoreCore
import ScoreMedia

struct WorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var session = WorkspaceSession()
    @State private var routesOpen = false
    @State private var inspectorShown = true
    @State private var began = false
    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HSplitView {
                sidebar.frame(minWidth: 195, idealWidth: 220, maxWidth: 290)
                canvas.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                if inspectorShown, session.project != nil { InspectorView(session: session, routesOpen: $routesOpen).frame(minWidth: 260, idealWidth: 290, maxWidth: 350) }
            }
            Divider()
            TransportBar(session: session)
        }
        .frame(minWidth: 1020, minHeight: 680)
        .navigationTitle(session.title)
        .navigationSubtitle(session.documentSubtitle)
        .focusedSceneValue(\.workspace, session)
        .background(WorkspaceWindowBridge(session: session).frame(width: 0, height: 0))
        .disabled(session.isClosing)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if session.project != nil {
                    Button { session.returnHome() } label: { Label("返回首页", systemImage: "house") }.help("返回首页并保留你的工程")
                }
                Button { session.openPanel() } label: { Label("打开", systemImage: "folder") }.help("打开 MusicXML、MXL 或 Music Viewer 工程")
                Button { session.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }.disabled(session.project == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session.reportOpen = true } label: { Label("曲谱报告", systemImage: "doc.text.magnifyingglass") }.disabled(session.project == nil)
                Button { inspectorShown.toggle() } label: { Label("选项", systemImage: "sidebar.right") }.help("显示或隐藏选项")
                Button { session.exportPanel() } label: { Label("导出影片", systemImage: "square.and.arrow.up") }.disabled(!session.ready)
            }
        }
        .alert("需要处理的问题", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("知道了", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
        .sheet(isPresented: $routesOpen) { RouteEditor(session: session) }
        .sheet(isPresented: $session.reportOpen) { ScoreReport(session: session) }
        .onOpenURL { SessionRegistry.shared.openExternal([$0]) }
        .onChange(of: session.transport.deviceChangeCount) { _, _ in session.status = "声音设备已变化，演奏已暂停；可以继续播放" }
        .onChange(of: session.project == nil) { _, home in if home { routesOpen = false; session.reportOpen = false } }
        .task {
            guard !began else { return }; began = true
            let launchWindow = openWindow
            SessionRegistry.shared.newWindow = { launchWindow(id: "workspace") }
            SessionRegistry.shared.openPendingFiles()
            guard !LaunchArguments.consumed else { return }
            LaunchArguments.consumed = true
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--audio-check"), args.indices.contains(i + 1) { session.runMediaDiagnostics(to: URL(fileURLWithPath: args[i + 1], isDirectory: true), audioOnly: true) }
            else if let i = args.firstIndex(of: "--sync"), args.indices.contains(i + 1) { session.runMediaDiagnostics(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            else if let i = args.firstIndex(of: "--open"), args.indices.contains(i + 1) { session.open(URL(fileURLWithPath: args[i + 1]), example: args.contains("--validate")) }
            else if args.contains("--sample") || args.contains("--validate") { session.openSample() }
        }
    }

    private var sidebar: some View {
        List(selection: $session.selectedPart) {
            Section("曲谱") {
                if let project = session.project {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.score.title).font(.headline).lineLimit(3)
                        if !project.score.composer.isEmpty { Text(project.score.composer).font(.caption).foregroundStyle(.secondary) }
                        Text("\(project.score.parts.first?.measures.count ?? 0) 小节 · \(project.score.noteCount) 音符").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
            } else { Label("首页 · 示例与我的工程", systemImage: "house").foregroundStyle(.secondary) }
            }
            if let project = session.project {
                Section("演奏声部") {
                    ForEach(project.score.parts) { part in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(part.name, systemImage: "music.note")
                            Text("\(part.voices.count) 个声部 · \(part.measures.count) 小节").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(part.id)
                    }
                }
                Section("配器段落") {
                    if project.settings.routes.isEmpty { Text("使用原谱或声部乐器").font(.caption).foregroundStyle(.secondary) }
                    ForEach(project.settings.routes) { route in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.settings.instruments.first { $0.id == route.instrumentId }?.displayName ?? route.instrumentId)
                            Text("\(route.selector.partId) · \(route.selector.voiceId.map { "声部 " + $0 } ?? "全部声部")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("编辑配器段落…") { routesOpen = true }.buttonStyle(.borderless).disabled(session.isBusy)
                }
            }
        }.listStyle(.sidebar)
    }

    private var canvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let scene = session.scene {
                ScorePreview(scene: scene, transport: session.transport) { session.error = $0 }
                    .aspectRatio(CGFloat(scene.settings.export.width) / CGFloat(scene.settings.export.height), contentMode: .fit).id(session.sceneVersion)
            } else if session.project == nil {
                HomeView(session: session)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "music.note.list").font(.system(size: 52, weight: .light)).foregroundStyle(.teal)
                    VStack(spacing: 8) {
                        Text(session.project == nil ? "让曲谱成为影片" : "正在准备演奏画面").font(.title2.weight(.semibold))
                        Text("导入曲谱，选择乐器与画面风格，播放并导出带声音的影片。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    }
                    if !session.isBusy { Button("重新准备") { session.prepare() } }
                }.padding(36)
            }
            if session.isBusy {
                VStack { Spacer(); HStack(spacing: 12) {
                    ProgressView(value: session.progress).frame(width: 150)
                    Text(session.status).font(.caption).lineLimit(1)
                    Button("取消") { session.cancel() }.controlSize(.small)
                }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(18) }
            }
        }
        .overlay(alignment: .topLeading) {
            if session.scene != nil {
                Text(session.project?.settings.visual.preset == "cinematic-paper" ? "电影纸面" : "清晰跟谱")
                    .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule()).padding(14).allowsHitTesting(false)
            }
        }
    }
}

@MainActor private enum LaunchArguments { static var consumed = false }

struct TransportBar: View {
    @Bindable var session: WorkspaceSession
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button { session.transport.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).help("停止并回到开头").disabled(!session.ready)
                Button { session.togglePlayback() } label: { Image(systemName: session.transport.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 24) }.buttonStyle(.plain).help("播放或暂停（空格）").disabled(!session.ready)
                Text(Self.time(session.transport.position)).monospacedDigit().font(.caption).frame(width: 48)
                Slider(value: Binding(get: { session.transport.position }, set: { session.transport.seek(to: $0) }), in: 0...max(0.01, session.transport.duration)).disabled(!session.ready).accessibilityLabel("演奏进度")
                Text(Self.time(session.transport.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 48)
                Divider().frame(height: 18)
                Text("\(session.project?.settings.export.fps.n ?? 60) fps").font(.caption).foregroundStyle(.secondary)
                Button { session.prepare() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("重新准备演奏").disabled(session.project == nil || session.isBusy)
            }
            HStack {
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let result = session.exportResult {
                    Button("在访达中显示影片") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }.buttonStyle(.link).font(.caption)
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
    static func time(_ seconds: Double) -> String { String(format: "%02d:%02d.%01d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60, Int(max(0, seconds) * 10) % 10) }
}
