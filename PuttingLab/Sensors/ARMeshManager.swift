import ARKit
import Foundation
import RealityKit
import simd

/// LiDAR scene-reconstruction owner. Maintains a Swift-side cache
/// of every `ARMeshAnchor` the session reports, and exposes:
///
///   1. A floor-only triangle list (vertices + per-triangle normal +
///      area) suitable for rebuilding a green overlay `MeshDescriptor`
///      that follows the actual floor outline — not an axis-aligned
///      plane rectangle.
///   2. A live stats accessor (`currentStats()`) summarising total
///      floor area, total triangle count, and classification
///      breakdown.
///   3. A pull-style `floorMesh()` that returns a single combined
///      `MeshResource` for the green overlay. The Coordinator owns
///      the entity + AnchorEntity and rebuilds it from this when
///      the mesh changes.
///
/// `ARMeshAnchor` data lives in Metal buffers (`MTLBuffer`) for
/// shader use. We read them on CPU here — fine at ARKit's mesh
/// update cadence (~1-2 Hz, not per-frame). Filtering is by
/// `ARMeshClassification.floor`.
///
/// This class is `@MainActor`-isolated because every callsite
/// (ARSessionDelegate methods + the SwiftUI overlay rebuild) is on
/// the main thread. The mesh-anchor MTLBuffer reads themselves are
/// thread-safe value-copies; isolation matches the surrounding
/// Coordinator's contract.
@MainActor
final class ARMeshManager {

    /// Snapshot of a single `ARMeshAnchor` at last-update. We keep
    /// only what we need to rebuild the floor overlay — not the
    /// raw MTLBuffers, since those mutate in place as ARKit
    /// refines the mesh and we'd race.
    private struct MeshSnapshot {
        let id: UUID
        let transform: simd_float4x4
        /// All floor-classified triangles transformed to world frame.
        /// Stored as a flat vertex list (3 verts per triangle); the
        /// overlay mesh-descriptor uses sequential indexing.
        let floorVertices: [SIMD3<Float>]
        /// Cumulative classification counts for this anchor.
        let classCounts: [ARMeshClassification: Int]
        /// Floor-classified triangle area sum, in m².
        let floorArea: Float
    }

    private var snapshots: [UUID: MeshSnapshot] = [:]

    /// Number of distinct mesh anchors currently cached.
    var anchorCount: Int { snapshots.count }

    /// Number of floor-classified triangles across every cached
    /// anchor.
    var floorTriangleCount: Int {
        snapshots.values.reduce(0) { $0 + $1.floorVertices.count / 3 }
    }

    /// Total floor area in m² across every cached anchor.
    var floorAreaM2: Float {
        snapshots.values.reduce(0) { $0 + $1.floorArea }
    }

    /// Add or refresh a mesh anchor. Reads the anchor's geometry
    /// buffers on the CPU, extracts every face whose classification
    /// is `.floor`, transforms its vertices to world frame, and
    /// stores a snapshot. Returns true if floor-face count changed
    /// (so the caller knows whether to rebuild the overlay mesh).
    @discardableResult
    func updateAnchor(_ anchor: ARMeshAnchor) -> Bool {
        let snapshot = makeSnapshot(anchor)
        let prevTriangles = snapshots[anchor.identifier]?.floorVertices.count ?? -1
        snapshots[anchor.identifier] = snapshot
        return snapshot.floorVertices.count != prevTriangles
    }

    /// Drop a mesh anchor (didRemove). Returns true if it was
    /// cached (so the overlay needs rebuilding).
    @discardableResult
    func removeAnchor(_ identifier: UUID) -> Bool {
        snapshots.removeValue(forKey: identifier) != nil
    }

    /// Clear everything — used on session reset / interruption.
    func clear() {
        snapshots.removeAll(keepingCapacity: true)
    }

