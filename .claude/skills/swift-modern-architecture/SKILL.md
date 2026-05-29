---
name: swift-modern-architecture
description: Guide for building iOS apps using Swift 6, iOS 17+, SwiftUI, SwiftData, and modern concurrency patterns. Use when writing Swift/iOS code, designing app architecture, or modernizing legacy patterns. Prevents outdated patterns like Core Data, ObservableObject, DispatchQueue, NavigationView.
---

# Swift Modern Architecture Guide

Sourced from `pstuart/pstuart` (20★, `plugins/swift-modern-dev/skills/swift-modern-architecture/`).
**This is the canonical "what's the modern way to do X in Swift 6 + iOS 17+" reference.**

## Core architecture: MVVM with @Observable

### ViewModel pattern (Swift 6 / iOS 17+)

```swift
import SwiftUI

@Observable
@MainActor
final class FeatureViewModel {
    var items: [Item] = []
    var isLoading = false
    var errorMessage: String?

    private let service: ItemService

    init(service: ItemService) {
        self.service = service
    }

    func loadItems() async {
        isLoading = true
        defer { isLoading = false }

        do {
            items = try await service.fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

### View pattern

```swift
struct FeatureView: View {
    @State private var viewModel: FeatureViewModel

    init(service: ItemService) {
        self._viewModel = State(wrappedValue: FeatureViewModel(service: service))
    }

    var body: some View {
        NavigationStack {
            List(viewModel.items) { item in
                ItemRow(item: item)
            }
            .overlay {
                if viewModel.isLoading { ProgressView() }
            }
            .task { await viewModel.loadItems() }
        }
    }
}
```

## Navigation

Always use `NavigationStack` with typed paths:

```swift
@Observable
class Router {
    var path = NavigationPath()

    func navigate(to destination: AppDestination) {
        path.append(destination)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}

enum AppDestination: Hashable {
    case detail(Item)
    case settings
}
```

## Data persistence with SwiftData

```swift
@Model
class StrokeRecord {
    var distance: Double
    var faceAngle: Double
    var tempo: Double
    var createdAt: Date

    init(distance: Double, faceAngle: Double, tempo: Double) {
        self.distance = distance
        self.faceAngle = faceAngle
        self.tempo = tempo
        self.createdAt = .now
    }
}
```

For PuttingLab v1, prefer `UserDefaults` for the calibration profile (simpler) and add SwiftData only if/when we need session history.

## Concurrency

```swift
// Task groups for parallel work
await withTaskGroup(of: SensorReading.self) { group in
    for stream in streams {
        group.addTask { await stream.next() }
    }
    for await reading in group {
        process(reading)
    }
}

// MainActor for UI updates
@MainActor
func updateUI() { /* safe */ }

// Actor for thread-safe state
actor SensorBuffer {
    private var samples: [Sample] = []

    func append(_ sample: Sample) {
        samples.append(sample)
    }

    func snapshot() -> [Sample] {
        samples
    }
}
```

## Forbidden patterns (canonical list)

| Deprecated | Modern replacement |
|---|---|
| `ObservableObject` | `@Observable` macro |
| `@Published` | Direct properties on `@Observable` class |
| `@StateObject` | `@State` with `@Observable` value |
| `@ObservedObject` | Pass directly or `@Environment(Type.self)` |
| `@EnvironmentObject` | `@Environment(Type.self)` |
| `DispatchQueue.main.async` | `@MainActor` or `MainActor.run` |
| `NavigationView` | `NavigationStack` / `NavigationSplitView` |
| Core Data | SwiftData |
| `XCTest` (new tests) | Swift Testing (`@Test`, `@Suite`, `#expect`) |
| Completion handlers | `async/await` |
| `Combine` (new code) | `AsyncSequence` / observation |

## Testing with Swift Testing

```swift
import Testing

@Suite("StrokeViewModel")
struct StrokeViewModelTests {
    @Test("loads calibration successfully")
    func loadCalibration() async {
        let viewModel = StrokeViewModel(profile: .fixture)
        await viewModel.start()
        #expect(viewModel.calibration != nil)
    }

    @Test("handles missing calibration")
    func missingCalibration() async {
        let viewModel = StrokeViewModel(profile: nil)
        await viewModel.start()
        #expect(viewModel.phase == .needsCalibration)
    }
}
```

## When to deviate from this guide

For the PuttingLab project:
- **iOS minimum = 17.0** (locked decision) — all of the above is available.
- **SwiftData**: defer until v1.1. UserDefaults is sufficient for v1.
- **Combine**: not used. Prefer `AsyncSequence` or direct `@Observable` properties for sensor streams.
- **UIKit**: only via `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` for haptics.

---

*Original: github.com/pstuart/pstuart `plugins/swift-modern-dev/skills/swift-modern-architecture/`.*
