import Foundation
import simd
@testable import PuttingLab

// plab — off-device replay + simulation harness for PuttingLab.
// Compiles the app's own mechanics sources (zero-copy, see Package.swift)
// and drives them from recorded StrokeReplay JSONs or synthetic inputs.
//
// Subcommands:
//   replay <dir|files...>            full pipeline per stroke -> CSV on stdout
//   parity <dir|files...>            field-split parity gate vs stored on-device results
//   calfit <dir|files...>            S2: DistanceModel-vs-BallPhysics disagreement, quantified
//   sim --peak <mps> --face <deg> --cal <factor> [--cup <m>]   one-off putt sim

let VALID_GOLDEN_FIELDS = "timestamp, peakVelocity, snappedToSquare, snapReason (ImpactDetector unchanged since Build 7); faceAngleRaw stored values are compass-era and NOT comparable to HEAD recomputation"

func makeDecoder() -> JSONDecoder {
    // Mirrors StrokeReplayStore.load exactly (StrokeReplay.swift:396-402).
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
    return decoder
}

func collectJSONs(_ args: [String]) -> [URL] {
    var urls: [URL] = []
    let fm = FileManager.default
    for a in args {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: a, isDirectory: &isDir) else {
            FileHandle.standardError.write("warning: no such path: \(a)\n".data(using: .utf8)!)
            continue
        }
        if isDir.boolValue {
            if let e = fm.enumerator(at: URL(fileURLWithPath: a), includingPropertiesForKeys: nil) {
                for case let u as URL in e where u.pathExtension == "json" && u.lastPathComponent.hasPrefix("stroke-") {
                    urls.append(u)
                }
            }
        } else {
            urls.append(URL(fileURLWithPath: a))
        }
    }
    return urls.sorted { $0.path < $1.path }
}

func deg(_ r: Double) -> Double { r * 180.0 / Double.pi }
func f(_ v: Double, _ p: Int = 4) -> String { String(format: "%.\(p)f", v) }

struct Replayed {
    let url: URL
    let replay: StrokeReplay
    let result: ImpactResult
}

func replayAll(_ urls: [URL]) -> (ok: [Replayed], failed: [(URL, String)]) {
    let decoder = makeDecoder()
    var ok: [Replayed] = []
    var failed: [(URL, String)] = []
    for url in urls {
        do {
            let data = try Data(contentsOf: url)
            let replay = try decoder.decode(StrokeReplay.self, from: data)
            let window = replay.toStrokeWindow()
            let result = try ImpactDetector().detect(in: window)
            ok.append(Replayed(url: url, replay: replay, result: result))
        } catch {
            failed.append((url, "\(error)"))
        }
    }
    return (ok, failed)
}

// MARK: - replay

func cmdReplay(_ paths: [String]) {
    // Optional trailing options: --cal <factor> --cup <metres> add live-sim
    // columns (outcome + end position under HEAD physics at that factor).
    var files: [String] = []
    var cal: Double? = nil
    var cup = 2.0
    var shrink = 1.0
    var fwd = 0.0
    var ret = 0.6
    var i = 0
    while i < paths.count {
        if paths[i] == "--cal", i + 1 < paths.count {
            cal = Double(paths[i + 1]); i += 2
        } else if paths[i] == "--cup", i + 1 < paths.count {
            cup = Double(paths[i + 1]) ?? cup; i += 2
        } else if paths[i] == "--shrink", i + 1 < paths.count {
            shrink = Double(paths[i + 1]) ?? shrink; i += 2
        } else if paths[i] == "--fwd", i + 1 < paths.count {
            fwd = Double(paths[i + 1]) ?? fwd; i += 2
        } else if paths[i] == "--ret", i + 1 < paths.count {
            ret = Double(paths[i + 1]) ?? ret; i += 2
        } else {
            files.append(paths[i]); i += 1
        }
    }
    let (ok, failed) = replayAll(collectJSONs(files))
    var header = "file,schema,judgment,stored_peak,replayed_peak,stored_face_deg,replayed_face_deg_HEADPIPELINE,stored_snap,replayed_snap,replayed_conf"
    if cal != nil { header += ",sim_outcome,sim_roll_m,sim_lateral" }
    print(header)
    for r in ok {
        let sr = r.replay.result
        var cols: [String] = [
            r.url.lastPathComponent,
            "\(r.replay.schemaVersion)",
            r.replay.userImpactJudgment ?? "-",
            sr.map { f($0.peakVelocity) } ?? "-",
            f(r.result.peakVelocity),
            sr.map { f(deg($0.faceAngleRaw), 2) } ?? "-",
            f(deg(r.result.faceAngleRaw), 2),
            sr.map { String($0.snappedToSquare) } ?? "-",
            String(r.result.snappedToSquare),
            f(r.result.confidence, 3),
        ]
        if let cal {
            let sim = BallPhysics.simulatePutt(
                peakVelocity: r.result.peakVelocity,
                faceAngleRaw: r.result.faceAngleRaw,
                speedCalibration: cal,
                cupPosition: SIMD2<Double>(cup, 0),
                captureShrink: shrink,
                lipOutForwardBias: fwd,
                lipOutSpeedRetention: ret)
            let side: String
            if sim.endPosition.y > 0.02 {
                side = "LEFT " + f(sim.endPosition.y, 2) + "m"
            } else if sim.endPosition.y < -0.02 {
                side = "RIGHT " + f(-sim.endPosition.y, 2) + "m"
            } else {
                side = "online"
            }
            cols += ["\(sim.outcome)", f(simd_length(sim.endPosition), 2), side]
        }
        print(cols.joined(separator: ","))
    }
    for (u, e) in failed {
        FileHandle.standardError.write("FAILED \(u.lastPathComponent): \(e)\n".data(using: .utf8)!)
    }
}

