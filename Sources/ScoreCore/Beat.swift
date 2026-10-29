import Foundation

/// An exact number of quarter-note beats. Invalid or overflowing input is rejected.
public struct Beat: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let n: Int64
    public let d: Int64

    public static let zero = Beat(unchecked: 0, 1)

    private init(unchecked n: Int64, _ d: Int64) { self.n = n; self.d = d }

    public init(_ n: Int64, _ d: Int64 = 1) throws {
        guard d > 0, n != .min else { throw ScoreError.invalid("拍值分母必须为正数。") }
        let divisor = Self.gcd(abs(n), d)
        self.n = n / divisor
        self.d = d / divisor
    }

    public var value: Double { Double(n) / Double(d) }
    public var description: String { "\(n)/\(d)" }

    public func adding(_ other: Beat) throws -> Beat {
        let common = Self.gcd(d, other.d)
        let a = n.multipliedReportingOverflow(by: other.d / common)
        let b = other.n.multipliedReportingOverflow(by: d / common)
        let sum = a.partialValue.addingReportingOverflow(b.partialValue)
        let denominator = d.multipliedReportingOverflow(by: other.d / common)
        guard !a.overflow, !b.overflow, !sum.overflow, !denominator.overflow else {
            throw ScoreError.invalid("曲谱拍值超出可表示范围。")
        }
        return try Beat(sum.partialValue, denominator.partialValue)
    }

    public func subtracting(_ other: Beat) throws -> Beat {
        try adding(Beat(-other.n, other.d))
    }

    public static func < (lhs: Beat, rhs: Beat) -> Bool {
        let a = lhs.n.multipliedFullWidth(by: rhs.d)
        let b = rhs.n.multipliedFullWidth(by: lhs.d)
        return a.high == b.high ? a.low < b.low : a.high < b.high
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a; var y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(Int64.self, forKey: .n), c.decode(Int64.self, forKey: .d))
    }
    private enum CodingKeys: String, CodingKey { case n, d }
}
