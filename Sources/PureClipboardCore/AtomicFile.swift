import Darwin
import Foundation

/// Minimal atomic file replacement: exclusive temp file, fsync, rename.
enum AtomicFile {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Writes `data` next to `url` and renames it into place with the given POSIX mode.
    static func write(_ data: Data, to url: URL, mode: mode_t, createDirectory: Bool = true) throws {
        let directory = url.deletingLastPathComponent()
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let tempPath = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: errnoString()) }

        var failure: String?
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        if !written { failure = errnoString() }
        if failure == nil, fchmod(fd, mode) != 0 { failure = errnoString() }
        if failure == nil, fsync(fd) != 0 { failure = errnoString() }
        close(fd)
        if failure == nil, rename(tempPath, url.path) != 0 { failure = errnoString() }
        if let failure {
            unlink(tempPath)
            throw Failure(message: failure)
        }
    }

    static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
