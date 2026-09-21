import Foundation

/// Console Log 的文本格式化（纯函数，方便单测）。
///
/// 格式参考 `specs/06-query-editor.md` §6 的列表，落盘文件用同一份文本。
public enum ConsoleLogFormatter {

    /// 文件名前缀 / 后缀（按天轮转，`02-persistence.md` §5）。
    public static let fileNamePrefix = "console-"
    public static let fileNameExtension = "log"

    /// 一天的日志文件名：`console-2026-09-22.log`。
    public static func fileName(day: String) -> String {
        "\(fileNamePrefix)\(day).\(fileNameExtension)"
    }

    /// 完整时间戳：`2026-09-22 14:32:07.123`（`specs/12-feedback.md` §8：时间用 `HH:mm:ss`，这里带日期）。
    public static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            (components.nanosecond ?? 0) / 1_000_000
        )
    }

    /// 日期部分：`2026-09-22`，用作轮转文件名。
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// 从文件名还原日期部分；不是日志文件时返回 `nil`。
    public static func day(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix(fileNamePrefix),
              fileName.hasSuffix(".\(fileNameExtension)") else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: fileNamePrefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -(".\(fileNameExtension)".count))
        return String(fileName[start..<end])
    }

    /// 一条日志的完整文本（一行概要 + 缩进的 SQL）。
    public static func text(for entry: ConsoleLogEntry, calendar: Calendar = .current) -> String {
        let database = entry.database.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
        let duration = entry.durationMilliseconds.map { "\($0) ms" } ?? "-"

        let result: String
        if let errorCode = entry.errorCode {
            result = "✗ \(errorCode)"
        } else if entry.isCancelled {
            result = "已取消"
        } else if let rows = entry.returnedRowCount {
            result = "\(rows) 行"
        } else if let affected = entry.affectedRows {
            result = "\(affected) 行"
        } else {
            result = "-"
        }

        var lines = ["\(timestamp(entry.timestamp, calendar: calendar)) [\(entry.tag.rawValue)] \(database) \(duration) \(result)"]
        lines.append("    " + entry.sql)
        if let message = entry.errorMessage, !message.isEmpty {
            // `specs/12-feedback.md` §5：服务器原文不翻译、不改写、不截断。
            lines.append("    错误：\(message)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
