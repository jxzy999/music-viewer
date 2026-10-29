import Foundation
import Metal
import ScoreCore
import Darwin
import simd

public actor FrameVerifier {
    public init() {}
    public func verify(scene: ScenePlan, to folder: URL) throws {
        let fps = scene.settings.export.fps.n
        let last = min(Int(scene.performance.duration * Double(fps)), fps * 36)
        let tieSample = scene.performance.trails.first { $0.kind == .tie }.map { Int(($0.arrival + ($0.holdUntil - $0.arrival) * 0.6) * Double(fps)) } ?? last
        let pageSample = scene.performance.anchors.first { (scene.layout.anchors[$0.sourceID]?.page ?? 0) > 0 }.map { Int(($0.start + 0.35) * Double(fps)) } ?? last
        let indices = Array(Set([0, min(last, fps + 11), min(last, fps * 3 + 7), min(last, fps * 9 + 13), min(last, fps * 21 + 4), min(last,tieSample), min(last,pageSample), last])).sorted()
        let renderer = try MetalSceneRenderer(scene: scene)
        let width = scene.settings.export.width; let height = scene.settings.export.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead]; descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { throw ScoreError.invalid("无法创建验证帧。") }
        var sequential: [Int: String] = [:]
        var frameMilliseconds: [Double] = []
        var checkedHeads = 0
        var outside = 0
        var cameraExamples: [[String: Any]] = []
        for index in 0...last {
            try Task.checkCancellation()
            let began = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool { _ = try renderer.render(time: Double(index) / Double(fps), to: texture, wait: true) }
            frameMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            if index % 6 == 0, scene.settings.camera.preset != "locked" {
                let time = Double(index) / Double(fps)
                let projection = scene.camera(at: time, aspect: Float(width) / Float(height))
                for event in scene.visibleEvents(at: time) where !event.note.isRest && time < event.end && scene.audible(event.note.partID) && (scene.settings.camera.focusPartIds.isEmpty || scene.settings.camera.focusPartIds.contains(event.note.partID)) {
                    guard let point = scene.positions[event.sourceID] else { continue }
                    let clip = projection * SIMD4(point, 1); checkedHeads += 1
                    if clip.w <= 0 || abs(clip.x / clip.w) > 0.96 || abs(clip.y / clip.w) > 0.96 {
                        outside += 1
                        if cameraExamples.count < 12 { cameraExamples.append(["sourceID":event.sourceID,"time":time,"ndcX":clip.x / clip.w,"ndcY":clip.y / clip.w]) }
                    }
                }
            }
            if indices.contains(index) {
                var bytes = Data(count: width * height * 4)
                bytes.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress { texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
                }
                sequential[index] = ProjectFile.digest(bytes)
            }
        }
        let fresh = try MetalSceneRenderer(scene: scene)
        var results: [[String: Any]] = []
        for index in indices.reversed() {
            try Task.checkCancellation()
            let afterSeeking = try renderer.capture(time: Double(index) / Double(fps), width: width, height: height)
            let direct = try fresh.capture(time: Double(index) / Double(fps), width: width, height: height)
            let hash = ProjectFile.digest(direct.bgra)
            guard sequential[index] == hash, ProjectFile.digest(afterSeeking.bgra) == hash else { throw ScoreError.invalid("第 \(index) 帧在顺序渲染与定位后不一致。") }
            results.append(["frame": index,"time": Double(index) / Double(fps),"sha256":hash,"matchesSequentialAndSeeking":true])
            try direct.png().write(to: folder.appendingPathComponent("frame-\(index).png"))
        }
        try JSONSerialization.data(withJSONObject: ["preset":scene.settings.visual.preset,"width":width,"height":height,"sequentialFrames":last + 1,"fps":fps,"samples":results], options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("frame-determinism.json"))
        let warm = Array(frameMilliseconds.dropFirst()).sorted()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let metrics: [String: Any] = ["scope":"1080-class offscreen render, CPU submission plus synchronous GPU completion; excludes texture readback, hashing and PNG encoding; not a display refresh measurement", "frames":frameMilliseconds.count,"firstFrameMS":frameMilliseconds.first ?? 0,"warmP50MS":warm.isEmpty ? 0 : warm[warm.count / 2],"warmP95MS":warm.isEmpty ? 0 : warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))],"maxFrameMS":frameMilliseconds.max() ?? 0,"textureLoads":renderer.textureLoadCount,"maximumVisiblePages":renderer.maximumVisiblePages,"mainProcessMaximumResidentBytes":usage.ru_maxrss,"memoryScope":"Main process lifetime maximum; WebKit helper processes are separate"]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("rendering-performance.json"))
        try JSONSerialization.data(withJSONObject: ["scope":"Gate-active audible heads in the selected camera parts, sampled every six frames; locked whole-page cuts are tested separately", "checkedHeads":checkedHeads,"outsideSafeArea":outside,"passed":outside == 0,"examples":cameraExamples], options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("camera-safety.json"))
    }
}
