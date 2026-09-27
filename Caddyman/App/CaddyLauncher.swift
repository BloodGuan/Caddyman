import Foundation
import Darwin

@main
enum CaddymanEntryPoint {
    static func main() async {
        guard CommandLine.arguments.dropFirst().first == CaddyLaunchAgentPlist.launcherFlag else {
            CaddymanApp.main()
            return
        }
        let status = await CaddyLauncher.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(status)
    }
}

enum CaddyLauncher {
    static func configuration(arguments: [String]) -> CaddyLaunchAgentConfiguration? {
        guard arguments.count == 5,
              arguments[0] == CaddyLaunchAgentPlist.launcherFlag,
              arguments[1] == "--binary", arguments[3] == "--config",
              arguments[2].hasPrefix("/"), arguments[4].hasPrefix("/") else { return nil }
        return CaddyLaunchAgentConfiguration(
            launcherURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            binaryURL: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
            caddyfileURL: URL(fileURLWithPath: arguments[4]).standardizedFileURL
        )
    }

    static func run(arguments: [String]) async -> Int32 {
        guard let configuration = configuration(arguments: arguments) else { return 78 }
        do {
            let data = try Data(contentsOf: configuration.caddyfileURL)
            let content = String(decoding: data, as: UTF8.self)
            let usesDNSPod = content.contains("{env.DNSPOD_TOKEN}") || content.contains("{$DNSPOD_TOKEN}")
            let token: String?
            if usesDNSPod {
                guard let saved = try DNSPodKeychainCredentialStore().readToken() else { return 78 }
                token = saved
            } else {
                token = nil
            }
            let environment = token.map { ["DNSPOD_TOKEN": $0] } ?? [:]
            let result = await CaddyCandidateValidator().validate(
                candidateData: data,
                binaryURL: configuration.binaryURL,
                workingDirectoryURL: configuration.caddyfileURL.deletingLastPathComponent(),
                environment: environment,
                sensitiveValues: token.map { [$0] } ?? []
            )
            guard result.isValid,
                  CaddyfileDocument.sha256(of: try Data(contentsOf: configuration.caddyfileURL))
                    == CaddyfileDocument.sha256(of: data) else { return 78 }

            unsetenv("DNSPOD_TOKEN")
            unsetenv("CADDY_ADMIN")
            if let token { setenv("DNSPOD_TOKEN", token, 1) }
            guard chdir(configuration.caddyfileURL.deletingLastPathComponent().path) == 0 else { return 78 }
            var arguments = [
                configuration.binaryURL.path, "run", "--config", configuration.caddyfileURL.path,
                "--adapter", "caddyfile"
            ].map { strdup($0) }
            arguments.append(nil)
            defer { arguments.compactMap { $0 }.forEach { free($0) } }
            let status = arguments.withUnsafeMutableBufferPointer { buffer in
                execv(configuration.binaryURL.path, buffer.baseAddress!)
            }
            return status == -1 ? 71 : 0
        } catch {
            return 78
        }
    }
}
