import Foundation
import CZlib

/// Small ZIP reader/writer with bounded inflation, CRC checks and no filesystem extraction.
public enum ZIPArchive {
    public static let maximumSize = 500 * 1024 * 1024

    public static func read(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= maximumSize else { throw ScoreError.invalid("工程压缩包大小不合法。") }
        let lower = max(0, data.count - 65_557)
        var end: Int?
        for i in stride(from: data.count - 22, through: lower, by: -1) {
            if try u32(data, i) == 0x06054b50, i + 22 + Int(try u16(data, i + 20)) == data.count { end = i; break }
        }
        guard let end else { throw ScoreError.invalid("缺少 ZIP 目录。") }
        guard try u16(data, end + 4) == 0, try u16(data, end + 6) == 0 else { throw ScoreError.unsupported("不支持分卷压缩包。") }
        let count = Int(try u16(data, end + 10))
        guard count < 10_000, count == Int(try u16(data, end + 8)) else { throw ScoreError.invalid("压缩包条目过多或目录不一致。") }
        var cursor = Int(try u32(data, end + 16))
        let directorySize = Int(try u32(data, end + 12))
        guard cursor >= 0, cursor <= end, directorySize <= end - cursor else { throw ScoreError.invalid("ZIP 目录越界。") }
        let directoryEnd = cursor + directorySize
        var result: [String: Data] = [:]
        var total = 0
        var paths = Set<String>()
        for _ in 0..<count {
            guard try u32(data, cursor) == 0x02014b50 else { throw ScoreError.invalid("ZIP 条目损坏。") }
            let flags = try u16(data, cursor + 8)
            let method = try u16(data, cursor + 10)
            let checksum = try u32(data, cursor + 16)
            let compressed = Int(try u32(data, cursor + 20))
            let expanded = Int(try u32(data, cursor + 24))
            let nameLength = Int(try u16(data, cursor + 28))
            let extraLength = Int(try u16(data, cursor + 30))
            let commentLength = Int(try u16(data, cursor + 32))
            let attributes = try u32(data, cursor + 38)
            let local = Int(try u32(data, cursor + 42))
            let name = try slice(data, cursor + 46, nameLength)
            guard let path = String(data: name, encoding: .utf8), validPath(path), paths.insert(path).inserted else { throw ScoreError.invalid("压缩包包含重复或不安全的文件路径。") }
            guard (attributes >> 16) & 0xf000 != 0xa000 else { throw ScoreError.invalid("压缩包不允许符号链接。") }
            guard flags & 1 == 0, method == 0 || method == 8 else { throw ScoreError.unsupported("不支持加密或此压缩方式。") }
            total += expanded
            guard total <= maximumSize, expanded <= 100 * 1024 * 1024, expanded <= max(1_048_576, compressed * 1000) else { throw ScoreError.invalid("解包大小或压缩比超过安全限制。") }
            guard try u32(data, local) == 0x04034b50 else { throw ScoreError.invalid("ZIP 本地条目不完整。") }
            guard try u16(data, local + 6) == flags, try u16(data, local + 8) == method else { throw ScoreError.invalid("ZIP 条目的压缩标记不一致。") }
            if flags & 8 == 0 {
                guard try u32(data, local + 14) == checksum, try u32(data, local + 18) == compressed, try u32(data, local + 22) == expanded else { throw ScoreError.invalid("ZIP 本地条目的长度或校验值不一致。") }
            }
            let localNameLength = Int(try u16(data, local + 26))
            let localExtraLength = Int(try u16(data, local + 28))
            guard try slice(data, local + 30, localNameLength) == name else { throw ScoreError.invalid("ZIP 文件名不一致。") }
            let payload = try slice(data, local + 30 + localNameLength + localExtraLength, compressed)
            let contents: Data
            if method == 0 {
                guard compressed == expanded else { throw ScoreError.invalid("ZIP 条目长度不一致。") }
                contents = payload
            } else { contents = try inflateRaw(payload, size: expanded) }
            guard crc(contents) == checksum else { throw ScoreError.invalid("文件校验失败：\(path)") }
            if !path.hasSuffix("/") { result[path] = contents }
            cursor += 46 + nameLength + extraLength + commentLength
            guard cursor <= directoryEnd else { throw ScoreError.invalid("ZIP 目录越界。") }
        }
        guard cursor == directoryEnd else { throw ScoreError.invalid("ZIP 目录长度不匹配。") }
        return result
    }

    public static func write(_ entries: [String: Data]) throws -> Data {
        guard entries.count < 10_000, entries.values.reduce(0, { $0 + $1.count }) <= maximumSize else { throw ScoreError.invalid("工程文件过大。") }
        var data = Data(); var directory = Data()
        for path in entries.keys.sorted() {
            guard validPath(path), let body = entries[path], let name = path.data(using: .utf8), name.count < 65_536 else { throw ScoreError.invalid("无法保存工程文件名。") }
            let offset = UInt32(data.count); let length = UInt32(body.count); let check = crc(body)
            data.put(UInt32(0x04034b50)); data.put(UInt16(20)); data.put(UInt16(0x800)); data.put(UInt16(0)); data.put(UInt16(0)); data.put(UInt16(0))
            data.put(check); data.put(length); data.put(length); data.put(UInt16(name.count)); data.put(UInt16(0)); data.append(name); data.append(body)
            directory.put(UInt32(0x02014b50)); directory.put(UInt16(20)); directory.put(UInt16(20)); directory.put(UInt16(0x800)); directory.put(UInt16(0)); directory.put(UInt16(0)); directory.put(UInt16(0))
            directory.put(check); directory.put(length); directory.put(length); directory.put(UInt16(name.count)); directory.put(UInt16(0)); directory.put(UInt16(0)); directory.put(UInt16(0)); directory.put(UInt16(0)); directory.put(UInt32(0)); directory.put(offset); directory.append(name)
        }
        let offset = UInt32(data.count); data.append(directory)
        data.put(UInt32(0x06054b50)); data.put(UInt16(0)); data.put(UInt16(0)); data.put(UInt16(entries.count)); data.put(UInt16(entries.count)); data.put(UInt32(directory.count)); data.put(offset); data.put(UInt16(0))
        return data
    }

    public static func validPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, part in
            part != "." && part != ".." && (!part.isEmpty || (index == components.count - 1 && path.hasSuffix("/")))
        }
    }

    private static func inflateRaw(_ input: Data, size: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ScoreError.invalid("无法初始化解压器。") }
        defer { inflateEnd(&stream) }
        var output = Data(count: max(1, size))
        let capacity = output.count
        let status: Int32 = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.total_in == input.count else { throw ScoreError.invalid("压缩内容与声明的长度不一致。") }
        return output.prefix(size)
    }
    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    private static func slice(_ data: Data, _ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { throw ScoreError.invalid("压缩包数据越界。") }
        return data.subdata(in: offset..<(offset + length))
    }
    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        let d = try slice(data, offset, 2); return UInt16(d[0]) | UInt16(d[1]) << 8
    }
    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        let d = try slice(data, offset, 4); return UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
