import SwiftUI
import MetalKit
import ScoreMedia

struct ScorePreview: NSViewRepresentable {
    let scene: ScenePlan
    let transport: AudioTransport
    let failure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), device: MTLCreateSystemDefaultDevice())
        view.autoResizeDrawable = true
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true
        view.preferredFramesPerSecond = 60; view.enableSetNeedsDisplay = false; view.isPaused = false
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.transport = transport
        context.coordinator.install(scene: scene, view: view, failure: failure)
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.transport = transport
        context.coordinator.install(scene: scene, view: view, failure: failure)
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { view.isPaused = true; view.delegate = nil }

    @MainActor final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MetalSceneRenderer?
        var transport: AudioTransport?
        var identity: Int?
        var lastTime: Double?
        var lastSize = CGSize.zero
        var failure: ((String) -> Void)?
        func install(scene: ScenePlan, view: MTKView, failure: @escaping (String) -> Void) {
            self.failure = failure
            // A scene is replaced only after explicit settings changes or preparation.
            // The immutable storage identity is supplied by the view's .id at the call site.
            guard renderer == nil else { return }
            do { renderer = try MetalSceneRenderer(scene: scene); view.device = renderer?.device }
            catch { failure(error.localizedDescription) }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            let time = transport?.time ?? 0
            guard time != lastTime || view.drawableSize != lastSize else { return }
            guard let renderer, let drawable = view.currentDrawable else { return }
            do {
                try renderer.render(time: time, to: drawable.texture, drawable: drawable)
                lastTime = time; lastSize = view.drawableSize
            }
            catch { view.isPaused = true; failure?(error.localizedDescription) }
        }
    }
}
