import Foundation
import XCTest
@testable import Caddyman

final class ProcessRunnerTests: XCTestCase {
    func testArgumentsArePassedLiterallyAndOutputIsTruncated() async throws {
        let runner = FoundationProcessRunner()
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "$HOME;still-plain-text"],
            outputLimitBytes: 6
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "$HOME;")
        XCTAssertTrue(result.stdoutWasTruncated)
    }

    func testTimeoutStopsLongRunningCommand() async {
        let runner = FoundationProcessRunner()

        do {
            _ = try await runner.run(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05
            ))
            XCTFail("Expected the command to time out.")
        } catch ProcessRunnerError.timedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStandardInputIsPassedToChildProcess() async throws {
        let runner = FoundationProcessRunner()
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/wc"),
            arguments: ["-c"],
            standardInput: Data("candidate config".utf8)
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "16")
    }

    func testChildEnvironmentCanRemoveAmbientDNSPodTokenAndAddInjectedToken() async throws {
        let runner = FoundationProcessRunner()
        let executable = URL(fileURLWithPath: "/usr/bin/printenv")
        let removed = try await runner.run(ProcessRequest(
            executableURL: executable,
            arguments: ["DNSPOD_TOKEN"],
            environmentVariablesToRemove: ["DNSPOD_TOKEN"]
        ))
        XCTAssertNotEqual(removed.exitCode, 0)
        XCTAssertTrue(removed.stdout.isEmpty)

        let secret = "12345,temporary_test_value"
        let injected = try await runner.run(ProcessRequest(
            executableURL: executable,
            arguments: ["DNSPOD_TOKEN"],
            environment: ["DNSPOD_TOKEN": secret],
            environmentVariablesToRemove: ["DNSPOD_TOKEN"]
        ))
        XCTAssertEqual(injected.exitCode, 0)
        XCTAssertEqual(injected.stdout.trimmingCharacters(in: .whitespacesAndNewlines), secret)
    }
}
