import Foundation

enum CaddyfileSiteEditorError: Error, LocalizedError, Equatable {
    case managedRegionRequired
    case malformedSiteMarker
    case duplicateSiteID
    case siteBlockCouldNotBeRead
    case unsupportedManagedSiteContent
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .managedRegionRequired:
            L10n.text("Create or repair the Caddyman managed region before editing sites.")
        case .malformedSiteMarker:
            L10n.text("A Caddyman site marker is incomplete or malformed. No site changes were saved.")
        case .duplicateSiteID:
            L10n.text("The Caddyfile contains duplicate Caddyman site IDs. No site changes were saved.")
        case .siteBlockCouldNotBeRead:
            L10n.text("A Caddyman-managed site block cannot be safely interpreted. No site changes were saved.")
        case .unsupportedManagedSiteContent:
            L10n.text("This marked site contains manual changes. Caddyman will not overwrite them; edit the Caddyfile directly or restore the original generated block.")
        case .readbackMismatch:
            L10n.text("The saved Caddyfile did not read back as the proposed site configuration.")
        }
    }
}

struct CaddyfileSiteChangePreview: Equatable, Identifiable {
    let id = UUID()
    let targetURL: URL
    let targetSHA256: String
    let sites: [ReverseProxySite]
    let candidateData: Data
    let diffText: String
    let shouldVerifyManagedSitesOnReadback: Bool

    static func make(document: CaddyfileDocument, sites: [ReverseProxySite]) throws -> CaddyfileSiteChangePreview {
        let sites = sites.map { $0.normalized() }
        var seenSites: [ReverseProxySite] = []
        for site in sites {
            try ReverseProxySiteValidator.validate(site, existingSites: seenSites)
            seenSites.append(site)
        }
        let candidate = try CaddyfileSiteEditor.replacingManagedSites(in: document, with: sites)
        return CaddyfileSiteChangePreview(
            targetURL: document.sourceURL,
            targetSHA256: document.sha256,
            sites: sites,
            candidateData: candidate,
            diffText: CaddyfileMigrationPreview.unifiedDiff(
                from: document.redactedContent,
                to: CaddyfileDocument.redactingCredentials(in: String(decoding: candidate, as: UTF8.self))
            ),
            shouldVerifyManagedSitesOnReadback: true
        )
    }

    static func replacingSourceBlock(
        in document: CaddyfileDocument,
        block: CaddyfileSiteBlock,
        with replacement: String,
        preserving managedSites: [ReverseProxySite]
    ) throws -> CaddyfileSiteChangePreview {
        guard block.sourceRange.lowerBound >= 0,
              block.sourceRange.upperBound <= document.originalData.count else {
            throw CaddyfileSiteEditorError.siteBlockCouldNotBeRead
        }
        if !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = try CaddyfileDocument.parseSiteBlocks(
                in: replacement,
                allowNonSiteTopLevelContent: false
            )
            guard parsed.count == 1 else { throw CaddyfileSiteEditorError.siteBlockCouldNotBeRead }
        }

        return try replacingSourceRange(
            in: document,
            range: block.sourceRange,
            with: replacement,
            preserving: managedSites
        )
    }

    static func replacingSourceRange(
        in document: CaddyfileDocument,
        range: Range<Int>,
        with replacement: String,
        preserving managedSites: [ReverseProxySite]
    ) throws -> CaddyfileSiteChangePreview {
        guard range.lowerBound >= 0, range.upperBound <= document.originalData.count else {
            throw CaddyfileSiteEditorError.siteBlockCouldNotBeRead
        }
        var candidate = Data(document.originalData[..<range.lowerBound])
        candidate.append(contentsOf: replacement.utf8)
        candidate.append(document.originalData[range.upperBound...])
        let normalizedSites = managedSites.map { $0.normalized() }
        return CaddyfileSiteChangePreview(
            targetURL: document.sourceURL,
            targetSHA256: document.sha256,
            sites: normalizedSites,
            candidateData: candidate,
            diffText: CaddyfileMigrationPreview.unifiedDiff(
                from: document.redactedContent,
                to: CaddyfileDocument.redactingCredentials(in: String(decoding: candidate, as: UTF8.self))
            ),
            shouldVerifyManagedSitesOnReadback: false
        )
    }
}

