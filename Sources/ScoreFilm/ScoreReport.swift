import SwiftUI
import AppKit
import ScoreMedia

struct ScoreReport: View {
    let session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("曲谱报告").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            if let project = session.project {
                Text("\(project.score.title) · \(project.score.noteCount) 个音符 · \(project.score.parts.count) 个演奏轨道")
                if let layout = session.layout { Text("\(layout.pages.count) 页 · 已定位 \(layout.anchors.count) 个符头 · 缺失 \(layout.missingNoteIDs.count) 个").foregroundStyle(.secondary) }
                if let plan = session.plan { Text("演奏时长 \(String(format: "%.3f", plan.duration)) 秒 · \(plan.notes.count) 次起音 · \(plan.trails.count) 条合格连接").foregroundStyle(.secondary) }
                Divider()
                if project.score.diagnostics.isEmpty { Label("当前识别到的曲谱特性可准备演奏", systemImage: "checkmark.circle").foregroundStyle(.green) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(project.score.diagnostics) { diagnostic in Label(diagnostic.message, systemImage: diagnostic.severity == .blocking ? "exclamationmark.octagon" : "exclamationmark.triangle").foregroundStyle(diagnostic.severity == .blocking ? .red : .secondary) }
                        Text("原始 MusicXML 随工程完整保存。尚未支持的装饰音、微分音和跳转会阻止生成不完整的演奏；连奏关系不明确时仅显示光点。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24).frame(width: 640, height: 420)
    }
}

struct CreditsView: View {
    var body: some View {
        Form {
            Section("Music Viewer 0.1") { Text("本地曲谱演奏与影片制作。Mac 首版开发中。"); Text("工程与音视频在本机处理，排版不使用远程服务。").foregroundStyle(.secondary) }
            Section("开源组件与音源") {
                Text("OpenSheetMusicDisplay 2.2.1 · BSD 3-Clause")
                Text("GeneralUser GS · S. Christian Collins · License 2.0")
                Button("查看随应用分发的许可") { NSWorkspace.shared.open(MediaResources.root.appendingPathComponent("Licenses")) }
            }
        }.formStyle(.grouped).padding()
    }
}
