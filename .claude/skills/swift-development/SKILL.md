---
name: swift-development
description: Comprehensive Swift development for building, testing, and deploying iOS apps. Use when Claude needs to build Swift packages or Xcode projects from command line, run tests with Swift Testing or XCTest, manage iOS simulators with simctl, handle code signing, format or lint Swift code with SwiftFormat/SwiftLint, work with Swift Package Manager, implement Swift 6 concurrency, create SwiftUI views, or any iOS/macOS development task.
---

# Swift Development

Sourced from `aiskillstore/marketplace` (302★, hmohamed01/swift-development).

## Prerequisites

- macOS with Xcode 16+ installed (Swift 6)
- Xcode Command Line Tools: `xcode-select --install`
- Verify: `xcodebuild -version` and `swift --version`

## Build and test (Xcode project)

```bash
# Debug build for simulator
xcodebuild -workspace PuttingLab.xcworkspace -scheme PuttingLab \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Run all tests
xcodebuild test -workspace PuttingLab.xcworkspace -scheme PuttingLab \
  -destination 'platform=iOS Simulator,name=iPhone 15'

# Specific test
xcodebuild test -only-testing:PuttingLabTests/ImpactDetectorTests/testPeakDetection
```

## Simulator management

```bash
# List devices
xcrun simctl list devices

# Boot a specific simulator
xcrun simctl boot "iPhone 15"

# Install + launch
xcrun simctl install booted ./Build/Products/Debug-iphonesimulator/PuttingLab.app
xcrun simctl launch booted com.puttinglab.app

# Screenshot
xcrun simctl io booted screenshot ~/Desktop/sim.png
```

**Caveat for PuttingLab:** the iOS simulator does NOT have a real motion sensor or magnetometer. Sensor-pipeline testing MUST be on a physical device. Plan accordingly: simulator for UI, real iPhone for sensors.

## Format and lint

```bash
# Format
swiftformat .

# Lint
swiftlint

# Combined check (CI-style)
swiftformat --lint . && swiftlint
```

Recommended config files (drop in repo root): `.swiftformat`, `.swiftlint.yml`.

## Code signing + TestFlight (end of week 2)

```bash
# Archive for distribution
xcodebuild archive \
  -workspace PuttingLab.xcworkspace -scheme PuttingLab \
  -archivePath ./build/PuttingLab.xcarchive \
  -configuration Release \
  -destination 'generic/platform=iOS'

# Export IPA
xcodebuild -exportArchive \
  -archivePath ./build/PuttingLab.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist ./ExportOptions/app-store.plist
```

Upload to TestFlight via `xcrun altool` or via Xcode Organizer for first time (easier).

## Swift Testing framework (new tests prefer this over XCTest)

```swift
import Testing

@Suite("ImpactDetector")
struct ImpactDetectorTests {
    @Test("detects peak velocity in a clean stroke")
    func detectsPeak() async throws {
        let buffer = StrokeBuffer.fixture(.cleanStroke)
        let detector = ImpactDetector()
        let result = detector.detect(in: buffer)
        #expect(result.peakIndex == 47)
        #expect(result.confidence > 0.8)
    }

    @Test("handles missing peak gracefully")
    func noPeak() async throws {
        let buffer = StrokeBuffer.fixture(.noMotion)
        let detector = ImpactDetector()
        #expect(throws: ImpactDetectionError.noClearPeak) {
            try detector.detect(in: buffer)
        }
    }
}
```

## Official documentation

| Resource | URL |
|---|---|
| Swift docs | https://developer.apple.com/documentation/swift |
| SwiftUI | https://developer.apple.com/documentation/swiftui |
| CoreMotion | https://developer.apple.com/documentation/coremotion |
| ARKit | https://developer.apple.com/documentation/arkit |
| AVFoundation | https://developer.apple.com/documentation/avfoundation |
| Swift Testing | https://developer.apple.com/documentation/testing |

Apple documentation is a JavaScript SPA — WebFetch will not work on these URLs. For programmatic access, use GitHub sources:

| Source | URL |
|---|---|
| Swift Testing | https://github.com/apple/swift-testing |
| Swift Evolution | https://github.com/apple/swift-evolution/tree/main/proposals |

## Essential commands quick reference

| Task | Command |
|---|---|
| Build | `xcodebuild build -workspace ... -scheme ... -destination ...` |
| Test | `xcodebuild test -workspace ... -scheme ... -destination ...` |
| Format | `swiftformat .` |
| Lint | `swiftlint` |
| List sims | `xcrun simctl list devices` |
| Boot sim | `xcrun simctl boot "iPhone 15"` |
| Install on sim | `xcrun simctl install booted ./App.app` |
| Launch on sim | `xcrun simctl launch booted com.bundle.id` |

## Common destinations

```
'platform=iOS Simulator,name=iPhone 15'      # for builds + UI tests
'generic/platform=iOS'                        # for archives
'platform=iOS,id=<DEVICE_UDID>'              # for sensor tests on real device
```

---

*Original: github.com/aiskillstore/marketplace `skills/hmohamed01/swift-development/`. Includes reference subfiles in the original repo: swiftui-patterns.md, testing-patterns.md, concurrency.md, architecture.md, best-practices.md, spm.md, xcodebuild.md, simctl.md, code-signing.md, cicd.md, troubleshooting.md. Fetch from GitHub if deep detail needed.*
