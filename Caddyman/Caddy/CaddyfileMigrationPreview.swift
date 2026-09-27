import Foundation

struct CaddyCandidateValidationResult: Equatable, Sendable {
    let isValid: Bool
    let detail: String
}

protocol CaddyCandidateValidating: Sendable {
    func validate(
        candidateData: Data,
        binaryURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String],
        sensitiveValues: [String]
    ) async -> CaddyCandidateValidationResult
}

struct CaddyCandidateValidator: CaddyCandidateValidating {
    private let processRunner: any ProcessRunning

    init(processRunner: any ProcessRunning = FoundationProcessRunner()) {
        self.processRunner = processRunner
    }

    func validate(
        candidateData: Data,
        binaryURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        sensitiveValues: [String] = []
    ) async -> CaddyCandidateValidationResult {
        do {
            let result = try await processRunner.run(ProcessRequest(
                executableURL: binaryURL,
                arguments: ["validate", "--config", "-", "--adapter", "caddyfile"],
                timeout: 30,
                standardInput: candidateData,
                workingDirectoryURL: workingDirectoryURL,
                environment: environment,
                environmentVariablesToRemove: ["DNSPOD_TOKEN", "CADDY_ADMIN"]
            ))

            guard result.exitCode == 0 else {
                let output = [result.stderr, result.stdout]
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = output.map { Self.redact($0, sensitiveValues: sensitiveValues) }
                    ?? L10n.format("Caddy validation failed with exit status %d.", Int(result.exitCode))
                return CaddyCandidateValidationResult(isValid: false, detail: detail)
            }

            let adapted = try await processRunner.run(ProcessRequest(
                executableURL: binaryURL,
                arguments: ["adapt", "--config", "-", "--adapter", "caddyfile"],
                timeout: 30,
                outputLimitBytes: 4 * 1024 * 1024,
                standardInput: candidateData,
                workingDirectoryURL: workingDirectoryURL,
                environment: environment,
                environmentVariablesToRemove: ["DNSPOD_TOKEN", "CADDY_ADMIN"]
            ))
            guard adapted.exitCode == 0, !adapted.stdoutWasTruncated else {
                let detail = adapted.stdoutWasTruncated
                    ? L10n.text("The adapted Caddy configuration is too large to inspect safely.")
                    : (adapted.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       ? L10n.text("Caddy could not inspect the adapted configuration.")
                       : adapted.stderr)
                return CaddyCandidateValidationResult(isValid: false,
                    detail: Self.redact(detail, sensitiveValues: sensitiveValues))
            }
            if let policyError = CaddyAdminEndpointPolicy.issue(in: Data(adapted.stdout.utf8)) {
                return CaddyCandidateValidationResult(isValid: false, detail: policyError)
            }

            let output = [result.stdout, result.stderr]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CaddyCandidateValidationResult(
                isValid: true,
                detail: output.map { Self.redact($0, sensitiveValues: sensitiveValues) }
                    ?? L10n.text("Caddy validated the candidate configuration successfully.")
            )
        } catch {
            return CaddyCandidateValidationResult(isValid: false, detail: error.localizedDescription)
        }
    }

    private static func redact(_ output: String, sensitiveValues: [String]) -> String {
        sensitiveValues.reduce(CaddyfileDocument.redactingCredentials(in: output)) { text, secret in
            guard !secret.isEmpty else { return text }
            return text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }
}

enum CaddyAdminEndpointPolicy {
    static func issue(in adaptedJSON: Data) -> String? {
        guard let config = try? JSONSerialization.jsonObject(with: adaptedJSON) as? [String: Any] else {
            return L10n.text("Caddy returned an unreadable adapted configuration.")
        }
        guard let admin = config["admin"] else { return nil }
        guard let settings = admin as? [String: Any],
              settings["remote"] == nil,
              settings["disabled"] as? Bool != true else {
            return L10n.text("Caddyman requires the Admin API on the default local port 2019. Remove remote or disabled admin settings from the Caddyfile.")
        }
        guard let listen = settings["listen"] else { return nil }
        guard let address = listen as? String,
              ["localhost:2019", "127.0.0.1:2019"].contains(address.lowercased()) else {
            return L10n.text("Caddyman requires the Admin API on the default local port 2019. Remove remote or disabled admin settings from the Caddyfile.")
        }
        return nil
    }
}

enum CaddyfileMigrationPreviewError: Error, Equatable, LocalizedError {
    case sameSourceAndTarget
    case sourceHasNoSites
    case unsupportedSourceContent
    case unbalancedBlocks
    case malformedSourceMarkers(CaddyfileManagedRegionIssue)
    case malformedTargetMarkers(CaddyfileManagedRegionIssue)
    case duplicateHostnames([String])

