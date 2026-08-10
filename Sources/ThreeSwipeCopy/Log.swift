import Foundation

/// 极简诊断日志：追加写入 ~/Library/Logs/ThreeSwipeCopy.log
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/ThreeSwipeCopy.log"

    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            guard let fh = FileHandle(forWritingAtPath: path) else { return }
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