enum CaddyfileSiteEditor {
    private static let beginPrefix = "# CADDYMAN SITE BEGIN id="
    private static let endPrefix = "# CADDYMAN SITE END id="

    static func readManagedSites(from document: CaddyfileDocument) throws -> [ReverseProxySite] {
        let entries = try managedEntries(in: document)
        return entries.map(\.site)
    }

    static func replacingManagedSites(in document: CaddyfileDocument, with sites: [ReverseProxySite]) throws -> Data {
        let newline: [UInt8] = document.lineEnding == .crlf ? [0x0D, 0x0A] : [0x0A]
        var uniqueSites: [UUID: ReverseProxySite] = [:]
        for site in sites {
            guard uniqueSites.updateValue(site, forKey: site.id) == nil else {
                throw CaddyfileSiteEditorError.duplicateSiteID
            }
        }

        switch document.managedRegion {
        case .malformed:
            throw CaddyfileSiteEditorError.managedRegionRequired
        case .absent:
            guard !sites.isEmpty else { return document.originalData }
            var candidate = document.originalData
            if let lastByte = candidate.last, lastByte != 0x0A { candidate.append(contentsOf: newline) }
            candidate.append(contentsOf: CaddyfileDocument.managedStartMarker.utf8)
            candidate.append(contentsOf: newline)
            for site in sorted(sites) {
                candidate.append(contentsOf: try render(site).utf8)
            }
            candidate.append(contentsOf: CaddyfileDocument.managedEndMarker.utf8)
            candidate.append(contentsOf: newline)
            return candidate
        case .valid(_, let bodyRange, _):
            let entries = try managedEntries(in: document)
            var output = Data(document.originalData[..<bodyRange.lowerBound])
            var cursor = bodyRange.lowerBound
            var existingIDs = Set<UUID>()

            for entry in entries {
                output.append(contentsOf: document.originalData[cursor..<entry.range.lowerBound])
                if let replacement = uniqueSites[entry.site.id] {
                    output.append(contentsOf: try render(replacement).utf8)
                    existingIDs.insert(replacement.id)
                }
                cursor = entry.range.upperBound
            }
            output.append(contentsOf: document.originalData[cursor..<bodyRange.upperBound])

            let newSites = sorted(sites.filter { !existingIDs.contains($0.id) })
            if !newSites.isEmpty {
                if output.last != 0x0A {
                    output.append(contentsOf: newline)
                }
                for site in newSites {
                    output.append(contentsOf: try render(site).utf8)
                }
            }
            output.append(contentsOf: document.originalData[bodyRange.upperBound...])
            return output
        }
    }

