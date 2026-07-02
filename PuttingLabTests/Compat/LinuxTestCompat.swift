import Foundation

// autoreleasepool is an ObjC-runtime construct that does not exist on
// Linux, where the harness runs the portable test subset (see repo-root
// Package.swift). The tests use it only to scope allocations; a direct
// call preserves semantics for value-type Swift code. Compiles to
// nothing on Apple platforms.
#if !canImport(Darwin)
@discardableResult
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
