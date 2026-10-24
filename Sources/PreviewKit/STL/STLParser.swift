import Foundation

/// A triangle mesh read from STL. `vertices` holds 3 points per triangle (no sharing).
public struct STLMesh: Sendable {
    public var name: String?
    public var vertices: [SIMD3<Float>] = []
    public var isBinary = false

    public var triangleCount: Int { vertices.count / 3 }

    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = vertices.first else { return nil }
        var hi = lo
        for v in vertices {
            lo = SIMD3(Swift.min(lo.x, v.x), Swift.min(lo.y, v.y), Swift.min(lo.z, v.z))
            hi = SIMD3(Swift.max(hi.x, v.x), Swift.max(hi.y, v.y), Swift.max(hi.z, v.z))
        }
        return (lo, hi)
    }

    /// Face normal from the winding (STL's stored normals are often zero or wrong).
    public func normal(ofTriangle t: Int) -> SIMD3<Float> {
        let a = vertices[t * 3], b = vertices[t * 3 + 1], c = vertices[t * 3 + 2]
        let u = b - a, v = c - a
        let n = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let len = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        return len > 0 ? n / len : SIMD3(0, 0, 1)
    }

    /// Summary rows for previews.
    public var summary: [(String, String)] {
        var rows: [(String, String)] = [("Triangles", NumberFormatter.localizedString(from: NSNumber(value: triangleCount), number: .decimal)),
                                        ("Format", isBinary ? "Binary STL" : "ASCII STL")]
        if let b = bounds {
            let d = b.max - b.min
            rows.insert(("Size", String(format: "%.2f × %.2f × %.2f", d.x, d.y, d.z)), at: 0)
        }
        if let name, !name.isEmpty { rows.append(("Name", name)) }
        return rows
    }
}

/// Reads ASCII and binary STL. A file is binary when its size matches `84 + 50 × count`
/// (many binary files start with "solid" too).
public enum STLParser {
    public enum ParseError: Error, Equatable { case empty, malformed }

    /// Meshes larger than this are refused (the preview would need gigabytes).
    public static let maxTriangles = 20_000_000

    public static func parse(_ data: Data) throws -> STLMesh {
        guard data.count >= 15 else { throw ParseError.empty }
        if isBinary(data) { return try parseBinary(data) }
        return try parseASCII(data)
    }

    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = data.withUnsafeBytes { raw -> Int in
            Int(raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian)
        }
        if 84 + count * 50 == data.count { return true }
        return !data.prefix(5).elementsEqual("solid".utf8)
    }

    static func parseBinary(_ data: Data) throws -> STLMesh {
        var mesh = STLMesh()
        mesh.isBinary = true
        try data.withUnsafeBytes { raw in
            let declared = Int(raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian)
            let available = (raw.count - 84) / 50
            let count = min(declared, available)
            guard count > 0 else { throw ParseError.empty }
            guard count <= maxTriangles else { throw ParseError.malformed }
            mesh.vertices.reserveCapacity(count * 3)
            for t in 0..<count {
                let base = 84 + t * 50 + 12
                for v in 0..<3 {
                    let o = base + v * 12
                    let x = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian)
                    let y = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self).littleEndian)
                    let z = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self).littleEndian)
                    mesh.vertices.append(SIMD3(x.isFinite ? x : 0, y.isFinite ? y : 0, z.isFinite ? z : 0))
                }
            }
        }
        let header = data.prefix(80)
        let name = String(decoding: header.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        mesh.name = name.isEmpty ? nil : name
        return mesh
    }

    static func parseASCII(_ data: Data) throws -> STLMesh {
        var mesh = STLMesh()
        let text = String(decoding: data, as: UTF8.self)
        var first = true
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if first {
                first = false
                if line.hasPrefix("solid") { mesh.name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            }
            guard line.hasPrefix("vertex") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4, let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else {
                throw ParseError.malformed
            }
            mesh.vertices.append(SIMD3(x, y, z))
            guard mesh.vertices.count <= maxTriangles * 3 else { throw ParseError.malformed }
        }
        // Drop a dangling partial triangle.
        mesh.vertices.removeLast(mesh.vertices.count % 3)
        guard !mesh.vertices.isEmpty else { throw ParseError.empty }
        return mesh
    }
}
