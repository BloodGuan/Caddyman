import Foundation
import XCTest
@testable import Caddyman

final class CaddyfileMigrationPreviewTests: XCTestCase {
    func testAppendsManagedRegionAndPreservesExistingTargetBytes() throws {
        let source = try makeDocument("""
        openclaw.example.com:58433 {
            reverse_proxy 127.0.0.1:58432
        }
        """)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let target = try makeDocument("# User-owned base config\n")
        defer { try? FileManager.default.removeItem(at: target.directory) }

        let preview = try CaddyfileMigrationPreview.make(source: source.document, target: target.document)
        let candidate = preview.candidateText

        XCTAssertTrue(preview.candidateData.starts(with: target.document.originalData))
        XCTAssertTrue(candidate.contains(CaddyfileDocument.managedStartMarker))
        XCTAssertTrue(candidate.contains("openclaw.example.com:58433"))
        XCTAssertTrue(candidate.contains(CaddyfileDocument.managedEndMarker))
        XCTAssertEqual(preview.sites.map(\.address), ["openclaw.example.com:58433"])
        XCTAssertTrue(preview.diffText.contains("+# BEGIN CADDYMAN MANAGED SITES"))
        XCTAssertTrue(preview.diffText.contains("+openclaw.example.com:58433 {"))
    }

    func testReplacesOnlyManagedBodyAndRedactsSecretsFromDiff() throws {
        let source = try makeDocument("""
        imported.example.com {
            tls {
                dns dnspod token "preview-only-secret"
            }
            reverse_proxy http://user:preview-password@127.0.0.1:58432
        }
        """)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let target = try makeDocument("""
        # Keep this line unchanged
        \(CaddyfileDocument.managedStartMarker)
        old.example.com {
            reverse_proxy 127.0.0.1:8000
        }
        \(CaddyfileDocument.managedEndMarker)
        # Keep this line too
        """)
        defer { try? FileManager.default.removeItem(at: target.directory) }

        let preview = try CaddyfileMigrationPreview.make(source: source.document, target: target.document)
        let oldBytes = target.document.originalData
        guard case .valid(_, let bodyRange, _) = target.document.managedRegion else {
            return XCTFail("Expected a valid managed region")
        }

        XCTAssertEqual(
            Data(preview.candidateData[..<bodyRange.lowerBound]),
            Data(oldBytes[..<bodyRange.lowerBound])
        )
        XCTAssertEqual(
            Data(preview.candidateData.suffix(oldBytes.count - bodyRange.upperBound)),
            Data(oldBytes[bodyRange.upperBound...])
        )
        XCTAssertTrue(preview.candidateText.contains("imported.example.com"))
        XCTAssertFalse(preview.candidateText.contains("old.example.com"))
        XCTAssertFalse(preview.diffText.contains("preview-only-secret"))
        XCTAssertFalse(preview.diffText.contains("preview-password"))
        XCTAssertTrue(preview.diffText.contains("dns dnspod token ••••••"))
        XCTAssertTrue(preview.diffText.contains("http://user:••••@127.0.0.1:58432"))
    }

    func testRejectsDuplicateHostnameEvenWhenPortsAndCaseDiffer() throws {
        let source = try makeDocument("""
        openclaw.example.com:58433 {
            reverse_proxy 127.0.0.1:58432
        }
        """)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let target = try makeDocument("""
        OPENCLAW.example.com:443 {
            reverse_proxy 127.0.0.1:8443
        }
        """)
        defer { try? FileManager.default.removeItem(at: target.directory) }

        XCTAssertThrowsError(try CaddyfileMigrationPreview.make(source: source.document, target: target.document)) { error in
            XCTAssertEqual(
                error as? CaddyfileMigrationPreviewError,
                .duplicateHostnames(["openclaw.example.com"])
            )
        }
    }

