import CryptoKit
import Darwin
import Foundation

enum CaddyfileAtomicWriteError: Error, LocalizedError, Equatable {
    case targetChanged
    case targetIsNotRegularFile
    case backupFailed
    case replacementFailed

    var errorDescription: String? {
        switch self {
        case .targetChanged:
            L10n.text("The target Caddyfile changed after the preview. Reload it and review a new diff before applying.")
        case .targetIsNotRegularFile:
            L10n.text("The selected Caddyfile is not a regular file, so Caddyman cannot replace it safely.")
        case .backupFailed:
            L10n.text("Caddyman could not create a protected backup of the target Caddyfile.")
        case .replacementFailed:
            L10n.text("Caddyman could not atomically replace the target Caddyfile. The original file was kept.")
        }
    }
}

struct CaddyfileMigrationApplyResult: Equatable, Sendable {
    let succeeded: Bool
    let detail: String
    let backupURL: URL?
}

protocol CaddyfileWriting: Sendable {
    func apply(candidateData: Data, to targetURL: URL, expectedSHA256: String) throws -> URL
}

struct CaddyfileAtomicWriter: CaddyfileWriting {
    func apply(candidateData: Data, to targetURL: URL, expectedSHA256: String) throws -> URL {
        let targetURL = targetURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CaddyfileAtomicWriteError.targetIsNotRegularFile
        }

        let attributes: [FileAttributeKey: Any]
        let originalData: Data
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CaddyfileAtomicWriteError.targetIsNotRegularFile
            }
            originalData = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
        } catch let error as CaddyfileAtomicWriteError {
            throw error
        } catch {
            throw CaddyfileAtomicWriteError.targetIsNotRegularFile
        }

        guard Self.sha256(originalData) == expectedSHA256 else {
            throw CaddyfileAtomicWriteError.targetChanged
        }

        let backupURL = try makeBackupURL(for: targetURL)
        do {
            try writeNewFile(originalData, to: backupURL, permissions: 0o600)
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            throw CaddyfileAtomicWriteError.backupFailed
        }

        do {
            let latestData = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            guard Self.sha256(latestData) == expectedSHA256 else {
                throw CaddyfileAtomicWriteError.targetChanged
            }
        } catch let error as CaddyfileAtomicWriteError {
            throw error
        } catch {
            throw CaddyfileAtomicWriteError.targetChanged
        }

        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let temporaryURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).caddyman-\(UUID().uuidString).tmp")
        do {
            try writeNewFile(candidateData, to: temporaryURL, permissions: permissions)
            guard rename(temporaryURL.path, targetURL.path) == 0 else {
                throw CaddyfileAtomicWriteError.replacementFailed
            }
            syncDirectory(targetURL.deletingLastPathComponent())
            return backupURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            if let error = error as? CaddyfileAtomicWriteError { throw error }
            throw CaddyfileAtomicWriteError.replacementFailed
        }
    }

    private func makeBackupURL(for targetURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = targetURL.appendingPathExtension("caddyman-backup-\(formatter.string(from: Date()))")
        for suffix in 0..<100 {
            let candidate = suffix == 0
                ? base
                : URL(fileURLWithPath: base.path + "-\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw CaddyfileAtomicWriteError.backupFailed
    }

    private func writeNewFile(_ data: Data, to url: URL, permissions: UInt16) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CaddyfileAtomicWriteError.replacementFailed }
        defer { _ = close(descriptor) }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw CaddyfileAtomicWriteError.replacementFailed }
                offset += result
            }
        }
        guard fsync(descriptor) == 0 else { throw CaddyfileAtomicWriteError.replacementFailed }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else { throw CaddyfileAtomicWriteError.replacementFailed }
        guard fsync(descriptor) == 0 else { throw CaddyfileAtomicWriteError.replacementFailed }
    }

    private func syncDirectory(_ directoryURL: URL) {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }
        _ = fsync(descriptor)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