    var errorDescription: String? {
        switch self {
        case .sameSourceAndTarget:
            L10n.text("Choose a different source and target Caddyfile.")
        case .sourceHasNoSites:
            L10n.text("The source file does not contain any importable site blocks.")
        case .unsupportedSourceContent:
            L10n.text("The source contains top-level content other than site blocks. Caddyman cannot safely place it in the managed region.")
        case .unbalancedBlocks:
            L10n.text("A Caddyfile block is incomplete or has unbalanced braces.")
        case .malformedSourceMarkers(let issue):
            L10n.format("The source managed-region markers are invalid: %@", issue.title)
        case .malformedTargetMarkers(let issue):
            L10n.format("The target managed-region markers are invalid: %@", issue.title)
        case .duplicateHostnames(let hostnames):
            L10n.format("Duplicate hostnames found: %@", hostnames.joined(separator: ", "))
        }
    }
}

struct CaddyfileMigrationPreview: Equatable, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let targetURL: URL
    let targetSHA256: String
    let sites: [CaddyfileManagedSite]
    let candidateData: Data
    let diffText: String

    var candidateText: String {
        String(decoding: candidateData, as: UTF8.self)
    }

    static func make(
        source: CaddyfileDocument,
        target: CaddyfileDocument
    ) throws -> CaddyfileMigrationPreview {
        guard source.sourceURL.standardizedFileURL != target.sourceURL.standardizedFileURL else {
            throw CaddyfileMigrationPreviewError.sameSourceAndTarget
        }

        let sourceContent: String
        switch source.managedRegion {
        case .valid:
            sourceContent = source.managedRegionText
        case .absent:
            sourceContent = source.content
        case .malformed(let issue):
            throw CaddyfileMigrationPreviewError.malformedSourceMarkers(issue)
        }

        let importedSites = try CaddyfileDocument.parseSiteBlocks(
            in: sourceContent,
            allowNonSiteTopLevelContent: false
        )
        guard !importedSites.isEmpty else {
            throw CaddyfileMigrationPreviewError.sourceHasNoSites
        }

        let existingSites: [CaddyfileManagedSite]
        do {
            switch target.managedRegion {
            case .malformed(let issue):
                throw CaddyfileMigrationPreviewError.malformedTargetMarkers(issue)
            case .absent, .valid:
                existingSites = try CaddyfileDocument.parseSiteBlocks(
                    in: target.content,
                    allowNonSiteTopLevelContent: true
                )
            }
        } catch let error as CaddyfileMigrationPreviewError {
            throw error
        } catch {
            throw CaddyfileMigrationPreviewError.unbalancedBlocks
        }

        let sourceHostnames = importedSites.flatMap(hostnames(in:))
        let targetHostnames = existingSites.flatMap(hostnames(in:))
        var duplicateHostnames = Set(sourceHostnames).intersection(Set(targetHostnames))
        let repeatedSourceHostnames = Dictionary(grouping: sourceHostnames, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
        duplicateHostnames.formUnion(repeatedSourceHostnames)
        guard duplicateHostnames.isEmpty else {
            throw CaddyfileMigrationPreviewError.duplicateHostnames(duplicateHostnames.sorted())
        }

        let newline = newlineBytes(for: target.lineEnding)
        let payload = Data(sourceContent.utf8)
        let candidate = merge(
            payload: payload,
            into: target,
            newline: newline
        )
        let candidateText = String(decoding: candidate, as: UTF8.self)
        let diffText = unifiedDiff(
            from: target.redactedContent,
            to: CaddyfileDocument.redactingCredentials(in: candidateText)
        )

        return CaddyfileMigrationPreview(
            sourceURL: source.sourceURL,
            targetURL: target.sourceURL,
            targetSHA256: target.sha256,
            sites: importedSites,
            candidateData: candidate,
            diffText: diffText
        )
    }

    private static func merge(
        payload: Data,
        into target: CaddyfileDocument,
        newline: [UInt8]
    ) -> Data {
        var managedPayload = payload
        if managedPayload.last != 0x0A {
            managedPayload.append(contentsOf: newline)
        }

        switch target.managedRegion {
        case .valid(_, let bodyRange, _):
            var candidate = Data(target.originalData[..<bodyRange.lowerBound])
            candidate.append(managedPayload)
            candidate.append(contentsOf: target.originalData[bodyRange.upperBound...])
            return candidate
        case .absent:
            var candidate = target.originalData
            if let lastByte = candidate.last, lastByte != 0x0A {
                candidate.append(contentsOf: newline)
            }
            candidate.append(contentsOf: CaddyfileDocument.managedStartMarker.utf8)
            candidate.append(contentsOf: newline)
            candidate.append(managedPayload)
            candidate.append(contentsOf: CaddyfileDocument.managedEndMarker.utf8)
            candidate.append(contentsOf: newline)
            return candidate
        case .malformed:
            return target.originalData
        }
    }

    private static func hostnames(in site: CaddyfileManagedSite) -> [String] {
        site.address.split(separator: ",", omittingEmptySubsequences: true).compactMap { rawAddress in
            var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if address.contains("://"), let url = URLComponents(string: address) {
                address = url.host ?? address
            } else if address.hasPrefix("["), let closingBracket = address.firstIndex(of: "]") {
                address = String(address[address.index(after: address.startIndex)..<closingBracket])
            } else if address.filter({ $0 == ":" }).count == 1, let colon = address.firstIndex(of: ":") {
                address = String(address[..<colon])
            }

            let hostname = address.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return hostname.isEmpty ? nil : hostname
        }
    }

    private static func newlineBytes(for lineEnding: CaddyfileLineEnding) -> [UInt8] {
        lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A]
    }

