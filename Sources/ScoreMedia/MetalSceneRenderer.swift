import Foundation
import MetalKit
import simd
import ScoreCore

/// Each preview or export owns its renderer and command queue on one executor.
/// Only the immutable, Sendable ScenePlan crosses executors.
public final class MetalSceneRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let paperPipeline: any MTLRenderPipelineState
    private let glowPipeline: any MTLRenderPipelineState
    private let linePipeline: any MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private var textures: [Int: any MTLTexture] = [:]
    private var recentlyUsed: [Int] = []
    private let scene: ScenePlan
    private let paperVertices: [[Vertex]]
    private(set) var textureLoadCount = 0
    private(set) var maximumVisiblePages = 0

    struct Vertex { var position: SIMD3<Float>; var uv: SIMD2<Float>; var color: SIMD4<Float> }
    struct Frame { var mvp: simd_float4x4; var options: SIMD4<Float> }
    struct PaperLight { var positionRadius: SIMD4<Float>; var color: SIMD4<Float> }

    public init(scene: ScenePlan) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ScoreError.unsupported("此 Mac 无法使用 Metal。") }
        self.device = device; self.queue = queue; self.scene = scene
        let code = try String(contentsOf: MediaResources.root.appendingPathComponent("Scene.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: code, options: nil)
        func pipeline(_ fragment: String, blended: Bool) throws -> any MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: "score_vertex"); p.fragmentFunction = library.makeFunction(name: fragment)
            p.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blended {
                let c = p.colorAttachments[0]!
                c.isBlendingEnabled = true; c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: p)
        }
        paperPipeline = try pipeline("paper_fragment", blended: false)
        glowPipeline = try pipeline("glow_fragment", blended: true)
        linePipeline = try pipeline("line_fragment", blended: true)
        loader = MTKTextureLoader(device: device)
        paperVertices = scene.layout.pages.map { page in
            let top = -scene.pageOrigins[page.index]
            return Self.quad(center: SIMD3(Float(page.width) / 2, top - Float(page.height) / 2, 0), radius: SIMD2(Float(page.width) / 2, Float(page.height) / 2), color: SIMD4(repeating: 1))
        }
    }

    @discardableResult
    public func render(time: Double, to texture: any MTLTexture, drawable: (any CAMetalDrawable)? = nil, wait: Bool = false) throws -> any MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw ScoreError.invalid("无法创建绘图任务。") }
        command.label = "ScoreFilm frame \(time)"
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture; attachment.loadAction = .clear; attachment.storeAction = .store
        attachment.clearColor = scene.settings.visual.preset == "cinematic-paper" ? MTLClearColor(red: 0.055, green: 0.048, blue: 0.04, alpha: 1) : MTLClearColor(red: 0.12, green: 0.15, blue: 0.17, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ScoreError.invalid("无法绘制帧。") }
        var encodingEnded = false
        defer { if !encodingEnded { encoder.endEncoding() } }
        let active = scene.visibleEvents(at: time).filter { !$0.note.isRest && time < $0.end + 0.3 && scene.audible($0.note.partID) }
        var lights: [PaperLight] = []
        for event in active.sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }) {
            guard let p = scene.positions[event.sourceID], let anchor = scene.layout.anchors[event.sourceID] else { continue }
            guard !lights.contains(where: { simd_distance(SIMD2($0.positionRadius.x, $0.positionRadius.y), SIMD2(p.x, p.y)) < 12 }) else { continue }
            let release = Float(max(0, min(1, (event.end + 0.3 - time) / 0.3)))
            var color = scene.color(for: event); color.w *= release
            lights.append(PaperLight(positionRadius: SIMD4(p.x, p.y, max(24, Float(anchor.radius) * 9), 0), color: color))
            if lights.count == 8 { break }
        }
        var frame = Frame(mvp: scene.camera(at: time, aspect: Float(texture.width) / Float(texture.height)), options: SIMD4(scene.settings.visual.preset == "cinematic-paper" ? 1 : 0, Float(lights.count), 0, 0))
        encoder.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        if lights.isEmpty { lights = [PaperLight(positionRadius: .zero, color: .zero)] }
        encoder.setFragmentBytes(lights, length: MemoryLayout<PaperLight>.stride * lights.count, index: 2)
        encoder.setRenderPipelineState(paperPipeline)
        let visiblePages = paperVertices.indices.filter { index in
            let vertices = paperVertices[index]
            let projected = vertices.map { frame.mvp * SIMD4($0.position, 1) }
            return !projected.allSatisfy { $0.x < -$0.w } && !projected.allSatisfy { $0.x > $0.w } && !projected.allSatisfy { $0.y < -$0.w } && !projected.allSatisfy { $0.y > $0.w } && !projected.allSatisfy { $0.z < 0 } && !projected.allSatisfy { $0.z > $0.w }
        }
        maximumVisiblePages = max(maximumVisiblePages, visiblePages.count)
        for index in visiblePages {
            let vertices = paperVertices[index]
            if textures[index] == nil {
                textures[index] = try loader.newTexture(data: scene.layout.pages[index].png, options: [.SRGB: false, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)])
                textureLoadCount += 1
            }
            recentlyUsed.removeAll { $0 == index }; recentlyUsed.append(index)
            encoder.setFragmentTexture(textures[index], index: 0)
            try draw(vertices, encoder: encoder)
        }
        // Never evict a page still visible in this frame. A pull-back across
        // pages may need more than three; evict the non-visible LRU entries
        // only after the complete visible set is known.
        let visibleSet = Set(visiblePages)
        while recentlyUsed.count > max(3, visiblePages.count) {
            guard let index = recentlyUsed.firstIndex(where: { !visibleSet.contains($0) }) else { break }
            textures.removeValue(forKey: recentlyUsed.remove(at: index))
        }
        var halos: [Vertex] = []; var cores: [Vertex] = []; var lines: [Vertex] = []
        for event in active {
            guard let p = scene.positions[event.sourceID], let anchor = scene.layout.anchors[event.sourceID] else { continue }
            let age = max(0, time - event.start)
            let release = Float(max(0, min(1, (event.end + 0.3 - time) / 0.3)))
            let pulse: Float = scene.settings.visual.effects.sustainMode == "pulse" ? Float(0.08 * sin(age * 5)) : 0
            let brightness = (0.55 + 0.45 * Float(exp(-age * 14)) + pulse) * release
            var color = scene.color(for: event); color.w *= brightness
            let radius = max(2.5, Float(anchor.radius) * 0.9)
            var halo = color; halo.w *= 0.34
            halos += Self.quad(center: p + SIMD3(0, 0, 0.04), radius: SIMD2(repeating: radius * 5.5), color: halo)
            cores += Self.quad(center: p + SIMD3(0, 0, 0.08), radius: SIMD2(repeating: radius * 1.65), color: color)
        }
        let history = scene.settings.visual.effects.trailHistoryMS / 1000
        var lanes: [String: Int] = [:]
        for trail in scene.performance.trails where time >= trail.start && time < trail.holdUntil + (trail.kind == .tie ? 0.45 : history) {
            guard let a = scene.eventIndex[trail.fromID], let b = scene.eventIndex[trail.toID], let pa = scene.positions[a.sourceID], let pb = scene.positions[b.sourceID], let ga = scene.layout.anchors[a.sourceID], let gb = scene.layout.anchors[b.sourceID], ga.page == gb.page, ga.system == gb.system else { continue }
            guard scene.audible(a.note.partID) else { continue }
            let laneKey = "\(a.note.partID)|\(a.note.voice)"
            guard lanes[laneKey, default: 0] < scene.settings.visual.effects.maxTrailLanes else { continue }
            let distance = simd_length(pb - pa)
            let loop = distance <= 1 && trail.kind == .slur && scene.settings.visual.effects.repeatNoteMode == "loop"
            guard distance > 1 || loop, distance < 850, trail.arrival > trail.start else { continue }
            lanes[laneKey, default: 0] += 1
            let u = Float(max(0, min(1, (time - trail.start) / (trail.arrival - trail.start))))
            let lo: Float = trail.kind == .tie ? 0 : Float(max(0, min(1, (time - history - trail.start) / (trail.arrival - trail.start))))
            let h = min(28, max(8, distance * 0.1))
            func point(_ t: Float) -> SIMD3<Float> {
                if loop {
                    let angle = t * 2 * Float.pi
                    return pa + SIMD3(sin(angle) * h, (1 - cos(angle)) * h * 0.5, sin(t * Float.pi) * h + 0.1)
                }
                return pa + (pb - pa) * t + SIMD3(0, h * 4 * t * (1 - t) * 0.65, h * 4 * t * (1 - t) + 0.1)
            }
            var color = scene.color(for: a)
            color.w *= trail.kind == .tie ? Float(max(0, min(1, (trail.holdUntil + 0.45 - time) / 0.45))) * 0.82 : 0.78
            if u > lo {
                let count = 32
                for segment in 0..<count {
                    let v0 = Float(segment) / Float(count); let v1 = Float(segment + 1) / Float(count)
                    let p0 = point(lo + (u - lo) * v0); let p1 = point(lo + (u - lo) * v1)
                    var c = color; if trail.kind == .slur { c.w *= 0.15 + v1 * 0.85 }
                    lines += Self.ribbon(p0, p1, width: trail.kind == .tie ? 2.4 : 3.0, color: c)
                }
            }
            if time < trail.arrival {
                let p = point(u)
                var halo = color; halo.w *= 0.26
                halos += Self.quad(center: p, radius: SIMD2(repeating: 15), color: halo)
                cores += Self.quad(center: p + SIMD3(0, 0, 0.05), radius: SIMD2(repeating: 4), color: color)
            }
        }
        encoder.setRenderPipelineState(glowPipeline); try draw(halos, encoder: encoder)
        encoder.setRenderPipelineState(linePipeline); try draw(lines, encoder: encoder)
        encoder.setRenderPipelineState(glowPipeline); try draw(cores, encoder: encoder)
        encoder.endEncoding(); encodingEnded = true
        if let drawable { command.present(drawable) }
        command.commit()
        if wait {
            command.waitUntilCompleted()
            if let error = command.error { throw error }
        }
        return command
    }

    private func draw(_ vertices: [Vertex], encoder: any MTLRenderCommandEncoder) throws {
        guard !vertices.isEmpty else { return }
        guard let buffer = device.makeBuffer(bytes: vertices, length: MemoryLayout<Vertex>.stride * vertices.count, options: .storageModeShared) else { throw ScoreError.invalid("绘图内存不足，未输出不完整的帧。") }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }

    private static func quad(center: SIMD3<Float>, radius: SIMD2<Float>, color: SIMD4<Float>) -> [Vertex] {
        let corners: [(Float, Float, Float, Float)] = [(-1, 1, 0, 0), (-1, -1, 0, 1), (1, -1, 1, 1), (-1, 1, 0, 0), (1, -1, 1, 1), (1, 1, 1, 0)]
        return corners.map { x, y, u, v in Vertex(position: center + SIMD3(x * radius.x, y * radius.y, 0), uv: SIMD2(u, v), color: color) }
    }

    private static func ribbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>, width: Float, color: SIMD4<Float>) -> [Vertex] {
        let d = b - a; let length = max(0.001, simd_length(SIMD2(d.x, d.y)))
        let side = SIMD3(-d.y / length * width, d.x / length * width, 0)
        let points = [a + side, a - side, b - side, a + side, b - side, b + side]
        let uv: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,0),SIMD2(1,1),SIMD2(0,1)]
        return zip(points, uv).map { Vertex(position: $0.0, uv: $0.1, color: color) }
    }
}
