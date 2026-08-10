#if DEBUG
import Foundation

/// A tiny hand-rolled test harness.
///
/// Neither XCTest nor swift-testing is available on a Command Line Tools–only
/// machine, and pulling a package dependency in for the sake of assertions
/// isn't worth it for a suite this size — so this is the whole framework:
/// a collector you record expectations against, a registry of named cases, and
/// a runner that prints a report and returns an exit code.
///
/// Used by `TorrentFlinger --self-test` (debug builds only).

/// One test's expectation collector. Every `expect*` records a check; failures
/// accumulate rather than aborting, so a single run reports everything wrong.
final class TestCase {
    let name: String
    private(set) var checks = 0
    private(set) var failures: [String] = []

    init(name: String) { self.name = name }

    private func location(_ file: StaticString, _ line: UInt) -> String {
        "\(file):\(line)"
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !condition { failures.append("\(location(file, line)) \(message())") }
    }

    func equal<Value: Equatable>(_ actual: Value, _ expected: Value, _ context: String = "",
                                 file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        guard actual != expected else { return }
        let suffix = context.isEmpty ? "" : " — \(context)"
        failures.append("\(location(file, line)) expected \(render(expected)), got \(render(actual))\(suffix)")
    }

    func close(_ actual: Double, _ expected: Double, accuracy: Double = 0.0001,
               _ context: String = "", file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        guard abs(actual - expected) > accuracy else { return }
        let suffix = context.isEmpty ? "" : " — \(context)"
        failures.append("\(location(file, line)) expected ≈\(expected), got \(actual)\(suffix)")
    }

    func isNil<Value>(_ actual: Value?, _ context: String = "",
                      file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        guard let actual else { return }
        let suffix = context.isEmpty ? "" : " — \(context)"
        failures.append("\(location(file, line)) expected nil, got \(render(actual))\(suffix)")
    }

    /// Returns the unwrapped value, or nil after recording a failure — so a
    /// test can bail out early with `guard let x = t.unwrap(...) else { return }`.
    @discardableResult
    func unwrap<Value>(_ actual: Value?, _ context: String = "",
                       file: StaticString = #fileID, line: UInt = #line) -> Value? {
        checks += 1
        if let actual { return actual }
        let suffix = context.isEmpty ? "" : " — \(context)"
        failures.append("\(location(file, line)) expected a value, got nil\(suffix)")
        return nil
    }

    func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        failures.append("\(location(file, line)) \(message)")
    }

    private func render(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        return String(describing: value)
    }
}

/// A named test: an async, throwing closure handed a fresh collector.
struct TestEntry {
    let name: String
    let body: (TestCase) async throws -> Void

    init(_ name: String, _ body: @escaping (TestCase) async throws -> Void) {
        self.name = name
        self.body = body
    }
}

enum TestRunner {
    /// Runs `entries` (optionally filtered by a substring of the name),
    /// printing a per-test line and a summary. Returns a process exit code.
    static func run(_ entries: [TestEntry], filter: String? = nil) async -> Int32 {
        let selected = filter.map { needle in
            entries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        } ?? entries

        guard !selected.isEmpty else {
            print("No tests matched \(filter.map { "\"\($0)\"" } ?? "the filter").")
            return 1
        }

        print("TorrentFlinger self-tests")
        var totalChecks = 0
        var failed: [TestCase] = []
        let started = Date()

        for entry in selected {
            let test = TestCase(name: entry.name)
            do {
                try await entry.body(test)
            } catch {
                test.fail("threw \(error)")
            }
            totalChecks += test.checks
            if test.failures.isEmpty {
                print("  ✓ \(entry.name)  (\(test.checks) checks)")
            } else {
                failed.append(test)
                print("  ✗ \(entry.name)")
                for failure in test.failures { print("      \(failure)") }
            }
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        let summary = "\(selected.count) tests, \(totalChecks) checks, \(failed.count) failed  [\(elapsed)]"
        print(failed.isEmpty ? "\n\(summary)" : "\n\(summary)")
        return failed.isEmpty ? 0 : 1
    }
}
#endif
