import CryptoKit
import Darwin
import Foundation

enum CaddyfileReadError: Error, LocalizedError, Equatable {
    case invalidUTF8
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            L10n.text("The Caddyfile is not valid UTF-8 text.")
        case .unreadable(let reason):
            L10n.format("Could not read the Caddyfile: %@", reason)
        }
    }
}

enum CaddyfileLineEnding: Equatable, Sendable {
    case lf
    case crlf
    case mixed
    case none
}

enum CaddyfileManagedRegionIssue: Equatable, Sendable {
    case missingStartMarker
    case missingEndMarker
    case duplicateStartMarker
    case duplicateEndMarker
    case endBeforeStart
    case malformedMarker

    var title: String {
        switch self {
        case .missingStartMarker: L10n.text("The managed-region start marker is missing.")
        case .missingEndMarker: L10n.text("The managed-region end marker is missing.")
        case .duplicateStartMarker: L10n.text("The managed-region start marker appears more than once.")
        case .duplicateEndMarker: L10n.text("The managed-region end marker appears more than once.")
        case .endBeforeStart: L10n.text("The managed-region end marker appears before its start marker.")
        case .malformedMarker: L10n.text("A Caddyman managed-region marker is malformed.")
        }
    }
}

enum CaddyfileManagedRegion: Equatable, Sendable {
    case absent
    case valid(startMarkerRange: Range<Int>, bodyRange: Range<Int>, endMarkerRange: Range<Int>)
    case malformed(CaddyfileManagedRegionIssue)

    var title: String {
        switch self {
        case .absent: L10n.text("No Caddyman-managed region")
        case .valid: L10n.text("Managed region is valid")
        case .malformed(let issue): issue.title
        }
    }

    var symbolName: String {
        switch self {
        case .absent: "doc.text.magnifyingglass"
        case .valid: "checkmark.circle"
        case .malformed: "exclamationmark.triangle"
        }
    }

    var bodyRange: Range<Int>? {
        guard case .valid(_, let bodyRange, _) = self else { return nil }
        return bodyRange
    }
}

struct CaddyfileManagedSite: Equatable, Identifiable, Sendable {
    let address: String
    let upstream: String?

    var id: String { address }

    var redactedUpstream: String? {
        guard let upstream else { return nil }
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(://[^:/@\s]+:)[^@/\s]+@"#) else {
            return upstream
        }
        let range = NSRange(upstream.startIndex..<upstream.endIndex, in: upstream)
        return expression.stringByReplacingMatches(in: upstream, range: range, withTemplate: "$1••••@")
    }
}

struct CaddyfileSiteBlock: Equatable, Identifiable, Sendable {
    let address: String
    let upstream: String?
    let sourceRange: Range<Int>
    let sourceText: String
    let isInsideManagedRegion: Bool

    var id: String { "\(sourceRange.lowerBound):\(address)" }

    var redactedSourceText: String {
        CaddyfileDocument.redactingCredentials(in: sourceText)
    }

    var redactedUpstream: String? {
        guard let upstream else { return nil }
        return CaddyfileManagedSite(address: address, upstream: upstream).redactedUpstream
    }
}

struct CaddyfileImportDirective: Equatable, Identifiable, Sendable {
    let pathPattern: String
    let lineRange: Range<Int>
    let pathRange: Range<Int>
    let rawLine: String

    var id: String { "\(lineRange.lowerBound):\(pathPattern)" }

    static func relativeReference(to fileURL: URL, from importingCaddyfileURL: URL) -> String {
        let directory = importingCaddyfileURL.standardizedFileURL.deletingLastPathComponent().pathComponents
        let file = fileURL.standardizedFileURL.pathComponents
        let sharedCount = zip(directory, file).prefix { pair in pair.0 == pair.1 }.count
        let components = Array(repeating: "..", count: directory.count - sharedCount)
            + Array(file.dropFirst(sharedCount))
        return components.isEmpty ? fileURL.lastPathComponent : components.joined(separator: "/")
    }
}

