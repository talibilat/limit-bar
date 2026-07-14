import Darwin
import Foundation

enum SecureRegularFile {
    static func open(_ url: URL) throws -> FileHandle {
        guard !isSymbolicLink(url) else { throw CocoaError(.fileReadNoPermission) }
        let components = url.pathComponents.dropFirst()
        guard let fileName = components.last else { throw CocoaError(.fileReadInvalidFileName) }

        var directoryDescriptor = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard directoryDescriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            }
            Darwin.close(directoryDescriptor)
            guard nextDescriptor >= 0 else {
                throw CocoaError(.fileReadNoPermission)
            }
            directoryDescriptor = nextDescriptor
        }
        let descriptor = fileName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        Darwin.close(directoryDescriptor)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadInvalidFileName)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        return result == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    static func canonicalURL(_ url: URL) -> URL? {
        if let resolved = resolvedURL(url) { return resolved }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let resolvedParent = canonicalURL(parent) else { return nil }
        return resolvedParent.appendingPathComponent(url.lastPathComponent)
    }

    static func stableStoredPath(_ path: String) -> String {
        for alias in ["var", "tmp", "etc"] {
            let prefix = "/\(alias)"
            if path == prefix || path.hasPrefix(prefix + "/") {
                return "/private" + path
            }
        }
        return path
    }

    private static func resolvedURL(_ url: URL) -> URL? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            let resolvedPath = String(cString: resolved)
            for alias in ["var", "tmp", "etc"] {
                let prefix = "/\(alias)"
                if resolvedPath == prefix || resolvedPath.hasPrefix(prefix + "/") {
                    return URL(fileURLWithPath: "/private" + resolvedPath)
                }
            }
            return URL(fileURLWithPath: resolvedPath)
        }
    }
}
