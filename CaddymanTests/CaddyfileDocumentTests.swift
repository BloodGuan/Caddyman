import Foundation
import XCTest
@testable import Caddyman

final class CaddyfileDocumentTests: XCTestCase {
    func testFilePickerImportPathIsRelativeToSelectedCaddyfile() {
        let caddyfile = URL(fileURLWithPath: "/tmp/Caddyman Project/Caddyfile")
        let child = URL(fileURLWithPath: "/tmp/Caddyman Project/sites/app.caddy")
        let sibling = URL(fileURLWithPath: "/tmp/Other Project/shared.caddy")

        XCTAssertEqual(CaddyfileImportDirective.relativeReference(to: child, from: caddyfile), "sites/app.caddy")
        XCTAssertEqual(CaddyfileImportDirective.relativeReference(to: sibling, from: caddyfile), "../Other Project/shared.caddy")
    }

    func testTopLevelImportRemainsEditableWhenGlobHasNoMatches() throws {
        let document = try readDocument(contents: Data("""
        import missing/*.caddy
        example.com {
            import nested.caddy
        }
        """.utf8))

        XCTAssertEqual(document.imports.map(\.pathPattern), ["missing/*.caddy"])
        XCTAssertTrue(document.importedCaddyfiles.isEmpty)
    }

    func testDirectImportedSitesAreReadWithoutExpandingNestedImports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanImports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("import child.caddy\n".utf8).write(to: directory.appendingPathComponent("Caddyfile"))
        try Data("import grandchild.caddy\nchild.example.com {\n    reverse_proxy 127.0.0.1:9001\n}\n".utf8)
            .write(to: directory.appendingPathComponent("child.caddy"))
        try Data("grandchild.example.com {\n    reverse_proxy 127.0.0.1:9002\n}\n".utf8)
            .write(to: directory.appendingPathComponent("grandchild.caddy"))

