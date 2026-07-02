// Cross-platform shim standing in for Apple's `simd` module so the
// production mechanics sources compile unmodified on Linux/Windows.
// Only the surface actually used by PuttingLab is provided (verified
// against every call site 2026-07-02): simd_quatd construction +
// .imag/.real access + simd_slerp, and length/dot/normalize/cross
// free functions. Quaternion arithmetic (multiply, act, inverse) is
// deliberately absent — production code does not use it.
//
// Numerical caveat: libm (glibc/ucrt vs Darwin) may differ in the last
// ulp, so parity checks against on-device outputs use tolerances,
// never exact equality.

#if canImport(Darwin)
#error("This shim must never build on Apple platforms — it would shadow the real simd module. Build the app via XcodeGen/xcodebuild; build this package only on Linux (Docker) or Windows.")
#endif

import Foundation

public struct simd_quatd: Equatable, Sendable {
    public var vector: SIMD4<Double>

    public init(ix: Double, iy: Double, iz: Double, r: Double) {
        self.vector = SIMD4(ix, iy, iz, r)
    }

    public init(vector: SIMD4<Double>) {
        self.vector = vector
    }

    /// Rotation of `angle` radians about `axis` (must be normalized) —
    /// matches Apple's simd_quatd(angle:axis:). Used by test fixtures.
    public init(angle: Double, axis: SIMD3<Double>) {
        let half = angle / 2
        let s = sin(half)
        self.vector = SIMD4(axis.x * s, axis.y * s, axis.z * s, cos(half))
    }

    public var imag: SIMD3<Double> { SIMD3(vector.x, vector.y, vector.z) }
    public var real: Double { vector.w }

    /// Hamilton product — matches Apple semantics. Used by test fixtures.
    public static func * (lhs: simd_quatd, rhs: simd_quatd) -> simd_quatd {
        let l = lhs.vector, r = rhs.vector
        return simd_quatd(
            ix: l.w * r.x + l.x * r.w + l.y * r.z - l.z * r.y,
            iy: l.w * r.y - l.x * r.z + l.y * r.w + l.z * r.x,
            iz: l.w * r.z + l.x * r.y - l.y * r.x + l.z * r.w,
            r: l.w * r.w - l.x * r.x - l.y * r.y - l.z * r.z
        )
    }
}

public struct simd_float4x4: Equatable, Sendable {
    public var c0: SIMD4<Float>, c1: SIMD4<Float>, c2: SIMD4<Float>, c3: SIMD4<Float>

    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        (c0, c1, c2, c3) = columns
    }

    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        (c0, c1, c2, c3)
    }
}

public func simd_length(_ v: SIMD3<Double>) -> Double { simd_dot(v, v).squareRoot() }
public func simd_length(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
public func simd_length(_ v: SIMD4<Double>) -> Double { (v * v).sum().squareRoot() }
public func simd_length(_ v: SIMD3<Float>) -> Float { simd_dot(v, v).squareRoot() }
public func simd_length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }

public func simd_dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
public func simd_dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a * b).sum() }
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
public func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a * b).sum() }

public func simd_normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { v / simd_length(v) }
public func simd_normalize(_ v: SIMD2<Double>) -> SIMD2<Double> { v / simd_length(v) }
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / simd_length(v) }

public func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

/// Shortest-arc spherical interpolation — matches Apple's simd_slerp.
public func simd_slerp(_ q0: simd_quatd, _ q1: simd_quatd, _ t: Double) -> simd_quatd {
    var dot = (q0.vector * q1.vector).sum()
    var v1 = q1.vector
    if dot < 0 { v1 = -v1; dot = -dot }
    if dot > 0.9995 {
        var v = q0.vector + (v1 - q0.vector) * t
        v /= (v * v).sum().squareRoot()
        return simd_quatd(vector: v)
    }
    let theta0 = acos(min(max(dot, -1.0), 1.0))
    let s0 = sin(theta0 * (1 - t)) / sin(theta0)
    let s1 = sin(theta0 * t) / sin(theta0)
    return simd_quatd(vector: q0.vector * s0 + v1 * s1)
}
