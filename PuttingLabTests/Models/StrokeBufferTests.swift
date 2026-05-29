import Testing
@testable import PuttingLab

@Suite("StrokeBuffer")
struct StrokeBufferTests {

    @Test("starts empty")
    func startsEmpty() {
        let buffer = StrokeBuffer<Int>(capacity: 10)
        #expect(buffer.currentCount == 0)
        #expect(buffer.snapshot() == [])
        #expect(buffer.maxCapacity == 10)
    }

    @Test("respects insertion order under capacity")
    func chronologicalBelowCapacity() {
        let buffer = StrokeBuffer<Int>(capacity: 5)
        for i in 1...3 { buffer.append(i) }
        #expect(buffer.currentCount == 3)
        #expect(buffer.snapshot() == [1, 2, 3])
    }

    @Test("preserves chronological order after wrap")
    func chronologicalAfterWrap() {
        let buffer = StrokeBuffer<Int>(capacity: 3)
        for i in 1...5 { buffer.append(i) }
        #expect(buffer.currentCount == 3)
        #expect(buffer.snapshot() == [3, 4, 5])
    }

    @Test("count caps at capacity")
    func capacityCap() {
        let buffer = StrokeBuffer<Int>(capacity: 4)
        for i in 0..<100 { buffer.append(i) }
        #expect(buffer.currentCount == 4)
        let snap = buffer.snapshot()
        #expect(snap.count == 4)
        #expect(snap == [96, 97, 98, 99])
    }

    @Test("clear resets to empty without changing capacity")
    func clearResets() {
        let buffer = StrokeBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.clear()
        #expect(buffer.currentCount == 0)
        #expect(buffer.snapshot() == [])
        #expect(buffer.maxCapacity == 3)
        buffer.append(9)
        #expect(buffer.snapshot() == [9])
    }

    @Test("snapshot returns a value copy (not aliased)")
    func snapshotIsValueCopy() {
        let buffer = StrokeBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)
        var copy = buffer.snapshot()
        copy.append(99)
        #expect(buffer.snapshot() == [1, 2])
    }

    @Test("five-second ring at 100Hz holds 500 samples")
    func sizingForOurUseCase() {
        let buffer = StrokeBuffer<Int>(capacity: 500)
        for i in 0..<500 { buffer.append(i) }
        #expect(buffer.currentCount == 500)
        buffer.append(500)
        #expect(buffer.currentCount == 500)
        #expect(buffer.snapshot().first == 1)
        #expect(buffer.snapshot().last == 500)
    }
}
