import Foundation
import ModelIO
import simd

/// Набор треугольников в мировых координатах (метры).
struct TriMesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var triangleCount: Int { indices.count / 3 }

    mutating func append(_ points: [SIMD3<Float>], _ idx: [UInt32]) {
        let base = UInt32(positions.count)
        positions.append(contentsOf: points)
        indices.append(contentsOf: idx.map { $0 + base })
    }

    /// Габариты в мм.
    var sizeMM: [Float]? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let d = (hi - lo) * MeshExport.scale
        return [d.x, d.y, d.z]
    }
}

enum MeshExport {
    /// Метры → миллиметры (SolidWorks и большинство CAD ждут мм).
    static let scale: Float = 1000

    // MARK: Чтение модели (USDZ из Object Capture)

    static func load(from url: URL) throws -> TriMesh {
        let asset = MDLAsset(url: url)
        var mesh = TriMesh()
        for i in 0..<asset.count {
            collect(asset.object(at: i), into: &mesh)
        }
        guard mesh.triangleCount > 0 else { throw ScanError.message("В модели не найдено треугольников") }
        return mesh
    }

    private static func collect(_ object: MDLObject, into mesh: inout TriMesh) {
        if let m = object as? MDLMesh {
            add(m, transform: MDLTransform.globalTransform(with: object, atTime: 0), into: &mesh)
        }
        for child in object.children.objects {
            collect(child, into: &mesh)
        }
    }

    private static func add(_ m: MDLMesh, transform: simd_float4x4, into mesh: inout TriMesh) {
        guard let attr = m.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(m.vertexCount)
        for v in 0..<m.vertexCount {
            let p = attr.dataStart.advanced(by: v * attr.stride).assumingMemoryBound(to: Float.self)
            let w = transform * SIMD4<Float>(p[0], p[1], p[2], 1)
            points.append(SIMD3<Float>(w.x, w.y, w.z))
        }
        var idx: [UInt32] = []
        for sub in (m.submeshes as? [MDLSubmesh]) ?? [] {
            guard sub.geometryType == .triangles else { continue }
            let buffer = sub.indexBuffer(asIndexType: .uInt32)
            let map = buffer.map()
            let p = map.bytes.assumingMemoryBound(to: UInt32.self)
            for k in 0..<sub.indexCount {
                idx.append(p[k])
            }
        }
        mesh.append(points, idx)
    }

    // MARK: Запись

    @discardableResult
    static func writeAll(_ mesh: TriMesh, folder: URL, baseName: String) throws -> [URL] {
        let stl = folder.appendingPathComponent(baseName + ".stl")
        let obj = folder.appendingPathComponent(baseName + ".obj")
        let ply = folder.appendingPathComponent(baseName + ".ply")
        try writeSTL(mesh, to: stl)
        try writeOBJ(mesh, to: obj)
        try writePLY(mesh, to: ply)
        return [stl, obj, ply]
    }

    static func writeSTL(_ m: TriMesh, to url: URL) throws {
        let n = m.triangleCount
        var data = Data(capacity: 84 + n * 50)
        var header = [UInt8](repeating: 0, count: 80)
        for (i, b) in Array("Scan3D binary STL, units: mm".utf8).enumerated() { header[i] = b }
        data.append(contentsOf: header)
        appendU32(&data, UInt32(n))
        for t in 0..<n {
            let a = m.positions[Int(m.indices[3 * t])] * scale
            let b = m.positions[Int(m.indices[3 * t + 1])] * scale
            let c = m.positions[Int(m.indices[3 * t + 2])] * scale
            var normal = simd_cross(b - a, c - a)
            let len = simd_length(normal)
            normal = len > 0 ? normal / len : SIMD3<Float>(0, 0, 0)
            appendVec(&data, normal)
            appendVec(&data, a)
            appendVec(&data, b)
            appendVec(&data, c)
            data.append(contentsOf: [0, 0])
        }
        try data.write(to: url, options: .atomic)
    }

    static func writeOBJ(_ m: TriMesh, to url: URL) throws {
        var s = "# Scan3D OBJ, units: mm\n"
        s.reserveCapacity(m.positions.count * 40 + m.triangleCount * 30)
        for p in m.positions {
            let q = p * scale
            s += "v \(q.x) \(q.y) \(q.z)\n"
        }
        for t in 0..<m.triangleCount {
            s += "f \(m.indices[3 * t] + 1) \(m.indices[3 * t + 1] + 1) \(m.indices[3 * t + 2] + 1)\n"
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writePLY(_ m: TriMesh, to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Scan3D, units: mm
        element vertex \(m.positions.count)
        property float x
        property float y
        property float z
        element face \(m.triangleCount)
        property list uchar int vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + m.positions.count * 12 + m.triangleCount * 13)
        for p in m.positions { appendVec(&data, p * scale) }
        for t in 0..<m.triangleCount {
            data.append(3)
            appendU32(&data, m.indices[3 * t])
            appendU32(&data, m.indices[3 * t + 1])
            appendU32(&data, m.indices[3 * t + 2])
        }
        try data.write(to: url, options: .atomic)
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func appendVec(_ d: inout Data, _ v: SIMD3<Float>) {
        appendU32(&d, v.x.bitPattern)
        appendU32(&d, v.y.bitPattern)
        appendU32(&d, v.z.bitPattern)
    }
}
