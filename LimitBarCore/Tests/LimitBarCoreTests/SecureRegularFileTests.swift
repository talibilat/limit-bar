import Foundation
import Testing
@testable import LimitBarCore

@Suite("Secure regular file")
struct SecureRegularFileTests {
    @Test("opens a canonical regular file beneath the macOS temporary directory alias")
    func opensCanonicalTemporaryFile() throws {
        let original = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try Data("contents".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let canonical = try #require(SecureRegularFile.canonicalURL(original))

        let handle = try SecureRegularFile.open(canonical)
        defer { try? handle.close() }

        #expect(try handle.readToEnd() == Data("contents".utf8))
    }
}