struct ImportedCaddyfileSites: Equatable, Identifiable, Sendable {
    let url: URL
    let siteBlocks: [CaddyfileSiteBlock]
    let error: String?

    var id: String { url.path }
}

struct CaddyfileDocument: Equatable, Sendable {
    static let managedStartMarker = "# BEGIN CADDYMAN MANAGED SITES"
    static let managedEndMarker = "# END CADDYMAN MANAGED SITES"

    let sourceURL: URL
    let originalData: Data
    let content: String
    let sha256: String
    let lineEnding: CaddyfileLineEnding
    let managedRegion: CaddyfileManagedRegion
    let managedSites: [CaddyfileManagedSite]
    let siteBlocks: [CaddyfileSiteBlock]
    let imports: [CaddyfileImportDirective]
    let importedCaddyfiles: [ImportedCaddyfileSites]

    var managedRegionText: String {
        guard let bodyRange = managedRegion.bodyRange else { return "" }
        return String(decoding: originalData[bodyRange], as: UTF8.self)
    }

    var redactedManagedRegionText: String {
        Self.redactingCredentials(in: managedRegionText)
    }

    var redactedContent: String {
        Self.redactingCredentials(in: content)
    }

    static func read(from url: URL, includeImportedFiles: Bool = true) throws -> CaddyfileDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CaddyfileReadError.unreadable(error.localizedDescription)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CaddyfileReadError.invalidUTF8
        }

        let managedRegion = inspectManagedRegion(in: data)
        let managedText: String
        if let bodyRange = managedRegion.bodyRange {
            managedText = String(decoding: data[bodyRange], as: UTF8.self)
        } else {
            managedText = ""
        }

        let digest = sha256(of: data)
        let siteBlocks = parseSiteBlocksWithRanges(in: content, managedRegion: managedRegion)
        let imports = parseTopLevelImports(in: data)
        let importedCaddyfiles = includeImportedFiles ? readImportedCaddyfiles(imports, relativeTo: url) : []
        return CaddyfileDocument(
            sourceURL: url.standardizedFileURL,
            originalData: data,
            content: content,
            sha256: digest,
            lineEnding: detectLineEnding(in: data),
            managedRegion: managedRegion,
            managedSites: parseManagedSites(in: managedText),
            siteBlocks: siteBlocks,
            imports: imports,
            importedCaddyfiles: importedCaddyfiles
        )
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func inspectManagedRegion(in data: Data) -> CaddyfileManagedRegion {
        let lines = lineRanges(in: data)
        var startMarkers: [CaddyfileLine] = []
        var endMarkers: [CaddyfileLine] = []
        var hasMalformedMarker = false

        for line in lines {
            let value = String(decoding: data[line.contentRange], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if value == managedStartMarker {
                startMarkers.append(line)
            } else if value == managedEndMarker {
                endMarkers.append(line)
            } else if value.contains("CADDYMAN MANAGED SITES") {
                hasMalformedMarker = true
            }
        }

        if hasMalformedMarker {
            return .malformed(.malformedMarker)
        }
        if startMarkers.count > 1 {
            return .malformed(.duplicateStartMarker)
        }
        if endMarkers.count > 1 {
            return .malformed(.duplicateEndMarker)
        }
        guard let start = startMarkers.first else {
            return endMarkers.isEmpty ? .absent : .malformed(.missingStartMarker)
        }
        guard let end = endMarkers.first else {
            return .malformed(.missingEndMarker)
        }
        guard end.contentRange.lowerBound > start.fullRange.upperBound else {
            return .malformed(.endBeforeStart)
        }

        return .valid(
            startMarkerRange: start.contentRange,
            bodyRange: start.fullRange.upperBound..<end.contentRange.lowerBound,
            endMarkerRange: end.contentRange
        )
    }

    private static func lineRanges(in data: Data) -> [CaddyfileLine] {
        var result: [CaddyfileLine] = []
        var start = 0

        for index in 0...data.count where index == data.count || data[index] == 0x0A {
            var contentEnd = index
            if contentEnd > start, data[contentEnd - 1] == 0x0D {
                contentEnd -= 1
            }
            let fullEnd = index < data.count ? index + 1 : index
            result.append(CaddyfileLine(
                contentRange: start..<contentEnd,
                fullRange: start..<fullEnd
            ))
            start = fullEnd
        }
        return result
    }

    private static func detectLineEnding(in data: Data) -> CaddyfileLineEnding {
        var crlfCount = 0
        var lfCount = 0
        for index in data.indices where data[index] == 0x0A {
            if index > data.startIndex, data[index - 1] == 0x0D {
                crlfCount += 1
            } else {
                lfCount += 1
            }
        }

        if crlfCount > 0, lfCount > 0 { return .mixed }
        if crlfCount > 0 { return .crlf }
        if lfCount > 0 { return .lf }
        return .none
    }

    private static func parseTopLevelImports(in data: Data) -> [CaddyfileImportDirective] {
        let lines = lineRanges(in: data)
        var result: [CaddyfileImportDirective] = []
        var depth = 0
        for line in lines {
            let raw = String(decoding: data[line.contentRange], as: UTF8.self)
            let uncommented = removingComment(from: raw)
            if depth == 0,
               let commandRange = tokenRange(in: uncommented, tokenIndex: 0),
               String(uncommented[commandRange]) == "import",
               let importRange = tokenRange(in: uncommented, tokenIndex: 1) {
                let pathPattern = unquote(String(uncommented[importRange]))
                let pathStart = uncommented[..<importRange.lowerBound].utf8.count
                let pathEnd = uncommented[..<importRange.upperBound].utf8.count
                result.append(CaddyfileImportDirective(
                    pathPattern: pathPattern,
                    lineRange: line.fullRange,
                    pathRange: (line.contentRange.lowerBound + pathStart)..<(line.contentRange.lowerBound + pathEnd),
                    rawLine: raw
                ))
            }
            depth += braceDelta(in: uncommented)
            if depth < 0 { return [] }
        }
        return result
    }

    private static func tokenRange(in source: String, tokenIndex: Int) -> Range<String.Index>? {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var quote: Character?
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if let tokenStart = start {
                if escaped { escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "`" {
                    quote = character
                } else if character.isWhitespace {
                    ranges.append(tokenStart..<index)
                    start = nil
                }
            } else if !character.isWhitespace {
                start = index
                if character == "\"" || character == "`" { quote = character }
            }
        }
        if let start { ranges.append(start..<source.endIndex) }
        guard ranges.indices.contains(tokenIndex) else { return nil }
        return ranges[tokenIndex]
    }

    private static func unquote(_ token: String) -> String {
        guard token.count >= 2,
              let first = token.first, first == "\"" || first == "`",
              token.last == first else { return token }
        return String(token.dropFirst().dropLast())
    }

    private static func readImportedCaddyfiles(
        _ imports: [CaddyfileImportDirective],
        relativeTo sourceURL: URL
    ) -> [ImportedCaddyfileSites] {
        var urls: [URL] = []
        for directive in imports {
            let patternURL = URL(fileURLWithPath: directive.pathPattern, relativeTo: sourceURL.deletingLastPathComponent())
                .standardizedFileURL
            var matches: [URL] = []
            if directive.pathPattern.contains(where: { "*?[]".contains($0) }) {
                var expansion = glob_t()
                let status = patternURL.path.withCString { glob($0, 0, nil, &expansion) }
                if status == 0, let paths = expansion.gl_pathv {
                    for index in 0..<Int(expansion.gl_pathc) {
                        if let path = paths[index] { matches.append(URL(fileURLWithPath: String(cString: path)).standardizedFileURL) }
                    }
                }
                globfree(&expansion)
            } else {
                matches = [patternURL]
            }
            urls.append(contentsOf: matches.filter { FileManager.default.fileExists(atPath: $0.path) })
        }

        var seen = Set<String>()
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .filter { seen.insert($0.path).inserted }
            .map { url in
                do {
                    let imported = try read(from: url, includeImportedFiles: false)
                    return ImportedCaddyfileSites(url: url, siteBlocks: imported.siteBlocks, error: nil)
                } catch {
                    return ImportedCaddyfileSites(url: url, siteBlocks: [], error: error.localizedDescription)
                }
            }
    }

    private static func parseManagedSites(in source: String) -> [CaddyfileManagedSite] {
        (try? parseSiteBlocks(in: source, allowNonSiteTopLevelContent: true)) ?? []
    }

    private static func parseSiteBlocksWithRanges(
        in source: String,
        managedRegion: CaddyfileManagedRegion
    ) -> [CaddyfileSiteBlock] {
        let lines = source.components(separatedBy: "\n")
        let bytes = Array(source.utf8)
        let managedRange = managedRegion.bodyRange
        var result: [CaddyfileSiteBlock] = []
        var byteOffset = 0
        var siteStart: Int?
        var address: String?
        var upstream: String?
        var braceDepth = 0

        for (index, rawLine) in lines.enumerated() {
            let lineStart = byteOffset
            let lineEnd = min(bytes.count, lineStart + rawLine.utf8.count)
            let lineAfter = min(bytes.count, lineEnd + (index < lines.count - 1 ? 1 : 0))
            byteOffset = lineAfter

            let line = removingComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if address != nil {
                if upstream == nil { upstream = reverseProxyUpstream(in: line) }
                braceDepth += braceDelta(in: line)
                guard braceDepth >= 0 else { return [] }
                if braceDepth == 0, let completedAddress = address, let completedStart = siteStart {
                    let range = completedStart..<lineAfter
                    let text = String(decoding: bytes[range], as: UTF8.self)
                    let isInsideManagedRegion = managedRange.map {
                        range.lowerBound >= $0.lowerBound && range.upperBound <= $0.upperBound
                    } ?? false
                    result.append(CaddyfileSiteBlock(
                        address: completedAddress,
                        upstream: upstream,
                        sourceRange: range,
                        sourceText: text,
                        isInsideManagedRegion: isInsideManagedRegion
                    ))
                    siteStart = nil
                    address = nil
                    upstream = nil
                }
                continue
            }

            if braceDepth > 0 {
                braceDepth += braceDelta(in: line)
                guard braceDepth >= 0 else { return [] }
                continue
            }

            guard let openingBrace = line.firstIndex(of: "{") else { continue }
            let candidate = String(line[..<openingBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, !candidate.hasPrefix("("), !candidate.hasPrefix("@") else {
                braceDepth = max(0, braceDelta(in: line))
                continue
            }

            address = candidate
            siteStart = lineStart
            upstream = reverseProxyUpstream(in: String(line[line.index(after: openingBrace)...]))
            braceDepth = braceDelta(in: line)
            guard braceDepth >= 0 else { return [] }
            if braceDepth == 0, let completedAddress = address, let completedStart = siteStart {
                let range = completedStart..<lineAfter
                let text = String(decoding: bytes[range], as: UTF8.self)
                let isInsideManagedRegion = managedRange.map {
                    range.lowerBound >= $0.lowerBound && range.upperBound <= $0.upperBound
                } ?? false
                result.append(CaddyfileSiteBlock(
                    address: completedAddress,
                    upstream: upstream,
                    sourceRange: range,
                    sourceText: text,
                    isInsideManagedRegion: isInsideManagedRegion
                ))
                siteStart = nil
                address = nil
                upstream = nil
            }
        }
        return braceDepth == 0 && address == nil ? result : []
    }


    static func parseSiteBlocks(
        in source: String,
        allowNonSiteTopLevelContent: Bool
    ) throws -> [CaddyfileManagedSite] {
        var sites: [CaddyfileManagedSite] = []
        var address: String?
        var upstream: String?
        var braceDepth = 0

        for rawLine in source.components(separatedBy: .newlines) {
            let line = removingComment(from: rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if address != nil {
                if upstream == nil {
                    upstream = reverseProxyUpstream(in: line)
                }
                braceDepth += braceDelta(in: line)
                guard braceDepth >= 0 else { throw CaddyfileMigrationPreviewError.unbalancedBlocks }
                if braceDepth == 0, let siteAddress = address {
                    sites.append(CaddyfileManagedSite(address: siteAddress, upstream: upstream))
                    address = nil
                    upstream = nil
                }
                continue
            }

            if braceDepth > 0 {
                braceDepth += braceDelta(in: line)
                guard braceDepth >= 0 else { throw CaddyfileMigrationPreviewError.unbalancedBlocks }
                continue
            }

            guard let openingBrace = line.firstIndex(of: "{") else {
                if !allowNonSiteTopLevelContent {
                    throw CaddyfileMigrationPreviewError.unsupportedSourceContent
                }
                continue
            }

            let candidate = String(line[..<openingBrace]).trimmingCharacters(in: .whitespaces)
            let delta = braceDelta(in: line)
            guard delta >= 0 else { throw CaddyfileMigrationPreviewError.unbalancedBlocks }
            guard !candidate.isEmpty, !candidate.hasPrefix("("), !candidate.hasPrefix("@") else {
                guard allowNonSiteTopLevelContent else {
                    throw CaddyfileMigrationPreviewError.unsupportedSourceContent
                }
                braceDepth = delta
                continue
            }

            address = candidate
            braceDepth = delta
            let bodyStart = line.index(after: openingBrace)
            upstream = reverseProxyUpstream(in: String(line[bodyStart...]))
            if braceDepth == 0 {
                sites.append(CaddyfileManagedSite(address: candidate, upstream: upstream))
                address = nil
                upstream = nil
            }
        }

        guard braceDepth == 0, address == nil else {
            throw CaddyfileMigrationPreviewError.unbalancedBlocks
        }
        return sites
    }

    static func redactingCredentials(in source: String) -> String {
        let patterns = [
            (
                #"(?i)(\b(?:api[_-]?token|token|secret|password|client[_-]?secret|access[_-]?key)\b\s+)(\"[^\"]*\"|`[^`]*`|[^\s#]+)"#,
                "$1••••••"
            ),
            (
                #"(?i)(\bdns\s+dnspod\s+(?:token\s+)?)(?!\{env\.[^}]+\})(\"[^\"]*\"|`[^`]*`|[^\s#]+)"#,
                "$1••••••"
            ),
            (#"(?i)(://[^:/@\s]+:)[^@/\s]+@"#, "$1••••@"),
        ]

        return patterns.reduce(source) { value, entry in
            guard let expression = try? NSRegularExpression(pattern: entry.0) else { return value }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(in: value, range: range, withTemplate: entry.1)
        }
    }

    private static func reverseProxyUpstream(in line: String) -> String? {
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2, tokens[0] == "reverse_proxy" else { return nil }
        let value = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
        return value == "{" || value.isEmpty ? nil : value
    }

    private static func removingComment(from line: String) -> String {
        var output = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                output.append(character)
                escaped = false
            } else if character == "\\" {
                output.append(character)
                escaped = true
            } else if let activeQuote = quote {
                output.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "`" {
                quote = character
                output.append(character)
            } else if character == "#" {
                break
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "`" {
                quote = character
            } else if character == "#" {
                break
            } else if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }
        return delta
    }
}

enum CaddyfileReadState: Equatable, Sendable {
    case notSelected
    case reading
    case loaded(CaddyfileDocument)
    case failed(String)
}

private struct CaddyfileLine {
    let contentRange: Range<Int>
    let fullRange: Range<Int>
}
