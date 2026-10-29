import SwiftUI
import ScoreCore

struct RouteEditor: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [InstrumentRoute] = []
    @State private var selected: String?
    @State private var validationError: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("段落配器").font(.title2.weight(.semibold)); Spacer(); Button("添加段落", systemImage: "plus") { add() } }.padding(20)
            Divider()
            if let project = session.project, let reference = project.score.parts.first(where: { $0.id == project.settings.scoreAxis.referencePartId }) {
                HSplitView {
                    List(selection: $selected) { ForEach(routes) { route in VStack(alignment: .leading) {
                        Text(project.settings.instruments.first { $0.id == route.instrumentId }?.displayName ?? route.instrumentId)
                        Text("\(route.selector.partId) · 优先级 \(route.priority)").font(.caption).foregroundStyle(.secondary)
                    }.tag(route.id) } }.frame(minWidth: 180, idealWidth: 200)
                    if let i = routes.firstIndex(where: { $0.id == selected }) {
                        Form {
                            Picker("演奏轨道", selection: $routes[i].selector.partId) { ForEach(project.score.parts) { Text($0.name).tag($0.id) } }
                            TextField("声部编号（空白表示全部）", text: Binding(get: { routes[i].selector.voiceId ?? "" }, set: { routes[i].selector.voiceId = $0.isEmpty ? nil : $0 }))
                            Picker("乐器", selection: $routes[i].instrumentId) { ForEach(project.settings.instruments) { Text($0.displayName).tag($0.id) } }
                            Stepper("优先级：\(routes[i].priority)", value: $routes[i].priority, in: 0...1000)
                            PositionFields(title: "起点（包含）", position: $routes[i].range.from, measures: reference.measures)
                            PositionFields(title: "终点（不包含）", position: $routes[i].range.to, measures: reference.measures)
                            Text("拍值以四分音符为 1；分子与分母可表达连音。段落在每次反复时生效；延音链继续使用起音时的乐器。").font(.caption).foregroundStyle(.secondary)
                            Button("删除此段落", role: .destructive) { let id = selected; routes.removeAll { $0.id == id }; selected = routes.first?.id }
                        }.formStyle(.grouped).frame(minWidth: 400)
                    } else { ContentUnavailableView("选择或添加段落", systemImage: "music.note.list").frame(maxWidth: .infinity) }
                }
            }
            Divider()
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red).padding(.horizontal, 20) }
            HStack { Text("同优先级的有效范围不能重叠。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("应用") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }.padding(20)
        }.frame(width: 760, height: 600)
        .onAppear { routes = session.project?.settings.routes ?? []; selected = routes.first?.id }
    }
    private func add() {
        guard let p = session.project, let ref = p.score.parts.first(where: { $0.id == p.settings.scoreAxis.referencePartId }), let first = ref.measures.first, let last = ref.measures.last, let instrument = p.settings.instruments.first else { return }
        let route = InstrumentRoute(selector: NoteSelector(partId: session.selectedPart ?? p.score.parts[0].id), range: ScoreRange(from: ScorePosition(measureId: first.id, beat: .zero), to: ScorePosition(measureId: last.id, beat: last.length)), instrumentId: instrument.id)
        routes.append(route); selected = route.id
    }
    private func apply() {
        guard var value = session.project else { return }; value.settings.routes = routes
        do { _ = try PerformanceCompiler.compile(value); session.edit { $0.routes = routes }; dismiss() } catch { validationError = error.localizedDescription }
    }
}

private struct PositionFields: View {
    let title: String
    @Binding var position: ScorePosition
    let measures: [ScoreMeasure]
    var body: some View {
        Section(title) {
            Picker("小节", selection: $position.measureId) { ForEach(measures) { Text("第 \($0.number) 小节（\($0.index + 1)）").tag($0.id) } }
            HStack {
                TextField("拍值分子", value: Binding(get: { position.beat.n }, set: { if let b = try? Beat($0, position.beat.d) { position.beat = b } }), format: .number)
                Text("／")
                TextField("分母", value: Binding(get: { position.beat.d }, set: { if let b = try? Beat(position.beat.n, $0) { position.beat = b } }), format: .number)
            }
        }
    }
}