// MARK: - parity

func cmdParity(_ paths: [String]) {
    let (ok, failed) = replayAll(collectJSONs(paths))
    var hardFailures: [String] = []
    var confidenceMax = 0.0
    var confidenceMismatches = 0
    var faceDeltaMax = 0.0
    var peakDeltaMax = 0.0
    var timestampDeltaMax = 0.0
    var compared = 0

    for r in ok {
        guard let stored = r.replay.result else { continue }
        compared += 1
        let name = r.url.lastPathComponent

        let peakDelta = abs(stored.peakVelocity - r.result.peakVelocity)
        peakDeltaMax = max(peakDeltaMax, peakDelta)
        let peakTol = max(1e-9 * abs(stored.peakVelocity), 1e-12)
        if peakDelta > peakTol {
            hardFailures.append("\(name): peakVelocity stored=\(stored.peakVelocity) replayed=\(r.result.peakVelocity)")
        }

        let tsDelta = abs(stored.timestamp - r.result.timestamp)
        timestampDeltaMax = max(timestampDeltaMax, tsDelta)
        if tsDelta > 1e-6 {
            hardFailures.append("\(name): timestamp stored=\(stored.timestamp) replayed=\(r.result.timestamp)")
        }

        if stored.snappedToSquare != r.result.snappedToSquare {
            hardFailures.append("\(name): snappedToSquare stored=\(stored.snappedToSquare) replayed=\(r.result.snappedToSquare)")
        }

        let replayedReason = r.result.snapReason.map { String(describing: $0) }
        if stored.snapReason != replayedReason {
            hardFailures.append("\(name): snapReason stored=\(stored.snapReason ?? "nil") replayed=\(replayedReason ?? "nil")")
        }

        let confDelta = abs(stored.confidence - r.result.confidence)
        confidenceMax = max(confidenceMax, confDelta)
        if confDelta > 1e-9 { confidenceMismatches += 1 }

        faceDeltaMax = max(faceDeltaMax, abs(deg(stored.faceAngleRaw - r.result.faceAngleRaw)))
    }

    print("=== plab parity (field-split gate) ===")
    print("replays decoded: \(ok.count), decode failures: \(failed.count), with stored result: \(compared)")
    print("HARD GATE  peakVelocity      max |delta| = \(peakDeltaMax)  \(peakDeltaMax <= 1e-9 ? "PASS" : "SEE FAILURES")")
    print("HARD GATE  timestamp         max |delta| = \(timestampDeltaMax) s")
    print("HARD GATE  snapped/snapReason exact match required")
    print("PROBE      confidence        max |delta| = \(confidenceMax), mismatches@1e-9 = \(confidenceMismatches)")
    print("REPORT     faceAngleRaw      max |delta| = \(f(faceDeltaMax, 2)) deg  (EXPECTED nonzero: stored=compass-era pipeline, replayed=HEAD press-attitude; not a defect)")
    print("valid golden fields: \(VALID_GOLDEN_FIELDS)")
    if hardFailures.isEmpty {
        print("RESULT: PARITY GREEN (\(compared)/\(compared) strokes)")
    } else {
        print("RESULT: \(hardFailures.count) HARD FAILURES")
        for h in hardFailures.prefix(20) { print("  " + h) }
        exit(1)
    }
    for (u, e) in failed {
        FileHandle.standardError.write("DECODE FAILED \(u.lastPathComponent): \(e)\n".data(using: .utf8)!)
    }
}

