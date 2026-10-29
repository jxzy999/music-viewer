import Foundation
import simd
import ScoreCore

public struct ScenePlan: Sendable {
    public let layout: LayoutSnapshot
    public let performance: PerformancePlan
    public let settings: ProjectSettings
    let positions: [String: SIMD3<Float>]
    let events: [NoteAnchorEvent]
    let eventIndex: [String: NoteAnchorEvent]
    let pageOrigins: [Float]
    let cameraKeys: [CameraKey]
    let maximumNoteLength: Double

    public init(layout: LayoutSnapshot, performance: PerformancePlan, settings: ProjectSettings) {
        self.layout = layout; self.performance = performance; self.settings = settings
        var origins: [Float] = []; var offset: Float = 0
        for page in layout.pages { origins.append(offset); offset += Float(page.height) + 48 }
        pageOrigins = origins
        positions = layout.anchors.reduce(into: [:]) { map, pair in
            let anchor = pair.value
            guard origins.indices.contains(anchor.page) else { return }
            map[pair.key] = SIMD3(Float(anchor.x), -Float(anchor.y) - origins[anchor.page], 0)
        }
        events = performance.anchors.sorted { $0.start < $1.start }
        eventIndex = Dictionary(uniqueKeysWithValues: performance.anchors.map { ($0.id, $0) })
        maximumNoteLength = performance.anchors.map { $0.end - $0.start }.max() ?? 0
        let focus = Set(settings.camera.focusPartIds)
        var keys: [CameraKey] = []
        let byVisit = Dictionary(grouping: performance.anchors, by: \.visit)
        let focusIDs = Set(performance.anchors.filter { focus.isEmpty || focus.contains($0.note.partID) }.map(\.sourceID))
        let bySystem = Dictionary(grouping: layout.anchors.values.filter { focusIDs.contains($0.sourceID) }, by: \.system)
        for visit in performance.visits {
            let members = (byVisit[visit.serial] ?? []).filter { !$0.note.isRest && (focus.isEmpty || focus.contains($0.note.partID)) }
            let mapped = members.compactMap { layout.anchors[$0.sourceID] }
            guard let first = mapped.first, origins.indices.contains(first.page) else { continue }
            let samePage = mapped.filter { $0.page == first.page }
            let page = layout.pages[first.page]
            let systemIDs = Set(samePage.map(\.system))
            let region = systemIDs.flatMap { bySystem[$0] ?? [] }.filter { $0.page == first.page }
            let minY = Float(region.map(\.y).min() ?? first.y)
            let maxY = Float(region.map(\.y).max() ?? first.y)
            let minX = Float(samePage.map(\.x).min() ?? first.x)
            let maxX = Float(samePage.map(\.x).max() ?? first.x)
            let clear = settings.visual.preset == "clear-score" || settings.camera.preset == "flatFollow"
            let fullWidth = Float(page.width) * 0.97
            let detailWidth = min(Float(page.width) * 1.02, max(400, maxX - minX + 240))
            let movement = Float(max(0, min(1, (settings.camera.motionIntensity - 0.35) / 0.3)))
            let width = clear ? fullWidth : fullWidth + (detailWidth - fullWidth) * movement
            let detailX = min(Float(page.width) - width * 0.35, max(width * 0.35, (minX + maxX) / 2))
            let x = clear ? Float(page.width) / 2 : Float(page.width) / 2 + (detailX - Float(page.width) / 2) * movement
            let height = max(180, maxY - minY + 120)
            keys.append(CameraKey(time: performance.tempo.seconds(at: visit.startBeat), center: SIMD2(x, -(minY + maxY) / 2 - origins[first.page]), size: SIMD2(width, height)))
        }
        if keys.isEmpty, let page = layout.pages.first {
            keys = [CameraKey(time: 0, center: SIMD2(Float(page.width / 2), -Float(page.height / 2)), size: SIMD2(Float(page.width), Float(page.height)))]
        }
        cameraKeys = keys
    }

