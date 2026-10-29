import SwiftUI
import ScoreCore

struct HomeView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("让曲谱成为影片").font(.largeTitle.weight(.semibold))
                    Text("选择一首示例，或导入你的曲谱。设置乐器与画面，播放并导出影片。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("导入曲谱…", systemImage: "folder") { session.openPanel() }.buttonStyle(.borderedProminent)
                        if session.recoveryURL != nil { Button("恢复未保存的工程") { session.restoreRecovery() } }
                    }.padding(.top, 6)
                    Text("支持 MusicXML · MXL · .scorefilm 工程").font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("示例曲谱").font(.title2.weight(.semibold))
                    Text("内置示例保持原样。修改任何设置时，会自动创建独立副本并保存到「我的工程」。")
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), alignment: .top)], spacing: 14) {
                        ForEach(ExampleScore.all) { example in
                            ExampleCard(example: example) { session.openExample(example) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("我的工程").font(.title2.weight(.semibold))
                    if let error = session.libraryError {
                        Text(error).foregroundStyle(.red)
                        Button("重新读取") { Task { await session.refreshLibrary() } }
                    } else if session.libraryProjects.isEmpty {
                        Text("修改示例的设置后，你的副本会出现在这里。").foregroundStyle(.secondary)
                    } else {
                        ForEach(session.libraryProjects) { project in
                            Button {
                                session.open(UserLibrary.store.projectURL(for: project.id))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text").font(.title2).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.title + " · 我的版本").font(.headline)
                                        Text("\(project.partCount) 个轨道 · \(project.noteCount) 个音符").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(project.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.padding(14).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { await session.refreshLibrary() }
    }
}

private struct ExampleCard: View {
    let example: ExampleScore
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(example.ensemble, systemImage: example.id == "fur-elise" ? "pianokeys" : "music.note")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(example.title).font(.title3.weight(.semibold))
            Text(example.composer).font(.caption).foregroundStyle(.secondary)
            Text(example.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack {
                Button("打开示例", action: open)
                    .buttonStyle(.bordered).accessibilityLabel("打开示例：\(example.title)")
                Spacer()
                Link("曲谱来源", destination: example.source).font(.caption)
            }
        }.padding(18).frame(maxWidth: .infinity, minHeight: 205, alignment: .topLeading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