// MARK: - calfit (S2)

func straightRollMetres(peakVelocity: Double, factor: Double) -> Double {
    // Cup far away so nothing captures; face square -> pure +x roll.
    let sim = BallPhysics.simulatePutt(
        peakVelocity: peakVelocity,
        faceAngleRaw: 0,
        speedCalibration: factor,
        cupPosition: SIMD2<Double>(999, 0))
    return sim.endPosition.x
}

func refitFactor(peakVelocity: Double, targetMetres: Double) -> Double {
    let loBound = 0.01, hiBound = 500.0
    var lo = loBound, hi = hiBound
    for _ in 0..<80 {
        let mid = (lo + hi) / 2
        if straightRollMetres(peakVelocity: peakVelocity, factor: mid) < targetMetres {
            lo = mid
        } else {
            hi = mid
        }
    }
    let result = (lo + hi) / 2
    if result < loBound * 1.01 || result > hiBound * 0.99 {
        FileHandle.standardError.write(
            "warning: refitFactor hit search bound (\(result)) — result unreliable, physics may have shifted outside [\(loBound), \(hiBound)]\n"
                .data(using: .utf8)!)
    }
    return result
}

func cmdCalfit(_ paths: [String]) {
    let target = 10.0 // feet — calibration target distance
    let targetMetres = target / DistanceModel.mpsToFps

    // Implied mean calibration-stroke velocity for the REAL B79 profile:
    // CalibrationModel.compute inverts DistanceModel:
    //   factor = sqrt(target * decel / stimp) / (meanV * mpsToFps)
    let realFactor = 14.183068217897258 // data/raw/ar-bundles/b79/calibrationProfile.json
    let defaultFactor = 14.4            // ARPlacementView.defaultSpeedCalibration
    let requiredFps = (target * DistanceModel.decelerationConstant / DistanceModel.defaultStimp).squareRoot()
    let impliedMeanV = requiredFps / (realFactor * DistanceModel.mpsToFps)

    print("=== plab calfit — S2 speed-factor disagreement (all numbers from HEAD-compiled production code) ===")
    print("calibration target: \(f(target, 1)) ft = \(f(targetMetres, 3)) m; stimp \(f(DistanceModel.defaultStimp, 1))")
    print("real B79 device factor: \(realFactor)  ->  implied mean cal-stroke peak velocity: \(f(impliedMeanV, 4)) m/s")
    print("")
    print("factor,peakV_mps,distancemodel_raw_ft,ballphysics_roll_ft,ratio_sim_over_dm")

    var velocities: [Double] = [impliedMeanV]
    let (ok, _) = replayAll(collectJSONs(paths))
    let stored = ok.compactMap { $0.replay.result?.peakVelocity }.filter { $0 > 0.01 }
    if !stored.isEmpty {
        let mean = stored.reduce(0, +) / Double(stored.count)
        let sortedV = stored.sorted()
        velocities.append(sortedV[sortedV.count / 2]) // median
        velocities.append(mean)
    }

    var ratios: [Double] = []
    for factor in [defaultFactor, realFactor] {
        for v in velocities {
            let dm = DistanceModel(speedCalibrationFactor: factor, stimp: DistanceModel.defaultStimp, jitterFraction: 0)
                .compute(peakSpeedMps: v)
            let rollM = straightRollMetres(peakVelocity: v, factor: factor)
            let rollFt = rollM * DistanceModel.mpsToFps
            let ratio = dm.rawFeet > 1e-12 ? rollFt / dm.rawFeet : .nan
            if ratio.isFinite { ratios.append(ratio) }
            print("\(f(factor, 3)),\(f(v, 4)),\(f(dm.rawFeet, 3)),\(f(rollFt, 3)),\(f(ratio, 4))")
        }
    }

    let meanRatio = ratios.reduce(0, +) / Double(max(ratios.count, 1))
    let refit = refitFactor(peakVelocity: impliedMeanV, targetMetres: targetMetres)
    print("")
    print("mean ratio (BallPhysics roll / legacy DistanceModel raw): \(f(meanRatio, 4))")
    print("  -> a user calibrated via the LEGACY (pre-v4) objective saw the live sim deliver ~\(f(meanRatio * 100, 1))% of the calibration target")
    print("refit (harness-independent bisection): \(f(refit, 3)) (vs \(realFactor) legacy, ratio \(f(refit / realFactor, 3)))")

    // Cross-validate the SHIPPED v4 objective against this harness's
    // independent bisection — both must land on the same factor.
    let v4Factor = CalibrationModel.factorDelivering(
        targetMetres: targetMetres,
        meanPeakVelocity: impliedMeanV,
        stimpFeet: BallPhysics.defaultStimp)
    let agrees = abs(v4Factor - refit) < 1e-6
    print("production v4 objective (CalibrationModel.factorDelivering): \(f(v4Factor, 3)) — \(agrees ? "MATCHES harness refit" : "DISAGREES with harness refit \(f(refit, 3)) — INVESTIGATE")")
}

