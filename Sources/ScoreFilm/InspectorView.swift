import SwiftUI
import AppKit
import ScoreCore

struct InspectorView: View {
    @Bindable var session: WorkspaceSession
    @Binding var routesOpen: Bool
    private var settings: ProjectSettings? { session.project?.settings }
    private var selectedPart: ScorePart? { session.project?.score.parts.first { $0.id == session.selectedPart } }
    var body: some View {
        Form {
            Section("画面") {
                Picker("风格", selection: setting(\.visual.preset, fallback: "cinematic-paper")) { Text("电影纸面").tag("cinematic-paper"); Text("清晰跟谱").tag("clear-score") }
                Picker("运镜", selection: setting(\.camera.preset, fallback: "cinematicFollow")) { Text("电影跟随").tag("cinematicFollow"); Text("正面跟谱").tag("flatFollow"); Text("锁定全页").tag("locked") }
                Picker("运动幅度", selection: setting(\.camera.motionIntensity, fallback: 0.35)) {
                    Text("轻柔").tag(0.15); Text("标准").tag(0.35); Text("明显").tag(0.65); Text("静稳").tag(0.0)
                    if let value = settings?.camera.motionIntensity, ![0.0,0.15,0.35,0.65].contains(value) { Text("自定 · \(String(format: "%.0f", value * 100))%").tag(value) }
                }
            }
            Section("光点与轨迹") {
                Picker("连接", selection: setting(\.visual.effects.trailMode, fallback: "auto")) { Text("自动").tag("auto"); Text("保留合格连接").tag("travel"); Text("关闭").tag("off") }
                Picker("短线长度", selection: setting(\.visual.effects.trailHistoryMS, fallback: 220)) {
                    Text("短 · 120 毫秒").tag(120.0); Text("标准 · 220 毫秒").tag(220.0); Text("长 · 350 毫秒").tag(350.0)
                    if let value = settings?.visual.effects.trailHistoryMS, ![120.0,220,350].contains(value) { Text("自定 · \(String(format: "%g", value)) 毫秒").tag(value) }
                }
                Text("轨迹仅连接曲谱中的连奏与延音关系。普通相邻音保持独立光点。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("持音光点", selection: setting(\.visual.effects.sustainMode, fallback: "pulse")) { Text("轻微脉冲").tag("pulse"); Text("稳定").tag("none") }
                Picker("同位连奏", selection: setting(\.visual.effects.repeatNoteMode, fallback: "pulse")) { Text("脉冲").tag("pulse"); Text("小回环").tag("loop") }
                Stepper("最多 \(settings?.visual.effects.maxTrailLanes ?? 4) 条同声部连接", value: setting(\.visual.effects.maxTrailLanes, fallback: 4), in: 1...16)
            }
            if let project = session.project {
                Section("镜头关注") {
                    ForEach(project.score.parts) { part in
                        Toggle(part.name, isOn: Binding(get: { (settings?.camera.focusPartIds.isEmpty ?? true) || settings?.camera.focusPartIds.contains(part.id) == true }, set: { included in
                            session.edit { value in
                                var ids = value.camera.focusPartIds.isEmpty ? project.score.parts.map(\.id) : value.camera.focusPartIds
                                if included && !ids.contains(part.id) { ids.append(part.id) }
                                if !included && ids.count > 1 { ids.removeAll { $0 == part.id } }
                                value.camera.focusPartIds = ids
                            }
                        }))
                    }
                    Text("至少关注一个声部；其他声部继续演奏。锁定全页时显示整页。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let part = selectedPart, let project = session.project {
                Section(part.name) {
                    Toggle("静音", isOn: partFlag(\.performance.mutedPartIds, part: part.id))
                    Toggle("独奏", isOn: partFlag(\.performance.soloPartIds, part: part.id))
                    Picker("乐器", selection: Binding(get: { settings?.partInstruments[part.id] ?? "source" }, set: { value in session.edit { $0.partInstruments[part.id] = value == "source" ? nil : value } })) {
                        Text("跟随原谱").tag("source"); ForEach(project.settings.instruments) { Text($0.displayName).tag($0.id) }
                    }
                    ForEach(part.voices, id: \.self) { voice in
                        let routeID = "voice-\(part.id)-\(voice)"
                        Picker("声部 \(voice)", selection: Binding(get: { settings?.routes.first { $0.id == routeID }?.instrumentId ?? "inherit" }, set: { value in
                            session.edit { config in
                                config.routes.removeAll { $0.id == routeID }
                                if value != "inherit", let reference = project.score.parts.first(where: { $0.id == config.scoreAxis.referencePartId }), let first = reference.measures.first, let last = reference.measures.last {
                                    config.routes.append(InstrumentRoute(id: routeID, selector: NoteSelector(partId: part.id, voiceId: voice), range: ScoreRange(from: ScorePosition(measureId: first.id, beat: .zero), to: ScorePosition(measureId: last.id, beat: last.length)), instrumentId: value, priority: 10))
                                }
                            }
                        })) { Text("跟随乐器").tag("inherit"); ForEach(project.settings.instruments) { Text($0.displayName).tag($0.id) } }
                        ColorPicker("声部 \(voice) 光点", selection: voiceColor(part: part.id, voice: voice), supportsOpacity: false)
                    }
                    Button("编辑段落配器…") { routesOpen = true }
                }
            }
            Section("速度与声音") {
                Picker("演奏速度", selection: setting(\.performance.tempoScale, fallback: 1)) {
                    Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("原速").tag(1.0); Text("1.25×").tag(1.25); Text("1.5×").tag(1.5)
                    if let value = settings?.performance.tempoScale, ![0.5,0.75,1,1.25,1.5].contains(value) { Text("自定 · \(String(format: "%g", value))×").tag(value) }
                }
                Picker("延长记号", selection: setting(\.performance.fermataMultiplier, fallback: 1.5)) {
                    Text("1.5 倍时值").tag(1.5); Text("2 倍时值").tag(2.0); Text("3 倍时值").tag(3.0)
                    if let value = settings?.performance.fermataMultiplier, ![1.5,2,3].contains(value) { Text("自定 · \(String(format: "%g", value)) 倍").tag(value) }
                }
                Picker("混响", selection: Binding(get: { settings?.performance.reverbWetDryMix ?? 12 }, set: { value in session.edit { $0.performance.reverbWetDryMix = value } })) {
                    Text("关闭").tag(0.0); Text("轻微 · 8%").tag(8.0); Text("自然 · 12%").tag(12.0); Text("明显 · 24%").tag(24.0); Text("宽阔 · 40%").tag(40.0)
                    if let value = settings?.performance.reverbWetDryMix, ![0.0,8,12,24,40].contains(value) { Text("自定 · \(Int(value))%").tag(value) }
                }
            }
            Section("版面") {
                Picker("纸张", selection: setting(\.layout.paper, fallback: "a4")) { Text("A4").tag("a4"); Text("Letter").tag("letter") }
                Picker("方向", selection: setting(\.layout.orientation, fallback: "portrait")) { Text("纵向").tag("portrait"); Text("横向").tag("landscape") }
                Toggle("保留原谱换行与分页", isOn: setting(\.layout.preserveSourceBreaks, fallback: true))
            }
            Section("影片") {
                Picker("画幅", selection: Binding(get: { settings?.export.width == 1080 ? "portrait" : "landscape" }, set: { value in session.edit { $0.export.width = value == "portrait" ? 1080 : 1920; $0.export.height = value == "portrait" ? 1920 : 1080 } })) { Text("横屏 · 1920 × 1080").tag("landscape"); Text("竖屏 · 1080 × 1920").tag("portrait") }
                Picker("帧率", selection: setting(\.export.fps.n, fallback: 60)) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                Text("MP4 · H.264 · AAC · 48 kHz").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).controlSize(.small).disabled(session.isBusy)
    }
    private func setting<T>(_ key: WritableKeyPath<ProjectSettings, T>, fallback: T) -> Binding<T> {
        Binding(get: { settings?[keyPath: key] ?? fallback }, set: { value in session.edit { $0[keyPath: key] = value } })
    }
    private func partFlag(_ key: WritableKeyPath<ProjectSettings, [String]?>, part: String) -> Binding<Bool> {
        Binding(get: { settings?[keyPath: key]?.contains(part) ?? false }, set: { flag in session.edit { value in
            var list = value[keyPath: key] ?? []; list.removeAll { $0 == part }; if flag { list.append(part) }; value[keyPath: key] = list
        } })
    }
    private func voiceColor(part: String, voice: String) -> Binding<Color> {
        Binding(get: {
            let matches = settings?.visual.voiceColors.filter { $0.selector.partId == part } ?? []
            let hex = matches.first { $0.selector.voiceId == voice }?.color ?? matches.first { $0.selector.voiceId == nil }?.color ?? "#6EDBFFFF"
            let v = UInt64(hex.dropFirst(), radix: 16) ?? 0x6EDBFFFF
            return Color(red: Double((v >> 24) & 255) / 255, green: Double((v >> 16) & 255) / 255, blue: Double((v >> 8) & 255) / 255)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02XFF", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            session.edit { settings in
                if let i = settings.visual.voiceColors.firstIndex(where: { $0.selector.partId == part && $0.selector.voiceId == voice }) { settings.visual.voiceColors[i].color = hex }
                else { settings.visual.voiceColors.append(VoiceColor(selector: NoteSelector(partId: part, voiceId: voice), color: hex)) }
            }
        })
    }
}