        let document = try CaddyfileDocument.read(from: directory.appendingPathComponent("Caddyfile"))
        XCTAssertEqual(document.importedCaddyfiles.map(\.url.lastPathComponent), ["child.caddy"])
        XCTAssertEqual(document.importedCaddyfiles[0].siteBlocks.map(\.address), ["child.example.com"])
    }

    func testDetectsLFAndCRLFAndPreservesOriginalBytes() throws {
        for (newline, expectedEnding) in [("\n", CaddyfileLineEnding.lf), ("\r\n", .crlf)] {
            let lines = [
                "# user-owned config before Caddyman",
                "external.example.com {",
                "    reverse_proxy 127.0.0.1:9000",
                "}",
                CaddyfileDocument.managedStartMarker,
                "managed.example.com {",
                "    reverse_proxy 127.0.0.1:9001",
                "}",
                CaddyfileDocument.managedEndMarker,
                "# user-owned config after Caddyman",
                "",
            ]
            let bytes = Data(lines.joined(separator: newline).utf8)
            let document = try readDocument(contents: bytes)

            XCTAssertEqual(document.lineEnding, expectedEnding)
            XCTAssertEqual(document.originalData, bytes)
            XCTAssertEqual(document.content, String(decoding: bytes, as: UTF8.self))
            guard case .valid(let startMarkerRange, let bodyRange, let endMarkerRange) = document.managedRegion else {
                return XCTFail("Expected valid markers for \(expectedEnding)")
            }
            XCTAssertEqual(String(decoding: bytes[startMarkerRange], as: UTF8.self), CaddyfileDocument.managedStartMarker)
            XCTAssertEqual(String(decoding: bytes[bodyRange], as: UTF8.self), [
                "managed.example.com {",
                "    reverse_proxy 127.0.0.1:9001",
                "}",
                "",
            ].joined(separator: newline))
            XCTAssertEqual(String(decoding: bytes[endMarkerRange], as: UTF8.self), CaddyfileDocument.managedEndMarker)
            XCTAssertEqual(document.managedSites, [
                CaddyfileManagedSite(address: "managed.example.com", upstream: "127.0.0.1:9001"),
            ])
        }
    }

    func testDoesNotTreatUnmanagedSiteBlocksAsManagedSites() throws {
        let document = try readDocument(contents: Data("""
        external.example.com {
            reverse_proxy 127.0.0.1:9000
        }
        """.utf8))

        XCTAssertEqual(document.managedRegion, .absent)
        XCTAssertTrue(document.managedSites.isEmpty)
        XCTAssertEqual(document.managedRegionText, "")
    }

    func testParsesMultipleManagedSitesAndRedactsSensitivePreviewValues() throws {
        let source = [
            "outside.example.com {",
            "    reverse_proxy 127.0.0.1:7000",
            "}",
            CaddyfileDocument.managedStartMarker,
            "first.example.com {",
            "    # reverse_proxy 127.0.0.1:7001 is only a comment",
            "    tls {",
            "        dns dnspod token \"test-placeholder-secret\"",
            "    }",
            "    reverse_proxy 127.0.0.1:7001 # trailing comment",
            "}",
            "second.example.com {",
            "    reverse_proxy http://user:placeholder-password@127.0.0.1:7002",
            "}",
            CaddyfileDocument.managedEndMarker,
            "outside-again.example.com {",
            "    reverse_proxy 127.0.0.1:7003",
            "}",
            "",
        ].joined(separator: "\n")
        let originalData = Data(source.utf8)
        let document = try readDocument(contents: originalData)

        XCTAssertEqual(document.managedSites, [
            CaddyfileManagedSite(address: "first.example.com", upstream: "127.0.0.1:7001"),
            CaddyfileManagedSite(address: "second.example.com", upstream: "http://user:placeholder-password@127.0.0.1:7002"),
        ])
        XCTAssertEqual(
            document.managedSites[1].redactedUpstream,
            "http://user:••••@127.0.0.1:7002"
        )
        XCTAssertFalse(document.redactedManagedRegionText.contains("test-placeholder-secret"))
        XCTAssertFalse(document.redactedManagedRegionText.contains("placeholder-password"))
        XCTAssertTrue(document.redactedManagedRegionText.contains("http://user:••••@127.0.0.1:7002"))
        XCTAssertEqual(document.originalData, originalData)
        XCTAssertTrue(document.content.hasPrefix("outside.example.com"))
        XCTAssertTrue(document.content.hasSuffix("outside-again.example.com {\n    reverse_proxy 127.0.0.1:7003\n}\n"))
    }

    func testReportsMalformedManagedRegionMarkers() throws {
        let cases: [(String, CaddyfileManagedRegionIssue)] = [
            ("\(CaddyfileDocument.managedEndMarker)\n", .missingStartMarker),
            ("\(CaddyfileDocument.managedStartMarker)\n", .missingEndMarker),
            ("\(CaddyfileDocument.managedStartMarker)\n\(CaddyfileDocument.managedStartMarker)\n\(CaddyfileDocument.managedEndMarker)\n", .duplicateStartMarker),
            ("\(CaddyfileDocument.managedStartMarker)\n\(CaddyfileDocument.managedEndMarker)\n\(CaddyfileDocument.managedEndMarker)\n", .duplicateEndMarker),
            ("\(CaddyfileDocument.managedEndMarker)\n\(CaddyfileDocument.managedStartMarker)\n", .endBeforeStart),
            ("# BEGIN CADDYMAN MANAGED SITES extra\n\(CaddyfileDocument.managedEndMarker)\n", .malformedMarker),
        ]

        for (source, issue) in cases {
            let document = try readDocument(contents: Data(source.utf8))
            XCTAssertEqual(document.managedRegion, .malformed(issue), "Unexpected result for: \(source)")
            XCTAssertTrue(document.managedSites.isEmpty)
        }
    }

    func testRejectsInvalidUTF8() throws {
        let file = try makeTemporaryFile(contents: Data([0xFF, 0xFE]))
        defer { try? FileManager.default.removeItem(at: file.directory) }

        XCTAssertThrowsError(try CaddyfileDocument.read(from: file.url)) { error in
            XCTAssertEqual(error as? CaddyfileReadError, .invalidUTF8)
        }
    }

    func testAtomicWriterCreatesProtectedBackupAndReplacesOnlyTarget() throws {
        let original = Data("# User config\r\nsite.example.com {\r\n    respond ok\r\n}\r\n".utf8)
        let candidate = Data("# User config\r\nsite.example.com {\r\n    respond changed\r\n}\r\n".utf8)
        let file = try makeTemporaryFile(contents: original)
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let document = try CaddyfileDocument.read(from: file.url)

        let backup = try CaddyfileAtomicWriter().apply(
            candidateData: candidate,
            to: file.url,
            expectedSHA256: document.sha256
        )

        XCTAssertEqual(try Data(contentsOf: file.url), candidate)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertTrue(backup.lastPathComponent.contains("caddyman-backup-"))
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testAtomicWriterRefusesExternallyChangedTargetWithoutReplacingIt() throws {
        let original = Data("# first version\n".utf8)
        let external = Data("# externally updated\n".utf8)
        let file = try makeTemporaryFile(contents: original)
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let expectedHash = try CaddyfileDocument.read(from: file.url).sha256
        try external.write(to: file.url)

        XCTAssertThrowsError(try CaddyfileAtomicWriter().apply(
            candidateData: Data("# candidate\n".utf8),
            to: file.url,
            expectedSHA256: expectedHash
        )) { error in
            XCTAssertEqual(error as? CaddyfileAtomicWriteError, .targetChanged)
        }
        XCTAssertEqual(try Data(contentsOf: file.url), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.directory.path).count, 1)
    }

    func testSiteEditorKeepsUnmanagedBytesAndUsesKeychainPlaceholder() throws {
        let source = [
            "# Keep before",
            CaddyfileDocument.managedStartMarker,
            "outside.example.com {",
            "    respond untouched",
            "}",
            CaddyfileDocument.managedEndMarker,
            "# Keep after",
            "",
        ].joined(separator: "\r\n")
        let file = try makeTemporaryFile(contents: Data(source.utf8))
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let document = try CaddyfileDocument.read(from: file.url)
        let site = ReverseProxySite(
            hostname: "managed.example.com",
            upstream: "127.0.0.1:8123",
            tlsMode: .dnsPodDNS01,
            credentialMode: .keychain
        )

        let candidate = try CaddyfileSiteEditor.replacingManagedSites(in: document, with: [site])
        let candidateText = String(decoding: candidate, as: UTF8.self)
        let reloadedURL = file.directory.appendingPathComponent("Candidate")
        try candidate.write(to: reloadedURL)
        let reloaded = try CaddyfileDocument.read(from: reloadedURL)

        XCTAssertTrue(candidateText.contains("dns dnspod {env.DNSPOD_TOKEN}"))
        XCTAssertTrue(candidateText.contains("# CADDYMAN SITE BEGIN id=\(site.id.uuidString.lowercased()) credential=keychain"))
        XCTAssertTrue(candidateText.contains("outside.example.com {\r\n    respond untouched\r\n}"))
        XCTAssertTrue(candidateText.hasPrefix("# Keep before\r\n"))
        XCTAssertTrue(candidateText.hasSuffix("# Keep after\r\n"))
        XCTAssertEqual(try CaddyfileSiteEditor.readManagedSites(from: reloaded), [site])
    }

    func testSiteEditorUpdatesAndDeletesOnlyItsOwnMarkedBlocks() throws {
        let file = try makeTemporaryFile(contents: Data("# external\n".utf8))
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let initial = try CaddyfileDocument.read(from: file.url)
        let managed = ReverseProxySite(hostname: "managed.example.com", upstream: "127.0.0.1:8000")
        let withSite = try CaddyfileSiteEditor.replacingManagedSites(in: initial, with: [managed])
        let withSiteURL = file.directory.appendingPathComponent("WithSite")
        try withSite.write(to: withSiteURL)
        let document = try CaddyfileDocument.read(from: withSiteURL)
        let updated = ReverseProxySite(
            id: managed.id,
            hostname: managed.hostname,
            upstream: "127.0.0.1:9000",
            tlsMode: managed.tlsMode
        )
        let updatedData = try CaddyfileSiteEditor.replacingManagedSites(in: document, with: [updated])
        let updatedText = String(decoding: updatedData, as: UTF8.self)
        XCTAssertTrue(updatedText.contains("reverse_proxy 127.0.0.1:9000"))
        XCTAssertFalse(updatedText.contains("reverse_proxy 127.0.0.1:8000"))

        let updatedURL = file.directory.appendingPathComponent("Updated")
        try updatedData.write(to: updatedURL)
        let updatedDocument = try CaddyfileDocument.read(from: updatedURL)
        let deletedData = try CaddyfileSiteEditor.replacingManagedSites(in: updatedDocument, with: [])
        XCTAssertEqual(String(decoding: deletedData, as: UTF8.self), "# external\n\(CaddyfileDocument.managedStartMarker)\n\(CaddyfileDocument.managedEndMarker)\n")
    }

    func testSiteEditorRendersAndReadsLetsEncryptStagingCA() throws {
        let site = ReverseProxySite(
            hostname: "staging.example.com",
            upstream: "127.0.0.1:8123",
            tlsMode: .dnsPodDNS01,
            acmeEnvironment: .staging,
            credentialMode: .keychain
        )
        let rendered = try CaddyfileSiteEditor.render(site)
        XCTAssertTrue(rendered.contains("ca https://acme-staging-v02.api.letsencrypt.org/directory"))
        XCTAssertTrue(rendered.contains("dns dnspod {env.DNSPOD_TOKEN}"))

        let file = try makeTemporaryFile(contents: Data("# base\n".utf8))
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let document = try CaddyfileDocument.read(from: file.url)
        let candidate = try CaddyfileSiteEditor.replacingManagedSites(in: document, with: [site])
        let candidateURL = file.directory.appendingPathComponent("StagingCandidate")
        try candidate.write(to: candidateURL)
        let readback = try CaddyfileSiteEditor.readManagedSites(from: CaddyfileDocument.read(from: candidateURL))
        XCTAssertEqual(readback, [site])
    }

    func testSiteEditorRefusesToOverwriteManualDirectivesInsideMarkedSite() throws {
        let site = ReverseProxySite(hostname: "managed.example.com", upstream: "127.0.0.1:8123")
        let file = try makeTemporaryFile(contents: Data("# base\n".utf8))
        defer { try? FileManager.default.removeItem(at: file.directory) }
        let initial = try CaddyfileDocument.read(from: file.url)
        let generated = try CaddyfileSiteEditor.replacingManagedSites(in: initial, with: [site])
        let modified = String(decoding: generated, as: UTF8.self)
            .replacingOccurrences(of: "    reverse_proxy 127.0.0.1:8123", with: "    header X-Manual yes\n    reverse_proxy 127.0.0.1:8123")
        try Data(modified.utf8).write(to: file.url)
        let document = try CaddyfileDocument.read(from: file.url)

        XCTAssertThrowsError(try CaddyfileSiteEditor.readManagedSites(from: document)) { error in
            XCTAssertEqual(error as? CaddyfileSiteEditorError, .unsupportedManagedSiteContent)
        }
        XCTAssertThrowsError(try CaddyfileSiteEditor.replacingManagedSites(in: document, with: [site]))
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), modified)
    }

    @MainActor
    func testModelDetectsExternalChangesAndKeepsPreviousSnapshot() throws {
        let initialData = Data("site.example.com {\n    reverse_proxy 127.0.0.1:8000\n}\n".utf8)
        let file = try makeTemporaryFile(contents: initialData)
        defer { try? FileManager.default.removeItem(at: file.directory) }

        let model = CaddymanAppModel(
            caddyfilePathStore: MemoryCaddyfilePathStore(),
            caddyfileHashStore: MemoryCaddyfileHashStore()
        )
        model.setSelectedCaddyfilePath(file.url.path)
        guard case .loaded(let initialDocument) = model.caddyfileReadState else {
            return XCTFail("Expected the initial Caddyfile to load")
        }

        let updatedData = Data("site.example.com {\n    reverse_proxy 127.0.0.1:8001\n}\n".utf8)
        try updatedData.write(to: file.url)
        model.loadSelectedCaddyfile()

        XCTAssertTrue(model.caddyfileExternalChangeDetected)
        XCTAssertEqual(model.previousCaddyfileDocument?.sha256, initialDocument.sha256)
        guard case .loaded(let updatedDocument) = model.caddyfileReadState else {
            return XCTFail("Expected the externally changed Caddyfile to load")
        }
        XCTAssertEqual(updatedDocument.originalData, updatedData)

        XCTAssertThrowsError(try model.makeSiteChangePreview(sites: [ReverseProxySite(hostname: "new.example.com")])) { error in
            XCTAssertEqual(error as? SiteManagementError, .externalChange)
        }
        model.acceptExternalCaddyfileChanges()
        XCTAssertFalse(model.caddyfileExternalChangeDetected)
        XCTAssertNil(model.previousCaddyfileDocument)
        XCTAssertNoThrow(try model.makeSiteChangePreview(sites: [ReverseProxySite(hostname: "new.example.com")]))
    }

    private func readDocument(contents: Data) throws -> CaddyfileDocument {
        let file = try makeTemporaryFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: file.directory) }
        return try CaddyfileDocument.read(from: file.url)
    }

    private func makeTemporaryFile(contents: Data) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaddymanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Caddyfile")
        try contents.write(to: url)
        return (directory, url)
    }
}