    func testIgnoresNestedGlobalOptionsWhenFindingExistingSites() throws {
        let source = try makeDocument("""
        new.example.com {
            reverse_proxy 127.0.0.1:8001
        }
        """)
        defer { try? FileManager.default.removeItem(at: source.directory) }
        let target = try makeDocument("""
        {
            admin 127.0.0.1:2019
            servers {
                protocols h1 h2
            }
        }
        existing.example.com {
            reverse_proxy 127.0.0.1:8000
        }
        """)
        defer { try? FileManager.default.removeItem(at: target.directory) }

        let existingSites = try CaddyfileDocument.parseSiteBlocks(
            in: target.document.content,
            allowNonSiteTopLevelContent: true
        )
        let preview = try CaddyfileMigrationPreview.make(source: source.document, target: target.document)

        XCTAssertEqual(existingSites.map(\.address), ["existing.example.com"])
        XCTAssertTrue(preview.candidateText.contains("servers {\n        protocols h1 h2\n"))
        XCTAssertTrue(preview.candidateText.contains("existing.example.com"))
        XCTAssertTrue(preview.candidateText.contains("new.example.com"))
    }

    func testRefusesSameFileMalformedMarkersAndUnsupportedSourceContent() throws {
        let valid = try makeDocument("same.example.com {\n    reverse_proxy 127.0.0.1:8000\n}\n")
        defer { try? FileManager.default.removeItem(at: valid.directory) }

        XCTAssertThrowsError(try CaddyfileMigrationPreview.make(source: valid.document, target: valid.document)) { error in
            XCTAssertEqual(error as? CaddyfileMigrationPreviewError, .sameSourceAndTarget)
        }

        let malformed = try makeDocument("\(CaddyfileDocument.managedStartMarker)\n")
        defer { try? FileManager.default.removeItem(at: malformed.directory) }
        let target = try makeDocument("# base\n")
        defer { try? FileManager.default.removeItem(at: target.directory) }

        XCTAssertThrowsError(try CaddyfileMigrationPreview.make(source: malformed.document, target: target.document)) { error in
            XCTAssertEqual(error as? CaddyfileMigrationPreviewError, .malformedSourceMarkers(.missingEndMarker))
        }

        let unsupported = try makeDocument("""
        {
            debug
        }
        same.example.com {
            reverse_proxy 127.0.0.1:8000
        }
        """)
        defer { try? FileManager.default.removeItem(at: unsupported.directory) }

        XCTAssertThrowsError(try CaddyfileMigrationPreview.make(source: unsupported.document, target: target.document)) { error in
            XCTAssertEqual(error as? CaddyfileMigrationPreviewError, .unsupportedSourceContent)
        }
    }

    private func makeDocument(_ contents: String) throws -> (document: CaddyfileDocument, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Caddyfile")
        try Data(contents.utf8).write(to: url)
        return (try CaddyfileDocument.read(from: url), directory)
    }
}

final class CaddyCandidateValidatorTests: XCTestCase {
    func testValidatorStreamsCandidateAndRedactsSecretsFromDiagnostics() async {
        let recorder = ProcessRequestRecorder()
        let runner = RecordingProcessRunner(
            recorder: recorder,
            result: ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "provision failed for token \"preview-secret\"",
                stdoutWasTruncated: false,
                stderrWasTruncated: false
            )
        )
        let validator = CaddyCandidateValidator(processRunner: runner)
        let candidate = Data("example.com {\n    tls { dns dnspod token \"preview-secret\" }\n}\n".utf8)
        let directory = URL(fileURLWithPath: "/tmp/caddy-working-directory", isDirectory: true)

