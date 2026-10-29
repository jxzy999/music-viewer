import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScoreCore

public struct CapturedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bgra: Data
    public func png() throws -> Data {
        guard let provider = CGDataProvider(data: bgra as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScoreError.invalid("无法读取导出帧。") }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ScoreError.invalid("无法创建帧图像。") }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ScoreError.invalid("帧图像写入失败。") }
        return data as Data
    }
}

extension MetalSceneRenderer {
    public func capture(time: Double, width: Int, height: Int) throws -> CapturedFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ScoreError.invalid("无法创建帧捕获缓冲。") }
        try render(time: time, to: texture, wait: true)
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        }
        return CapturedFrame(width: width, height: height, bgra: bytes)
    }
}
