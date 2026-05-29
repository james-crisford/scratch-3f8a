import Foundation

final class StrokeBuffer<Element>: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Element?]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let lock = NSLock()

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var maxCapacity: Int { capacity }

    var currentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        var result: [Element] = []
        result.reserveCapacity(count)
        let startIndex = count < capacity ? 0 : writeIndex
        for i in 0..<count {
            let idx = (startIndex + i) % capacity
            if let v = storage[idx] { result.append(v) }
        }
        return result
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}
