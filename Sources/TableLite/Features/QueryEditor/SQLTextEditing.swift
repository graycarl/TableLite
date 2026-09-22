import Foundation

/// 编辑器命令（`specs/06-query-editor.md` §2：注释切换 / 缩进 / 反缩进）。
enum SQLEditingCommand: Equatable {
    case toggleComment
    case indent
    case dedent
}

/// 编辑器命令的请求载体：`token` 变化时执行一次。
struct SQLTextViewCommand: Equatable {
    var token: Int
    var command: SQLEditingCommand
}

/// 纯函数实现的文本编辑命令，便于单测。
enum SQLTextEditing {

    /// 注释切换：整段已注释则取消，否则给每一行加 `-- `。
    static func toggleComment(text: String, selection: NSRange, indentWidth: Int) -> (text: String, selection: NSRange) {
        transformLines(text: text, selection: selection) { line in
            let (indent, body) = splitIndent(line)
            if body.isEmpty {
                return line
            }
            if body.hasPrefix("--") {
                var stripped = String(body.dropFirst(2))
                if stripped.hasPrefix(" ") { stripped.removeFirst() }
                return indent + stripped
            }
            return indent + "-- " + body
        }
    }

    /// 每行增加一级缩进。
    static func indent(text: String, selection: NSRange, indentWidth: Int) -> (text: String, selection: NSRange) {
        let spaces = String(repeating: " ", count: max(1, indentWidth))
        return transformLines(text: text, selection: selection) { line in
            line.isEmpty ? line : spaces + line
        }
    }

    /// 每行去掉一级缩进（最多 `indentWidth` 个前导空格，或一个 Tab）。
    static func dedent(text: String, selection: NSRange, indentWidth: Int) -> (text: String, selection: NSRange) {
        let width = max(1, indentWidth)
        return transformLines(text: text, selection: selection) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var removed = 0
            var result = line
            while removed < width, result.hasPrefix(" ") {
                result.removeFirst()
                removed += 1
            }
            return result
        }
    }

    // MARK: 内部

    private static func transformLines(
        text: String,
        selection: NSRange,
        transform: (String) -> String
    ) -> (text: String, selection: NSRange) {
        let nsText = text as NSString
        guard nsText.length > 0 else { return (text, selection) }
        let location = min(max(selection.location, 0), nsText.length)
        let length = min(max(selection.length, 0), nsText.length - location)
        let blockRange = nsText.lineRange(for: NSRange(location: location, length: length))

        var output = ""
        var cursor = blockRange.location
        let blockEnd = blockRange.location + blockRange.length
        while cursor < blockEnd {
            let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
            let clipped = NSIntersectionRange(lineRange, blockRange)
            guard clipped.length > 0 else { break }
            let line = nsText.substring(with: clipped)
            output += transformLineKeepingNewline(line, transform: transform)
            cursor = clipped.location + clipped.length
        }

        let result = nsText.replacingCharacters(in: blockRange, with: output)
        let newSelection = NSRange(location: blockRange.location, length: (output as NSString).length)
        return (result, newSelection)
    }

    private static func transformLineKeepingNewline(_ line: String, transform: (String) -> String) -> String {
        if line.hasSuffix("\r\n") {
            return transform(String(line.dropLast(2))) + "\r\n"
        }
        if line.hasSuffix("\n") {
            return transform(String(line.dropLast())) + "\n"
        }
        return transform(line)
    }

    /// 拆出前导空白与正文。
    static func splitIndent(_ line: String) -> (indent: String, body: String) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        return (indent, String(line.dropFirst(indent.count)))
    }
}
