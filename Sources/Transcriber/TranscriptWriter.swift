import Foundation

/// final 文本实时落盘:每句 append 一行,句到即写(FileHandle 直写 OS,无用户态缓冲),
/// 中途崩溃/断电也只丢未出的句子。课后 LLM 流水线(计划 §六)直接读该文件。
final class TranscriptWriter {
    let url: URL
    private let handle: FileHandle

    init?(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = h
    }

    func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}
