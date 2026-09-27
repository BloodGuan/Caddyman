import Foundation
import XCTest
@testable import Caddyman

final class CaddyInspectionTests: XCTestCase {
    func testModuleParserRecognizesDNSPodModule() throws {
        let data = Data(#"["admin.api", "dns.providers.dnspod"]"#.utf8)
        let modules = try CaddyModuleListParser.parseModuleIDs(from: data)

        XCTAssertTrue(modules.contains(CaddyModuleListParser.dnsPodModuleID))
    }

    func testModuleParserRecognizesMissingDNSPodModule() throws {
        let data = Data(#"["admin.api", "tls.issuance.acme"]"#.utf8)
        let modules = try CaddyModuleListParser.parseModuleIDs(from: data)

        XCTAssertFalse(modules.contains(CaddyModuleListParser.dnsPodModuleID))
    }

    func testModuleParserSupportsModuleObjects() throws {
        let data = Data(#"[{"id":"admin.api"},{"id":"dns.providers.dnspod"}]"#.utf8)
        let modules = try CaddyModuleListParser.parseModuleIDs(from: data)

        XCTAssertTrue(modules.contains(CaddyModuleListParser.dnsPodModuleID))
    }

    func testModuleParserDistinguishesEmptyInvalidAndUnsupportedOutput() {
        XCTAssertThrowsError(try CaddyModuleListParser.parseModuleIDs(from: Data())) { error in
            XCTAssertEqual(error as? CaddyModuleListParseError, .emptyOutput)
        }
        XCTAssertThrowsError(try CaddyModuleListParser.parseModuleIDs(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? CaddyModuleListParseError, .invalidJSON)
        }
        XCTAssertThrowsError(try CaddyModuleListParser.parseModuleIDs(from: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? CaddyModuleListParseError, .emptyModuleList)
        }
        XCTAssertThrowsError(try CaddyModuleListParser.parseModuleIDs(from: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? CaddyModuleListParseError, .unsupportedFormat)
        }
    }

    func testExplicitBinaryPathTakesPriorityOverHomebrewCandidates() throws {
        let checker = StubExecutableChecker(executablePaths: [
            "/custom/caddy",
            "/opt/homebrew/bin/caddy",
        ])
        let locator = CaddyBinaryLocator(executableChecker: checker)

        let result = try locator.locate(explicitPath: "/custom/caddy")

        XCTAssertEqual(result.path, "/custom/caddy")
    }

    func testAutomaticDiscoveryPrefersAppleSiliconHomebrewPath() throws {
        let checker = StubExecutableChecker(executablePaths: Set(CaddyBinaryLocator.homebrewPaths))
        let locator = CaddyBinaryLocator(executableChecker: checker)

        let result = try locator.locate(explicitPath: "")

        XCTAssertEqual(result.path, "/opt/homebrew/bin/caddy")
    }

    func testInvalidExplicitPathDoesNotFallBackToHomebrew() {
        let checker = StubExecutableChecker(executablePaths: ["/opt/homebrew/bin/caddy"])
        let locator = CaddyBinaryLocator(executableChecker: checker)

        XCTAssertThrowsError(try locator.locate(explicitPath: "/missing/caddy")) { error in
            XCTAssertEqual(error as? CaddyBinaryResolutionError, .notExecutable("/missing/caddy"))
        }
    }

    func testInspectorReportsVersionAndMissingPlugin() async throws {
        let url = URL(fileURLWithPath: "/custom/caddy")
        let version = ProcessResult(
            exitCode: 0,
            stdout: "v2.10.0\n",
            stderr: "",
            stdoutWasTruncated: false,
            stderrWasTruncated: false
        )
        let modules = ProcessResult(
            exitCode: 0,
            stdout: #"["admin.api", "tls.issuance.acme"]"#,
            stderr: "",
            stdoutWasTruncated: false,
            stderrWasTruncated: false
        )
        let inspector = CaddyBinaryInspector(processRunner: StubProcessRunner(
            versionResult: version,
            moduleResult: modules
        ))

        let info = try await inspector.inspect(binaryURL: url)

        XCTAssertEqual(info.version, "v2.10.0")
        XCTAssertEqual(info.dnsPodStatus, .missing)
        XCTAssertEqual(info.moduleCount, 2)
    }
}

private struct StubExecutableChecker: ExecutableChecking {
    let executablePaths: Set<String>

    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

private struct StubProcessRunner: ProcessRunning {
    let versionResult: ProcessResult
    let moduleResult: ProcessResult

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        request.arguments == ["version"] ? versionResult : moduleResult
    }
}
