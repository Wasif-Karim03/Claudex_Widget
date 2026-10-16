import Foundation

/// A fresh temporary directory, removed by the caller via `cleanup()`.
struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String, modified: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

func isoDate(_ string: String) -> Date {
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    return try! Date(string, strategy: style)
}