    /// Build a single `MeshResource` covering every floor-classified
    /// triangle across every cached anchor. Returns nil if no floor
    /// triangles are cached (e.g. first second of LiDAR warmup) so
    /// the caller can skip the overlay rebuild.
    ///
    /// Both faces of each triangle are emitted (front + back) so the
    /// overlay reads from above + below the floor plane in case the
    /// camera dips slightly low.
    func buildFloorMesh() -> MeshResource? {
        // Flatten every snapshot's floorVertices into one big list.
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(floorTriangleCount * 3)
        for snap in snapshots.values {
            positions.append(contentsOf: snap.floorVertices)
        }
        guard positions.count >= 3 else { return nil }

        // Generate sequential indices: 0,1,2 / 3,4,5 / 6,7,8 ...
        // For each triangle, emit front + back (6 indices per
        // triangle but only 3 positions — the back face just reverses
        // the winding so the same vertices are reused).
        var indices: [UInt32] = []
        indices.reserveCapacity(positions.count * 2)
        var i: UInt32 = 0
        while Int(i) + 3 <= positions.count {
            indices.append(i)
            indices.append(i + 1)
            indices.append(i + 2)
            // Back face — reverse winding so the same 3 vertices
            // are visible from the opposite side. RealityKit
            // back-face culls by default; this lets the overlay
            // show through if the user looks up at the floor plane
            // from a near-flush angle.
            indices.append(i)
            indices.append(i + 2)
            indices.append(i + 1)
            i += 3
        }

        var descriptor = MeshDescriptor(name: "lidar_floor")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Snapshot used for periodic `.meshStats` logger emission.
    /// Keys: `floor_area_m2`, `triangle_count`, `anchor_count`,
    /// `classification_breakdown_floor` … etc.
    func currentStats(lidarActive: Bool) -> [String: String] {
        var classTotals: [ARMeshClassification: Int] = [:]
        for snap in snapshots.values {
            for (cls, count) in snap.classCounts {
                classTotals[cls, default: 0] += count
            }
        }
        return [
            "floor_area_m2": String(format: "%.3f", floorAreaM2),
            "triangle_count_floor": "\(floorTriangleCount)",
            "anchor_count": "\(anchorCount)",
            "lidar_active": lidarActive ? "true" : "false",
            "class_floor":   "\(classTotals[.floor]   ?? 0)",
            "class_wall":    "\(classTotals[.wall]    ?? 0)",
            "class_ceiling": "\(classTotals[.ceiling] ?? 0)",
            "class_table":   "\(classTotals[.table]   ?? 0)",
            "class_seat":    "\(classTotals[.seat]    ?? 0)",
            "class_window":  "\(classTotals[.window]  ?? 0)",
            "class_door":    "\(classTotals[.door]    ?? 0)",
            "class_none":    "\(classTotals[.none]    ?? 0)",
        ]
    }

    // MARK: - Snapshot construction (private)

    private func makeSnapshot(_ anchor: ARMeshAnchor) -> MeshSnapshot {
        let geometry = anchor.geometry
        let transform = anchor.transform

        let vertexBuffer = geometry.vertices.buffer
        let faceBuffer = geometry.faces.buffer
        let classBuffer = geometry.classification?.buffer

        let vertexStride = geometry.vertices.stride
        let vertexOffset = geometry.vertices.offset
        let faceCount = geometry.faces.count
        let indicesPerFace = geometry.faces.indexCountPerPrimitive  // always 3

        // Defensive: missing classification buffer means ARKit hasn't
        // run scene classification yet (rare — fires within the first
        // second on LiDAR devices). Return an empty snapshot so we
        // don't crash; next update will catch the buffer.
        guard let classBuffer = classBuffer else {
            return MeshSnapshot(id: anchor.identifier,
                                transform: transform,
                                floorVertices: [],
                                classCounts: [:],
                                floorArea: 0)
        }
        guard indicesPerFace == 3 else {
            // Defensive: ARKit's ARMeshGeometry has always emitted
            // triangles. Anything else would be a future API change;
            // skip safely.
            return MeshSnapshot(id: anchor.identifier,
                                transform: transform,
                                floorVertices: [],
                                classCounts: [:],
                                floorArea: 0)
        }

        // Vertex reader — vertices are simd_float3 packed but stride
        // may include padding. Read via UnsafeRawPointer + offset
        // each access.
        let vertexBase = vertexBuffer.contents().advanced(by: vertexOffset)

        // Face index reader — index buffer holds UInt32 per index.
        let faceIndices = faceBuffer.contents()
            .bindMemory(to: UInt32.self, capacity: faceCount * 3)

        // Classification reader — one UInt8 per face.
        let classBytes = classBuffer.contents()
            .bindMemory(to: UInt8.self, capacity: faceCount)

        var floorVerts: [SIMD3<Float>] = []
        floorVerts.reserveCapacity(faceCount * 3)
        var classCounts: [ARMeshClassification: Int] = [:]
        var floorArea: Float = 0

        for f in 0..<faceCount {
            let cls = ARMeshClassification(rawValue: Int(classBytes[f])) ?? .none
            classCounts[cls, default: 0] += 1
            guard cls == .floor else { continue }

            let i0 = Int(faceIndices[f * 3 + 0])
            let i1 = Int(faceIndices[f * 3 + 1])
            let i2 = Int(faceIndices[f * 3 + 2])

            let v0 = readVertex(vertexBase, index: i0, stride: vertexStride)
            let v1 = readVertex(vertexBase, index: i1, stride: vertexStride)
            let v2 = readVertex(vertexBase, index: i2, stride: vertexStride)

            // Transform to world frame
            let w0 = transformPoint(v0, by: transform)
            let w1 = transformPoint(v1, by: transform)
            let w2 = transformPoint(v2, by: transform)
            floorVerts.append(w0)
            floorVerts.append(w1)
            floorVerts.append(w2)

            // Triangle area = ½ |cross|
            let edge1 = w1 - w0
            let edge2 = w2 - w0
            floorArea += simd_length(simd_cross(edge1, edge2)) * 0.5
        }

        return MeshSnapshot(id: anchor.identifier,
                            transform: transform,
                            floorVertices: floorVerts,
                            classCounts: classCounts,
                            floorArea: floorArea)
    }

    @inline(__always)
    private func readVertex(_ base: UnsafeMutableRawPointer,
                             index: Int,
                             stride: Int) -> SIMD3<Float> {
        // Each vertex is 3 × Float32 packed at the start of its
        // stride slot. Use a raw load to avoid alignment surprises.
        let ptr = base.advanced(by: index * stride)
            .assumingMemoryBound(to: Float.self)
        return SIMD3<Float>(ptr[0], ptr[1], ptr[2])
    }

    @inline(__always)
    private func transformPoint(_ p: SIMD3<Float>,
                                 by m: simd_float4x4) -> SIMD3<Float> {
        let v4 = m * SIMD4<Float>(p.x, p.y, p.z, 1.0)
        return SIMD3<Float>(v4.x, v4.y, v4.z)
    }
}