final class ReverseProxySiteValidatorTests: XCTestCase {
    func testValidatesRequiredFieldsAndDuplicateHostnames() throws {
        let existing = ReverseProxySite(hostname: "example.com", upstream: "127.0.0.1:8000")
        let duplicate = ReverseProxySite(hostname: "EXAMPLE.com", upstream: "127.0.0.1:9000")

        XCTAssertThrowsError(try ReverseProxySiteValidator.validate(duplicate, existingSites: [existing])) { error in
            XCTAssertEqual(error as? SiteValidationIssue, .duplicateHostname("example.com"))
        }

        var invalidPort = ReverseProxySite(hostname: "other.example.com", upstream: "127.0.0.1:9000")
        invalidPort.port = "70000"
        XCTAssertThrowsError(try ReverseProxySiteValidator.validate(invalidPort, existingSites: [])) { error in
            XCTAssertEqual(error as? SiteValidationIssue, .invalidPort)
        }
    }

    func testDNSPodTokenFormatAndPlainTextRedaction() throws {
        var site = ReverseProxySite(
            hostname: "secure.example.com",
            upstream: "https://127.0.0.1:9443",
            tlsMode: .dnsPodDNS01,
            credentialMode: .plainText,
            plainTextToken: "12345,secret_value"
        )
        XCTAssertNoThrow(try ReverseProxySiteValidator.validate(site, existingSites: []))
        XCTAssertTrue(ReverseProxySiteValidator.isValidDNSPodToken(site.plainTextToken))

        let rendered = try CaddyfileSiteEditor.render(site)
        XCTAssertTrue(rendered.contains("dns dnspod \"12345,secret_value\""))
        XCTAssertFalse(CaddyfileDocument.redactingCredentials(in: rendered).contains("secret_value"))

        site.plainTextToken = "bad-token"
        XCTAssertThrowsError(try ReverseProxySiteValidator.validate(site, existingSites: [])) { error in
            XCTAssertEqual(error as? SiteValidationIssue, .invalidDNSPodToken)
        }
    }

    func testHTTPOnlySiteCannotUseACMEStaging() {
        let site = ReverseProxySite(
            hostname: "http.example.com",
            upstream: "127.0.0.1:8000",
            tlsMode: .httpOnly,
            acmeEnvironment: .staging
        )
        XCTAssertThrowsError(try ReverseProxySiteValidator.validate(site, existingSites: [])) { error in
            XCTAssertEqual(error as? SiteValidationIssue, .invalidACMEEnvironment)
        }
    }
}

@MainActor
private final class MemoryCaddyfilePathStore: CaddyfilePathStoring {
    private(set) var path = ""

    func loadPath() -> String { path }
    func savePath(_ path: String) { self.path = path }
}

@MainActor
private final class MemoryCaddyfileHashStore: CaddyfileHashStoring {
    private(set) var hash: String?

    func loadHash() -> String? { hash }
    func saveHash(_ hash: String?) { self.hash = hash }
}
