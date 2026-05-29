---
name: ios-coremotion-arkit-sensors
description: CoreMotion + ARKit + sensor fusion patterns specific to the PuttingLab project. Use whenever working on the sensor pipeline — motion capture, stillness detection, stroke detection, impact detection, face angle computation, address-pose calibration, or any code involving CMMotionManager, CMDeviceMotion, ARWorldTrackingConfiguration, or sensor sync via mach_absolute_time.
---

# iOS CoreMotion + ARKit Sensor Patterns (PuttingLab)

This skill bundles all the sensor-fusion knowledge from the research (reports #1, #4, #5) and the spec. Read this BEFORE touching anything in `Sensors/` or `Physics/`.

## The headline architecture decisions

1. **Phone orientation in user's grip:** vertical in lead hand, screen-facing-user, back-camera-facing-direction-of-swing.
2. **Phone Y axis = putter shaft (vertical).** Phone X axis = putter face normal. This is the convention used throughout the code.
3. **No physical ball.** No microphone-based impact detection. Impact = peak forward hand velocity (Wii-Golf style).
4. **Magnetometer reference + ARKit drift correction together** give face-angle measurement that GolfGo doesn't have.

## CoreMotion setup

### The reference frame matters

Use `xMagneticNorthZVertical`. This auto-fuses magnetometer with gyro/accel and gives you a yaw value that's anchored to magnetic north — exactly what we need for the target-line reference.

```swift
let motionManager = CMMotionManager()
motionManager.deviceMotionUpdateInterval = 1.0 / 100.0  // 100Hz

guard motionManager.isDeviceMotionAvailable else {
    // Error: device doesn't support fused motion. Bail.
    return
}

motionManager.startDeviceMotionUpdates(
    using: .xMagneticNorthZVertical,
    to: OperationQueue.main
) { motion, error in
    guard let m = motion else { return }
    // m.attitude.yaw is magnetic-north-referenced
    // m.userAcceleration is gravity-removed
    // m.gravity is the unit gravity vector
    // m.rotationRate is gyro (rad/s)
    // m.timestamp is seconds since boot — convert to mach_absolute_time if needed
}
```

### Sample rate notes (research-confirmed)

- `CMDeviceMotion` at **100Hz** is the maximum on iPhone (200Hz raw available but fusion runs at 100).
- Latency to delivery: ~5–10ms.
- Drift on raw integrated yaw over a 1-second window: ~0.1–0.5°. Acceptable for the 1.5s putting stroke window IF anchored at address.

### Authorisation

Motion data on iPhone does not need user permission in iOS 17 (only required for iPad simulator or Apple Watch). No `NSMotionUsageDescription` required for a basic motion-only app. Verify before App Store submission.

## ARKit setup (drift-corrected absolute orientation)

```swift
import ARKit

let arSession = ARSession()
let config = ARWorldTrackingConfiguration()
config.planeDetection = []  // no plane detection in v1 — saves power
config.frameSemantics = []  // no body tracking, no people occlusion
arSession.run(config)

// Read camera pose at any time
let pose = arSession.currentFrame?.camera.transform  // 4x4 matrix
// Extract yaw: see Pose math below
```

### Drift envelope from research

- **iPhone 12+**: ~0.02 m/s positional drift, **sub-degree rotational drift** over typical sessions.
- Tracking degrades during **fast motion** (Apple's own term) — this is exactly the downswing.
- Recovery: ~100ms after motion ends.

### How to handle the fast-motion gap

During the stroke (especially the ~300ms downswing):
1. ARKit may lose tracking. Watch `ARCamera.trackingState`.
2. If lost, fall back to CMDeviceMotion's yaw for that window.
3. ARKit reconverges post-stroke. Re-anchor for the next stroke at next address pose.

```swift
if case .limited = arSession.currentFrame?.camera.trackingState {
    // Use motionManager.deviceMotion?.attitude.yaw instead
}
```

## The mach_absolute_time clock trick

CMDeviceMotion samples and ARFrames both expose a `timestamp` property in seconds since boot, but they share the underlying `mach_absolute_time` clock. To align them precisely:

```swift
import Foundation

// Convert mach_absolute_time ticks to seconds:
var info = mach_timebase_info_data_t()
mach_timebase_info(&info)
let nanosPerTick = Double(info.numer) / Double(info.denom)

func currentMachSeconds() -> TimeInterval {
    let ticks = mach_absolute_time()
    return Double(ticks) * nanosPerTick / 1_000_000_000.0
}

// CMDeviceMotion.timestamp is already in seconds since boot
// ARFrame.timestamp is also in seconds since boot
// They are directly comparable — same clock.
```

For PuttingLab, store every sample with its `.timestamp` and you can interpolate cleanly across both streams.

## The 5 sensor patterns we use

### 1. Ring buffer for ambient sample stream

```swift
final class RingBuffer<T> {
    private var storage: [T?]
    private var writeIndex = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    func append(_ element: T) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
    }

    func snapshot() -> [T] {
        // Return in chronological order
        var result: [T] = []
        for i in 0..<capacity {
            let idx = (writeIndex + i) % capacity
            if let v = storage[idx] { result.append(v) }
        }
        return result
    }
}
```

Use: ambient IMU stream goes into a 5-second ring buffer (500 samples at 100Hz).

### 2. Stillness detector (the address-pose lock)

The trigger condition for auto-address (locked in the spec):

```
for 800ms continuous:
    |deviceMotion.rotationRate| < 5°/s
    AND |deviceMotion.userAcceleration| < 0.2 m/s²
    AND phone within ±15° of vertical
        (check: dot(deviceMotion.gravity, [0,-1,0]) > 0.96 — gravity is mostly downward when phone is vertical)
```

When the condition holds for 800ms:
1. Snapshot `attitude.yaw` → `yaw_target_compass`
2. Snapshot ARKit yaw → `yaw_target_arkit`
3. Snapshot `gravity` → `gravity_reference`
4. Snapshot mach_absolute_time → `address_lock_time`
5. Fire `UIImpactFeedbackGenerator(.medium)` haptic tick

### 3. Stroke detector

Start: `|rotationRate|` > 30°/s for ≥50ms (debounced — must persist).
End: `|rotationRate|` < 30°/s for 300ms continuous, OR 2s hard cutoff from start.

### 4. PCA on userAcceleration to find swing-plane forward axis

```swift
func principalAxis(of accelerations: [SIMD3<Double>]) -> SIMD3<Double> {
    // Compute mean
    var mean = SIMD3<Double>(0, 0, 0)
    for a in accelerations { mean += a }
    mean /= Double(accelerations.count)

    // Compute covariance matrix (3x3)
    var cov = [[Double]](repeating: [0,0,0], count: 3)
    for a in accelerations {
        let d = a - mean
        for i in 0..<3 {
            for j in 0..<3 {
                cov[i][j] += d[i] * d[j]
            }
        }
    }

    // Find dominant eigenvector via power iteration (3 iterations is plenty for a 3x3)
    var v = SIMD3<Double>(1, 0, 0)
    for _ in 0..<10 {
        let next = SIMD3<Double>(
            cov[0][0]*v.x + cov[0][1]*v.y + cov[0][2]*v.z,
            cov[1][0]*v.x + cov[1][1]*v.y + cov[1][2]*v.z,
            cov[2][0]*v.x + cov[2][1]*v.y + cov[2][2]*v.z
        )
        v = simd_normalize(next)
    }
    return v
}
```

### 5. Parabolic interpolation for sub-sample peak detection

Given samples `y[i-1]`, `y[i]`, `y[i+1]` where `y[i]` is a local max:

```swift
func parabolicPeak(prev: Double, peak: Double, next: Double) -> Double {
    // Returns sub-sample offset from `peak`, in (-0.5, +0.5)
    let denom = prev - 2.0 * peak + next
    guard denom != 0 else { return 0 }
    return 0.5 * (prev - next) / denom
}

// Use to refine impact timestamp:
let offset = parabolicPeak(prev: vel[i-1], peak: vel[i], next: vel[i+1])
let impactTime = timestamps[i] + offset * sampleInterval
```

Same trick is used for the peak yaw value at impact — interpolate between the surrounding samples.

## The impact detection algorithm (full)

```swift
func detectImpact(in stroke: StrokeBuffer, calibration: CalibrationProfile) throws -> ImpactResult {
    // 1. Project acceleration onto user's calibrated forward axis
    let forward = calibration.swingPlaneAxis
    let projectedAccel = stroke.accelerations.map { simd_dot($0, forward) }

    // 2. Integrate to get forward velocity (with drift correction)
    let dt = 1.0 / 100.0
    var velocity = [Double](repeating: 0, count: projectedAccel.count)
    for i in 1..<projectedAccel.count {
        velocity[i] = velocity[i-1] + projectedAccel[i] * dt
    }
    // Drift correction: assume end-of-stroke velocity should be near 0
    let endDrift = velocity.last ?? 0
    let n = velocity.count
    for i in 0..<n {
        velocity[i] -= endDrift * Double(i) / Double(n - 1)
    }

    // 3. Smooth (5-point moving average)
    let smoothed = movingAverage(velocity, window: 5)

    // 4. Find peak
    guard let peakIdx = smoothed.enumerated().max(by: { $0.element < $1.element })?.offset,
          peakIdx > 0, peakIdx < smoothed.count - 1 else {
        throw ImpactError.noClearPeak
    }

    // 5. Sub-sample interpolation
    let offset = parabolicPeak(
        prev: smoothed[peakIdx - 1],
        peak: smoothed[peakIdx],
        next: smoothed[peakIdx + 1]
    )
    let impactTime = stroke.timestamps[peakIdx] + offset / 100.0

    // 6. Read interpolated attitude at impact
    let attitude = slerp(
        stroke.attitudes[peakIdx],
        stroke.attitudes[peakIdx + (offset > 0 ? 1 : -1)],
        abs(offset)
    )

    // 7. Compute face angle vs target
    let yawAtImpact = euler(attitude).yaw
    let faceAngleRaw = yawAtImpact - calibration.yawTargetArkit

    // 8. Subtract user's known systematic bias
    let faceAngle = faceAngleRaw - calibration.faceAngleBias

    return ImpactResult(
        timestamp: impactTime,
        peakVelocity: smoothed[peakIdx],
        faceAngle: faceAngle,
        attitude: attitude,
        confidence: confidence(smoothed, peakIdx)  // strength of peak vs noise
    )
}
```

## Sensor fusion: ARKit yaw vs CMDeviceMotion yaw

Both give yaw. They drift differently:
- CMDeviceMotion yaw (magnetic-north frame): low-frequency drift due to magnetometer noise + indoor magnetic interference.
- ARKit yaw: low drift in good lighting, can lose tracking in fast motion.

The fusion rule for PuttingLab:
1. **At address pose**: lock BOTH. They will diverge during the swing.
2. **During stroke**: prefer ARKit IF `trackingState == .normal` throughout. Else fall back to CMDeviceMotion.
3. **At impact**: read the chosen one.

Don't try to average them in real-time — they have different latencies. Pick one per stroke.

## Confidence scoring

Confidence in the impact result is downweighted by:
- ARKit lost tracking during >50% of the stroke
- Peak velocity < 0.3 m/s (user barely moved)
- Stroke duration < 200ms (probably a flick, not a real stroke)
- No clear peak (multiple local maxima within 90% of global max)

If confidence is below threshold, the Mario Kart assist snaps face_angle_displayed to "Square" — see `golf-swing-game-design` skill.

## Things NOT to do

- Don't run sensor streams on the main queue if doing heavy work. Use a dedicated background queue for analysis; only push results to main for UI.
- Don't call `motionManager.stopDeviceMotionUpdates()` between strokes — the cold-start latency to restart is 100–500ms. Keep it running, just stop appending to the active stroke buffer.
- Don't use `CMMotionManager.startMagnetometerUpdates` directly. Use the fused `xMagneticNorthZVertical` reference frame which already incorporates the magnetometer.
- Don't sample CoreMotion at >100Hz hoping for more precision — the underlying fusion runs at 100Hz, anything above is wasted.
- Don't use `Combine` for sensor streams in this codebase. Use `AsyncSequence` or direct closure callbacks.

## Devices to test on (research-confirmed)

- iPhone 12 (A14, no LiDAR) — must work; lowest target.
- iPhone 15 Pro (A17 Pro, LiDAR) — sanity check.
- Simulator — UI only, sensors will be silent/zero.

## References

Background research is in `docs/research/`:
- `research-1-imu-swing-physics.md` — physics envelope
- `research-4-arkit-realitykit-feasibility.md` — Apple stack feasibility
- `research-5-multisensor-swing-detection.md` — sensor fusion patterns
- `spec-putting-lab-v1-FINAL.md` — the spec this skill implements
