import SwiftUI

struct VolumeControl: View {
    let label: String
    let volume: Double
    let maximum: Double
    let onCommit: (Double) -> Void
    @State private var draft: Double
    @State private var editing = false

    init(_ label: String, volume: Double, maximum: Double, onCommit: @escaping (Double) -> Void) {
        self.label = label; self.volume = volume; self.maximum = maximum; self.onCommit = onCommit
        _draft = State(initialValue: volume)
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { draft }, set: { value in
                    draft = value
                    if !editing { onCommit(value) }
                }), in: 0...maximum, step: maximum == 1 ? 0.01 : 0.05, onEditingChanged: { active in
                    editing = active
                    if !active { onCommit(draft) }
                })
                .accessibilityLabel(label)
                .accessibilityValue("\(Int((draft * 100).rounded()))%")
                Text("\(Int((draft * 100).rounded()))%")
                    .monospacedDigit().frame(width: 44, alignment: .trailing).accessibilityHidden(true)
            }
        }
        .onChange(of: volume) { _, value in if !editing { draft = value } }
        .contextMenu {
            Button("恢复到 100%") { draft = 1; onCommit(1) }
        }
    }
}
