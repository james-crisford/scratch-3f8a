---
name: ios-dev-guidelines
description: Context-aware routing to Swift/iOS development patterns, architecture, and best practices. Use when working with .swift files, ViewModels, refactoring, or discussing Swift/SwiftUI patterns.
---

# iOS Development Guidelines (Router)

Sourced and adapted from `anyproto/anytype-swift` (483★, real shipping iOS app).
Adapted for the PuttingLab project. Project-specific overrides noted inline.

## When auto-activated

- Working with `.swift` files
- Discussing ViewModels, architecture, refactoring
- Keywords: swift, swiftui, mvvm, async, await, refactor, sensor pipeline

## Critical rules (never violate)

1. **Never trim whitespace-only lines** — preserve blank lines with spaces/tabs exactly as they appear.
2. **Never edit generated files** — files marked `// Generated using ...`.
3. **Always update tests and mocks when refactoring** — search for all references.
4. **Never add comments** unless explicitly requested. Self-documenting code preferred.
5. **No hardcoded user-facing strings** — even for v1, wrap in a `Strings` enum for future localisation.

## SwiftUI fundamentals (WWDC24 line)

SwiftUI views are three things:
1. **Declarative** — describe the result, not the steps.
2. **Compositional** — small building blocks combine.
3. **State-driven** — UI updates automatically when state changes.

**Key insight:** views are VALUE TYPES (structs), not long-lived objects. Breaking views into subviews doesn't hurt performance — SwiftUI's diffing handles it efficiently.

## Common patterns

### MVVM ViewModel (Swift 6 / iOS 17+)

Use the modern `@Observable` macro, NOT `ObservableObject`:

```swift
@Observable
@MainActor
final class StrokeSessionViewModel {
    var phase: StrokePhase = .arm
    var lastResult: StrokeResult?
    var calibration: CalibrationProfile

    private let motion: MotionService
    private let detector: ImpactDetector

    init(motion: MotionService, detector: ImpactDetector, calibration: CalibrationProfile) {
        self.motion = motion
        self.detector = detector
        self.calibration = calibration
    }

    func start() async {
        // begin sensor streams
    }
}
```

### View pattern

```swift
struct PracticeView: View {
    @State private var viewModel = StrokeSessionViewModel(...)

    var body: some View {
        // ...
        .task { await viewModel.start() }
    }
}
```

### ViewModel init must be cheap

Defer heavy work to `.task`:

```swift
init(...) { /* assign only */ }

.task { await model.startSubscriptions() }
```

## Project structure (PuttingLab)

```
PuttingLab/
├── App/                  // PuttingLabApp.swift
├── Models/               // StrokeBuffer, CalibrationProfile, StrokeResult, PhaseState
├── Sensors/              // MotionManager, ARTrackingManager, StillnessDetector, StrokeDetector
├── Physics/              // ImpactDetector, FaceAngleComputer, DistanceModel, MarioKartAssist
├── Calibration/          // CalibrationCoordinator, CalibrationModel
├── UI/                   // PracticeView, ResultPanelView, RollAnimationView, ...
├── Storage/              // ProfileStore (UserDefaults wrapper)
└── Resources/            // Assets.xcassets
```

## Code style quick reference

- **Indentation:** 4 spaces (no tabs)
- **Naming:** PascalCase types, camelCase variables/functions
- **Extensions:** `TypeName+Feature.swift`
- **Property order:** `@State`/`@Observable` props → public → private → computed → init → methods
- **Enums:** explicit `switch` (compiler exhaustiveness warnings catch mistakes)

## Common past mistakes to avoid

- Autonomous committing without user request — never commit unprompted
- Wildcard file deletion (`rm *.swift`) — delete files explicitly, `ls` first
- Incomplete mock updates after refactoring — `rg "oldName" --type swift` then update everywhere

## Related skills

- `swift-modern-architecture` → Swift 6 + iOS 17+ idioms, forbidden-pattern list
- `swift-development` → build/test/deploy/lint workflows
- `ios-coremotion-arkit-sensors` → CoreMotion + ARKit + sensor fusion (project-custom)
- `golf-swing-game-design` → Mario Kart assist, calibration model (project-custom)

---

*Original source: github.com/anyproto/anytype-swift `.claude/skills/ios-dev-guidelines/`.*
