import Darwin
import Foundation

enum SiteTLSMode: String, CaseIterable, Identifiable, Sendable {
    case httpOnly
    case automaticHTTPS
    case dnsPodDNS01

    var id: String { rawValue }
}

enum DNSPodCredentialMode: String, CaseIterable, Identifiable, Sendable {
    case keychain
    case plainText

    var id: String { rawValue }
}

enum ACMEEnvironment: String, CaseIterable, Identifiable, Sendable {
    case production
    case staging

    var id: String { rawValue }

    var directoryURL: String? {
        switch self {
        case .production: nil
        case .staging: "https://acme-staging-v02.api.letsencrypt.org/directory"
        }
    }
}

struct ReverseProxySite: Equatable, Identifiable, Sendable {
    var id: UUID
    var hostname: String
    var port: String
    var upstream: String
    var tlsMode: SiteTLSMode
    var acmeEnvironment: ACMEEnvironment
    var credentialMode: DNSPodCredentialMode
    var plainTextToken: String

    init(
        id: UUID = UUID(),
        hostname: String = "",
        port: String = "",
        upstream: String = "127.0.0.1:3000",
        tlsMode: SiteTLSMode = .automaticHTTPS,
        acmeEnvironment: ACMEEnvironment = .production,
        credentialMode: DNSPodCredentialMode = .keychain,
        plainTextToken: String = ""
    ) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.upstream = upstream
        self.tlsMode = tlsMode
        self.acmeEnvironment = acmeEnvironment
        self.credentialMode = credentialMode
        self.plainTextToken = plainTextToken
    }

    var normalizedHostname: String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    func normalized() -> ReverseProxySite {
        var copy = self
        copy.hostname = normalizedHostname
        copy.port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.upstream = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
        if tlsMode != .dnsPodDNS01 {
            copy.credentialMode = .keychain
            copy.plainTextToken = ""
        } else {
            copy.plainTextToken = plainTextToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return copy
    }
}

enum SiteValidationIssue: Error, Equatable, LocalizedError {
    case invalidHostname
    case invalidPort
    case invalidUpstream
    case invalidDNSPodHostname
    case invalidACMEEnvironment
    case missingDNSPodToken
    case invalidDNSPodToken
    case duplicateHostname(String)

    var errorDescription: String? {
        switch self {
        case .invalidHostname: L10n.text("Enter a valid hostname or IP address.")
        case .invalidPort: L10n.text("The site port must be a number from 1 to 65535.")
        case .invalidUpstream: L10n.text("Enter an HTTP or HTTPS upstream address without a path or credentials.")
        case .invalidDNSPodHostname: L10n.text("DNSPod DNS-01 requires a public domain name, not an IP address or localhost.")
        case .invalidACMEEnvironment: L10n.text("HTTP-only sites cannot use an ACME certificate environment.")
        case .missingDNSPodToken: L10n.text("Enter the DNSPod token or save it to Keychain first.")
        case .invalidDNSPodToken: L10n.text("The DNSPod token must use the APP_ID,APP_TOKEN format.")
        case .duplicateHostname(let hostname): L10n.format("A site for %@ already exists.", hostname)
        }
    }
}

enum ReverseProxySiteValidator {
    static func validate(_ site: ReverseProxySite, existingSites: [ReverseProxySite]) throws {
        let hostname = site.normalizedHostname
        guard isValidHost(hostname) else { throw SiteValidationIssue.invalidHostname }

        let trimmedPort = site.port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty {
            guard let port = Int(trimmedPort), (1...65_535).contains(port) else {
                throw SiteValidationIssue.invalidPort
            }
        }

        guard isValidUpstream(site.upstream) else { throw SiteValidationIssue.invalidUpstream }

        if site.tlsMode == .httpOnly, site.acmeEnvironment != .production {
            throw SiteValidationIssue.invalidACMEEnvironment
        }

        if let duplicate = existingSites.first(where: {
            $0.id != site.id && $0.normalizedHostname == hostname
        }) {
            throw SiteValidationIssue.duplicateHostname(duplicate.normalizedHostname)
        }

        if site.tlsMode == .dnsPodDNS01 {
            let internalSuffixes = [".localhost", ".local", ".internal", ".home.arpa", ".test", ".invalid"]
            guard hostname.contains("."),
                  !isIPAddress(hostname),
                  hostname != "localhost",
                  !internalSuffixes.contains(where: hostname.hasSuffix) else {
                throw SiteValidationIssue.invalidDNSPodHostname
            }
            if site.credentialMode == .plainText {
                let token = site.plainTextToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { throw SiteValidationIssue.missingDNSPodToken }
                guard isValidDNSPodToken(token) else { throw SiteValidationIssue.invalidDNSPodToken }
            }
        }
    }

    static func isValidDNSPodToken(_ token: String) -> Bool {
        let parts = token.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { character in
                guard let ascii = character.asciiValue else { return false }
                return (0x21...0x7E).contains(ascii) && character != "{" && character != "}"
            }
        }
    }

    private static func isValidHost(_ hostname: String) -> Bool {
        guard !hostname.isEmpty, hostname.utf8.count <= 253 else { return false }
        if isIPAddress(hostname) || hostname == "localhost" { return true }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard label.utf8.count <= 63,
                  let first = label.first,
                  let last = label.last,
                  first.isASCII, last.isASCII,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        let ipv6Host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ipv6Host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func isValidUpstream(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let components: URLComponents?
        if value.contains("://") {
            components = URLComponents(string: value)
        } else {
            components = URLComponents(string: "http://\(value)")
        }
        guard let components,
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, isValidHost(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return false }
        if let port = components.port, !(1...65_535).contains(port) { return false }
        return true
    }
}