    static func render(_ site: ReverseProxySite) throws -> String {
        try ReverseProxySiteValidator.validate(site, existingSites: [])
        let host = site.normalizedHostname.contains(":") ? "[\(site.normalizedHostname)]" : site.normalizedHostname
        let port = site.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portSuffix = port.isEmpty ? "" : ":\(port)"
        let address = site.tlsMode == .httpOnly
            ? "http://\(host)\(portSuffix)"
            : "\(host)\(portSuffix)"
        let credentialMetadata: String
        switch site.tlsMode {
        case .httpOnly, .automaticHTTPS:
            credentialMetadata = "none"
        case .dnsPodDNS01:
            credentialMetadata = site.credentialMode.rawValue
        }

        var lines = [
            "\(beginPrefix)\(site.id.uuidString.lowercased()) credential=\(credentialMetadata) acme=\(site.acmeEnvironment.rawValue)",
            "\(address) {",
        ]
        if site.tlsMode == .dnsPodDNS01 || site.acmeEnvironment == .staging {
            let providerToken: String
            if site.credentialMode == .keychain {
                providerToken = "{env.DNSPOD_TOKEN}"
            } else {
                providerToken = "\"\(escapeCaddyString(site.plainTextToken.trimmingCharacters(in: .whitespacesAndNewlines)))\""
            }
            lines.append("    tls {")
            if let acmeDirectory = site.acmeEnvironment.directoryURL {
                lines.append("        ca \(acmeDirectory)")
            }
            if site.tlsMode == .dnsPodDNS01 {
                lines.append("        dns dnspod \(providerToken)")
            }
            lines.append("    }")
        }
        lines.append("    reverse_proxy \(site.upstream.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("}")
        lines.append("\(endPrefix)\(site.id.uuidString.lowercased())")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func managedEntries(in document: CaddyfileDocument) throws -> [ManagedEntry] {
        guard case .valid(_, let bodyRange, _) = document.managedRegion else {
            if case .absent = document.managedRegion { return [] }
            throw CaddyfileSiteEditorError.managedRegionRequired
        }

        let lines = lineRanges(in: document.originalData, restrictedTo: bodyRange)
        var entries: [ManagedEntry] = []
        var usedIDs = Set<UUID>()
        var index = 0
        while index < lines.count {
            let line = trimmedLine(document.originalData, lines[index])
            guard line.hasPrefix(beginPrefix) else {
                if line.hasPrefix(endPrefix) { throw CaddyfileSiteEditorError.malformedSiteMarker }
                index += 1
                continue
            }

            guard let marker = parseBeginMarker(line), usedIDs.insert(marker.id).inserted else {
                throw CaddyfileSiteEditorError.duplicateSiteID
            }
            let beginLine = lines[index]
            index += 1
            guard index < lines.count else { throw CaddyfileSiteEditorError.malformedSiteMarker }
            let blockStart = beginLine.fullRange.upperBound
            var endLine: ByteLine?
            while index < lines.count {
                let candidateLine = trimmedLine(document.originalData, lines[index])
                if candidateLine.hasPrefix(beginPrefix) {
                    throw CaddyfileSiteEditorError.malformedSiteMarker
                }
                if candidateLine.hasPrefix(endPrefix) {
                    guard candidateLine == "\(endPrefix)\(marker.id.uuidString.lowercased())" else {
                        throw CaddyfileSiteEditorError.malformedSiteMarker
                    }
                    endLine = lines[index]
                    index += 1
                    break
                }
                index += 1
            }
            guard let endLine else { throw CaddyfileSiteEditorError.malformedSiteMarker }
            let blockData = Data(document.originalData[blockStart..<endLine.contentRange.lowerBound])
            let site = try parseSite(
                id: marker.id,
                credentialMode: marker.credentialMode,
                acmeEnvironment: marker.acmeEnvironment,
                blockData: blockData
            )
            let originalBlock = String(decoding: blockData, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n")
            let generatedLines = try render(site).components(separatedBy: "\n")
            let expectedBlock = generatedLines.dropFirst().dropLast(2).joined(separator: "\n") + "\n"
            guard originalBlock == expectedBlock else {
                throw CaddyfileSiteEditorError.unsupportedManagedSiteContent
            }
            entries.append(ManagedEntry(site: site, range: beginLine.fullRange.lowerBound..<endLine.fullRange.upperBound))
        }
        return entries
    }

    private static func parseSite(
        id: UUID,
        credentialMode: DNSPodCredentialMode?,
        acmeEnvironment: ACMEEnvironment,
        blockData: Data
    ) throws -> ReverseProxySite {
        guard let text = String(data: blockData, encoding: .utf8),
              let block = try? CaddyfileDocument.parseSiteBlocks(in: text, allowNonSiteTopLevelContent: false),
              block.count == 1,
              let upstream = block[0].upstream,
              let address = parsedAddress(block[0].address) else {
            throw CaddyfileSiteEditorError.siteBlockCouldNotBeRead
        }

        let isDNSPod = text.range(of: #"(?im)^\s*dns\s+dnspod\b"#, options: .regularExpression) != nil
        let tlsMode: SiteTLSMode
        if address.isHTTPOnly {
            tlsMode = .httpOnly
        } else if isDNSPod {
            tlsMode = .dnsPodDNS01
        } else {
            tlsMode = .automaticHTTPS
        }

        let token = isDNSPod && credentialMode == .plainText ? parseDNSPodToken(from: text) ?? "" : ""
        return ReverseProxySite(
            id: id,
            hostname: address.hostname,
            port: address.port,
            upstream: upstream,
            tlsMode: tlsMode,
            acmeEnvironment: acmeEnvironment,
            credentialMode: credentialMode ?? .keychain,
            plainTextToken: token
        )
    }

    private static func parseDNSPodToken(from text: String) -> String? {
        let pattern = #"(?im)^\s*dns\s+dnspod\s+(?:"((?:\\.|[^"])*)"|([^\s#]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else {
            return nil
        }
        for group in [1, 2] where match.range(at: group).location != NSNotFound {
            guard let range = Range(match.range(at: group), in: text) else { continue }
            return String(text[range])
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return nil
    }

    private static func parsedAddress(_ source: String) -> (hostname: String, port: String, isHTTPOnly: Bool)? {
        let httpOnly = source.lowercased().hasPrefix("http://")
        let value = source.contains("://") ? source : "https://\(source)"
        guard let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty else { return nil }
        return (host, components.port.map(String.init) ?? "", httpOnly)
    }

    private static func parseBeginMarker(_ source: String) -> SiteMarker? {
        let components = source.split(separator: " ").map(String.init)
        guard (components.count == 6 || components.count == 7),
              components[0] == "#",
              components[1] == "CADDYMAN",
              components[2] == "SITE",
              components[3] == "BEGIN",
              components[4].hasPrefix("id=") else { return nil }
        let id = String(components[4].dropFirst(3))
        let credential = components[5].hasPrefix("credential=")
            ? String(components[5].dropFirst("credential=".count))
            : ""
        guard let uuid = UUID(uuidString: id) else { return nil }
        let mode: DNSPodCredentialMode?
        switch credential {
        case "none": mode = nil
        case DNSPodCredentialMode.keychain.rawValue: mode = .keychain
        case DNSPodCredentialMode.plainText.rawValue: mode = .plainText
        default: return nil
        }
        let acmeEnvironment: ACMEEnvironment
        if components.count == 6 {
            acmeEnvironment = .production
        } else {
            guard components[6].hasPrefix("acme="),
                  let parsed = ACMEEnvironment(rawValue: String(components[6].dropFirst("acme=".count))) else {
                return nil
            }
            acmeEnvironment = parsed
        }
        return SiteMarker(id: uuid, credentialMode: mode, acmeEnvironment: acmeEnvironment)
    }

    private static func sorted(_ sites: [ReverseProxySite]) -> [ReverseProxySite] {
        sites.sorted {
            if $0.normalizedHostname != $1.normalizedHostname {
                return $0.normalizedHostname < $1.normalizedHostname
            }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func escapeCaddyString(_ source: String) -> String {
        source.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func lineRanges(in data: Data, restrictedTo range: Range<Int>) -> [ByteLine] {
        guard !range.isEmpty else { return [] }
        var lines: [ByteLine] = []
        var start = range.lowerBound
        for index in range where data[index] == 0x0A {
            var contentEnd = index
            if contentEnd > start, data[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            lines.append(ByteLine(contentRange: start..<contentEnd, fullRange: start..<(index + 1)))
            start = index + 1
        }
        if start < range.upperBound {
            lines.append(ByteLine(contentRange: start..<range.upperBound, fullRange: start..<range.upperBound))
        }
        return lines
    }

    private static func trimmedLine(_ data: Data, _ line: ByteLine) -> String {
        String(decoding: data[line.contentRange], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private struct SiteMarker {
        let id: UUID
        let credentialMode: DNSPodCredentialMode?
        let acmeEnvironment: ACMEEnvironment
    }

    private struct ManagedEntry {
        let site: ReverseProxySite
        let range: Range<Int>
    }

    private struct ByteLine {
        let contentRange: Range<Int>
        let fullRange: Range<Int>
    }
}