    func camera(at time: Double, aspect: Float) -> simd_float4x4 {
        guard let first = cameraKeys.first else { return matrix_identity_float4x4 }
        var key = first
        let i = max(0, cameraKeys.partitionIndex { $0.time > time } - 1)
        let maximumTravel = Float(layout.pages.map(\.height).max() ?? 1) * 2
        if settings.camera.preset == "locked", !layout.pages.isEmpty {
            let y = -cameraKeys[i].center.y
            let pageIndex = min(layout.pages.count - 1, max(0, pageOrigins.partitionIndex { $0 > y } - 1))
            let page = layout.pages[pageIndex]
            key = CameraKey(time: time, center: SIMD2(Float(page.width / 2), -Float(page.height / 2) - pageOrigins[pageIndex]), size: SIMD2(Float(page.width) * 1.08, Float(page.height) * 1.08))
        } else {
            let a = cameraKeys[i]; key = a
            // Interpolate enclosing rectangles, so the outgoing measure remains
            // visible until the next onset. Then hold through its short release
            // and move into the new rectangle without leaving the new notes.
            if i + 1 < cameraKeys.count {
                let b = cameraKeys[i + 1]
                let lead = min(settings.camera.lookAheadSeconds, 1.1, max(0.001, (b.time - a.time) * 0.4))
                if abs(b.center.y - a.center.y) <= maximumTravel, lead > 0, time >= b.time - lead {
                    key = a.interpolated(to: a.enclosing(b), progress: Float((time - (b.time - lead)) / lead), time: time)
                }
            }
            if i > 0, key.time == a.time {
                let previous = cameraKeys[i - 1]
                let interval = i + 1 < cameraKeys.count ? cameraKeys[i + 1].time - a.time : a.time - previous.time
                let hold = min(0.3, max(0.001, interval * 0.1))
                let settle = min(0.8, max(0.001, interval * 0.25))
                if abs(a.center.y - previous.center.y) <= maximumTravel, time - a.time < hold + settle {
                    key = previous.enclosing(a).interpolated(to: a, progress: Float(max(0, (time - a.time - hold) / settle)), time: time)
                }
            }
        }
        let cinematic = settings.visual.preset == "cinematic-paper" && settings.camera.preset != "flatFollow" && settings.camera.preset != "locked"
        let intensity = Float(settings.camera.motionIntensity)
        let viewHeight = max(key.size.y, key.size.x / max(0.2, aspect)) * (cinematic ? 1.14 : 1.02)
        let target = SIMD3(key.center.x, key.center.y, 0)
        let offset = cinematic ? SIMD3(viewHeight * (0.1 + 0.25 * intensity), -viewHeight * (0.15 + 0.45 * intensity), viewHeight * 1.8) : SIMD3(0, 0, viewHeight * 2)
        let eye = target + offset
        let z = simd_normalize(eye - target)
        let roll = cinematic ? 0.10 + intensity * 0.14 : 0
        let up = SIMD3<Float>(sin(roll), cos(roll), 0)
        let x = simd_normalize(simd_cross(up, z)); let y = simd_cross(z, x)
        let view = simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0), SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
        let w = viewHeight * aspect; let h = viewHeight
        let near: Float = 1; let far = viewHeight * 6 + 2000
        let projection: simd_float4x4
        if cinematic {
            let f = 1 / tan(Float.pi * 35 / 360)
            projection = simd_float4x4(columns: (SIMD4(f / aspect,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far / (near - far),-1),SIMD4(0,0,near * far / (near - far),0)))
        } else {
            projection = simd_float4x4(columns: (SIMD4(2 / w, 0, 0, 0), SIMD4(0, 2 / h, 0, 0), SIMD4(0, 0, 1 / (near - far), 0), SIMD4(0, 0, near / (near - far), 1)))
        }
        return projection * view
    }

    func color(for event: NoteAnchorEvent) -> SIMD4<Float> {
        let matching = settings.visual.voiceColors.filter { $0.selector.matches(event.note) }
        let hex = matching.max { a, b in
            (a.selector.voiceId == nil ? 0 : 1) + (a.selector.staff == nil ? 0 : 1) < (b.selector.voiceId == nil ? 0 : 1) + (b.selector.staff == nil ? 0 : 1)
        }?.color ?? "#6EDBFFFF"
        let number = UInt64(hex.dropFirst(), radix: 16) ?? 0x6EDBFFFF
        return SIMD4(Float((number >> 24) & 255) / 255, Float((number >> 16) & 255) / 255, Float((number >> 8) & 255) / 255, Float(number & 255) / 255)
    }

    func visibleEvents(at time: Double) -> ArraySlice<NoteAnchorEvent> {
        let from = events.partitionIndex { $0.start >= time - maximumNoteLength - 0.35 }
        let to = events.partitionIndex { $0.start > time }
        return events[from..<max(from, to)]
    }

    func audible(_ partID: String) -> Bool {
        !(settings.performance.mutedPartIds ?? []).contains(partID) && ((settings.performance.soloPartIds ?? []).isEmpty || (settings.performance.soloPartIds ?? []).contains(partID))
    }
}

struct CameraKey: Sendable {
    let time: Double
    let center: SIMD2<Float>
    let size: SIMD2<Float>
    func enclosing(_ other: Self) -> Self {
        let lo = simd_min(center - size / 2, other.center - other.size / 2)
        let hi = simd_max(center + size / 2, other.center + other.size / 2)
        return Self(time: time, center: (lo + hi) / 2, size: hi - lo)
    }
    func interpolated(to other: Self, progress: Float, time: Double) -> Self {
        let u = max(0, min(1, progress)); let s = u * u * (3 - 2 * u)
        return Self(time: time, center: center + (other.center - center) * s, size: size + (other.size - size) * s)
    }
}

extension Array {
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0; var high = count
        while low < high { let mid = (low + high) / 2; if predicate(self[mid]) { high = mid } else { low = mid + 1 } }
        return low
    }
}
