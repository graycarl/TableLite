import AppKit
import UniformTypeIdentifiers

/// 脚本文件读写（`specs/06-query-editor.md` §7）。
///
/// `⌘O` 打开 `.sql` / `.txt` 到新标签；`⌘S` / `⇧⌘S` 保存 / 另存为。
/// 面板逻辑与视图分开，便于复用与阅读。
@MainActor
enum ScriptFileController {

    /// 打开文件面板；返回 (URL, 文本)。取消时返回 nil。
    static func openPanel() -> (url: URL, text: String)? {
        let panel = NSOpenPanel()
        panel.title = "打开脚本"
        panel.message = "选择要打开的 .sql / .txt 文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ScriptFileTypes.allowed
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try read(url)
            return (url, text)
        } catch {
            presentError(title: "无法打开文件", error: error)
            return nil
        }
    }

    /// 另存为面板；写入成功后返回 URL。取消或失败返回 nil。
    static func saveAsPanel(defaultName: String, contents: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "脚本另存为"
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = ScriptFileTypes.allowed
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if write(contents, to: url) {
            return url
        }
        return nil
    }

    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        // 兼容非 UTF-8 的旧脚本，尽量读出来而不是直接失败。
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw ScriptFileError.notText
    }

    @discardableResult
    static func write(_ contents: String, to url: URL) -> Bool {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            presentError(title: "保存失败", error: error)
            return false
        }
    }

    private static func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

enum ScriptFileError: Error, LocalizedError {
    case notText

    var errorDescription: String? {
        "文件不是可识别的文本（既不是 UTF-8 也不是 Latin-1）。"
    }
}

/// `.sql` / `.txt` 的 UTType。
enum ScriptFileTypes {
    static var allowed: [UTType] {
        var types: [UTType] = []
        if let sql = UTType(filenameExtension: "sql") { types.append(sql) }
        types.append(.plainText)
        return types.isEmpty ? [.plainText] : types
    }
}