    static func unifiedDiff(from old: String, to new: String) -> String {
        let oldLines = diffLines(old)
        let newLines = diffLines(new)
        var commonPrefix = 0
        while commonPrefix < min(oldLines.count, newLines.count),
              oldLines[commonPrefix] == newLines[commonPrefix] {
            commonPrefix += 1
        }

        var commonSuffix = 0
        while commonSuffix < min(oldLines.count - commonPrefix, newLines.count - commonPrefix),
              oldLines[oldLines.count - 1 - commonSuffix] == newLines[newLines.count - 1 - commonSuffix] {
            commonSuffix += 1
        }

        let oldChangedEnd = oldLines.count - commonSuffix
        let newChangedEnd = newLines.count - commonSuffix
        let contextStart = max(0, commonPrefix - 3)
        let contextEnd = min(commonSuffix, 3)
        var result = ["--- selected Caddyfile", "+++ proposed Caddyfile"]
        let oldHunkCount = oldChangedEnd - contextStart + contextEnd
        let newHunkCount = newChangedEnd - contextStart + contextEnd
        result.append("@@ -\(contextStart + 1),\(oldHunkCount) +\(contextStart + 1),\(newHunkCount) @@")
        result.append(contentsOf: oldLines[contextStart..<commonPrefix].map { " \($0)" })
        result.append(contentsOf: oldLines[commonPrefix..<oldChangedEnd].map { "-\($0)" })
        result.append(contentsOf: newLines[commonPrefix..<newChangedEnd].map { "+\($0)" })
        if contextEnd > 0 {
            let oldContextStart = oldChangedEnd
            result.append(contentsOf: oldLines[oldContextStart..<(oldContextStart + contextEnd)].map { " \($0)" })
        }
        return result.joined(separator: "\n")
    }

    private static func diffLines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