        let result = await validator.validate(
            candidateData: candidate,
            binaryURL: URL(fileURLWithPath: "/opt/caddyman/caddy"),
            workingDirectoryURL: directory
        )

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.detail.contains("preview-secret"))
        XCTAssertTrue(result.detail.contains("••••••"))
        XCTAssertEqual(recorder.request?.arguments, ["validate", "--config", "-", "--adapter", "caddyfile"])
        XCTAssertEqual(recorder.request?.standardInput, candidate)
        XCTAssertEqual(recorder.request?.workingDirectoryURL, directory)
    }

    func testValidatorReportsSuccessWhenCaddyExitsSuccessfullyWithoutOutput() async {
        let runner = RecordingProcessRunner(
            recorder: ProcessRequestRecorder(),
            result: ProcessResult(
                exitCode: 0,
                stdout: "",
                stderr: "",
                stdoutWasTruncated: false,
                stderrWasTruncated: false
            )
        )
        let validator = CaddyCandidateValidator(processRunner: runner)

        let result = await validator.validate(
            candidateData: Data("localhost { respond ok }\n".utf8),
            binaryURL: URL(fileURLWithPath: "/opt/caddyman/caddy"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )

        XCTAssertTrue(result.isValid)
        XCTAssertFalse(result.detail.isEmpty)
    }

    func testValidatorInjectsSecretOnlyIntoChildEnvironmentAndRedactsItFromOutput() async {
        let secret = "12345,very_secret_token"
        let recorder = ProcessRequestRecorder()
        let runner = RecordingProcessRunner(
            recorder: recorder,
            result: ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "provider failed: \(secret)",
                stdoutWasTruncated: false,
                stderrWasTruncated: false
            )
        )
        let validator = CaddyCandidateValidator(processRunner: runner)
        let result = await validator.validate(
            candidateData: Data("example.com { tls { dns dnspod {env.DNSPOD_TOKEN} } }".utf8),
            binaryURL: URL(fileURLWithPath: "/opt/caddy"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            environment: ["DNSPOD_TOKEN": secret],
            sensitiveValues: [secret]
        )

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.detail.contains(secret))
        XCTAssertTrue(result.detail.contains("[REDACTED]"))
        XCTAssertEqual(recorder.request?.environment?["DNSPOD_TOKEN"], secret)
        XCTAssertFalse(recorder.request?.arguments.contains(secret) ?? false)
    }

    func testValidatorRejectsPublicAdminListenerAfterAdaptation() async {
        let recorder = ProcessRequestRecorder()
        let runner = RecordingProcessRunner(
            recorder: recorder,
            result: ProcessResult(exitCode: 0, stdout: "", stderr: "", stdoutWasTruncated: false, stderrWasTruncated: false),
            adaptResult: ProcessResult(exitCode: 0, stdout: #"{"admin":{"listen":":2019"}}"#,
                                       stderr: "", stdoutWasTruncated: false, stderrWasTruncated: false)
        )
        let validator = CaddyCandidateValidator(processRunner: runner)
        let result = await validator.validate(
            candidateData: Data("{ admin :2019 }".utf8),
            binaryURL: URL(fileURLWithPath: "/opt/caddy"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.detail.isEmpty)
        XCTAssertEqual(recorder.request?.arguments.first, "adapt")
        XCTAssertTrue(recorder.request?.environmentVariablesToRemove.contains("CADDY_ADMIN") == true)
    }

    func testAdminEndpointPolicyAllowsOnlyDefaultLocalListener() {
        XCTAssertNil(CaddyAdminEndpointPolicy.issue(in: Data(#"{"admin":{"listen":"localhost:2019"}}"#.utf8)))
        XCTAssertNil(CaddyAdminEndpointPolicy.issue(in: Data("{}".utf8)))
        XCTAssertNotNil(CaddyAdminEndpointPolicy.issue(in: Data(#"{"admin":{"listen":"0.0.0.0:2019"}}"#.utf8)))
        XCTAssertNotNil(CaddyAdminEndpointPolicy.issue(in: Data(#"{"admin":{"remote":{"listen":":2020"}}}"#.utf8)))
        XCTAssertNotNil(CaddyAdminEndpointPolicy.issue(in: Data(#"{"admin":{"disabled":true}}"#.utf8)))
    }
}

private final class ProcessRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: ProcessRequest?

    var request: ProcessRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: ProcessRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedRequest = request
    }
}

private struct RecordingProcessRunner: ProcessRunning {
    let recorder: ProcessRequestRecorder
    let result: ProcessResult
    var adaptResult = ProcessResult(exitCode: 0, stdout: "{}", stderr: "", stdoutWasTruncated: false, stderrWasTruncated: false)

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        recorder.record(request)
        return request.arguments.first == "adapt" ? adaptResult : result
    }
}