// MARK: - sim

func cmdSim(_ opts: [String: String]) {
    let peak = Double(opts["--peak"] ?? "") ?? 0.15
    let faceDeg = Double(opts["--face"] ?? "") ?? 0
    let cal = Double(opts["--cal"] ?? "") ?? 14.4
    let cup = Double(opts["--cup"] ?? "") ?? 2.0
    let shrink = Double(opts["--shrink"] ?? "") ?? 1.0
    let fwd = Double(opts["--fwd"] ?? "") ?? 0.0
    let ret = Double(opts["--ret"] ?? "") ?? 0.6
    let sim = BallPhysics.simulatePutt(
        peakVelocity: peak,
        faceAngleRaw: faceDeg * .pi / 180,
        speedCalibration: cal,
        cupPosition: SIMD2<Double>(cup, 0),
        captureShrink: shrink,
        lipOutForwardBias: fwd,
        lipOutSpeedRetention: ret)
    print("peak=\(f(peak,3)) m/s face=\(f(faceDeg,2))deg cal=\(f(cal,2)) cup=\(f(cup,2))m")
    print("outcome=\(sim.outcome) end=(\(f(sim.endPosition.x,3)), \(f(sim.endPosition.y,3))) m endSpeed=\(f(simd_length(sim.endVelocity),3)) m/s duration=\(f(sim.totalDuration,2))s pathPoints=\(sim.path.count)")
}

// MARK: - entry

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("""
    plab — PuttingLab off-device harness (compiles the app's real mechanics sources)
    usage:
      plab replay <dir|files...>
      plab parity <dir|files...>
      plab calfit <dir|files...>
      plab h5
      plab sim --peak 0.15 --face -3 --cal 14.4 [--cup 2.0]
    """)
    exit(2)
}
let rest = Array(args.dropFirst())
switch cmd {
case "replay": cmdReplay(rest)
case "parity": cmdParity(rest)
case "calfit": cmdCalfit(rest)
case "h5": cmdH5()
case "calfactor":
    // plab calfactor <files...> [--target-ft 8] — compute the TRUE v4
    // calibration factor from recorded cal strokes on the laptop (the
    // on-device value predates the S2 fix and is wrong).
    var calFiles: [String] = []
    var targetFt = 8.0
    var k = 0
    while k < rest.count {
        if rest[k] == "--target-ft", k + 1 < rest.count {
            targetFt = Double(rest[k + 1]) ?? targetFt; k += 2
        } else {
            calFiles.append(rest[k]); k += 1
        }
    }
    let (calOk, _) = replayAll(collectJSONs(calFiles))
    let peaks = calOk.map { $0.result }
        .filter { !$0.snappedToSquare && $0.peakVelocity >= ImpactDetector.minPeakVelocityMps
            && $0.peakVelocity <= BallPhysics.maxPlausiblePeakVelocity }
        .map { $0.peakVelocity }
    if peaks.isEmpty {
        print("{\"error\": \"no valid cal strokes (need peak >= 0.3, non-snapped)\", \"strokes\": \(calOk.count)}")
        exit(1)
    }
    let meanPeak = peaks.reduce(0, +) / Double(peaks.count)
    let factor = CalibrationModel.factorDelivering(
        targetMetres: targetFt * CalibrationModel.metresPerFoot,
        meanPeakVelocity: meanPeak,
        stimpFeet: BallPhysics.defaultStimp)
    print("{\"strokes\": \(peaks.count), \"mean_peak\": \(meanPeak), \"target_ft\": \(targetFt), \"factor\": \(factor)}")
case "live": MainActor.assumeIsolated { cmdLive(rest) }
case "fuzz":
    var fuzzOpts: [String: String] = [:]
    var j = 0
    while j + 1 < rest.count {
        if rest[j].hasPrefix("--") { fuzzOpts[rest[j]] = rest[j + 1]; j += 2 } else { j += 1 }
    }
    cmdFuzz(fuzzOpts)
case "sim":
    var opts: [String: String] = [:]
    var i = 0
    while i + 1 < rest.count {
        if rest[i].hasPrefix("--") { opts[rest[i]] = rest[i + 1]; i += 2 } else { i += 1 }
    }
    cmdSim(opts)
default:
    print("unknown subcommand: \(cmd)")
    exit(2)
}
