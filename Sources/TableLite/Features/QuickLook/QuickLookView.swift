import AppKit
import SwiftUI

// MARK: - 快速查看内容
//
// 需求见 specs/03-data-browsing.md §8：JSON 格式化折叠、长文本等宽 + 行号、
// 二进制 hex（前 64 KB）+ 导出、图片直接显示 + 导出、日期时间原样显示。
//
// 面板与生命周期在 `QuickLookPanel.swift`；这里只有内容模型与渲染。

/// 快速查看的呈现形态。
enum QuickLookFormat: Equatable {
    case json
    case image(format: String)
    case binary
    case longText
    case scalar
}

enum QuickLookFormatter {

    /// hex dump 的默认上限：64 KB。
    static let hexDumpByteLimit = 64 * 1024

    /// 按列类型与内容决定呈现形态。
    static func format(value: CellValue, kind: ColumnKind) -> QuickLookFormat {
        if value.isNull { return .scalar }
        if kind == .json {
            if case .bytes(let bytes) = value,
               let text = String(bytes: bytes, encoding: .utf8),
               JSONNode.parse(text) != nil {
                return .json
            }
            return .longText
        }
        if kind.isBinaryLike {
            if case .bytes(let bytes) = value, GridValueFormatter.imageFormat(bytes) != nil {
                return .image(format: GridValueFormatter.imageFormat(bytes) ?? "图片")
            }
            return .binary
        }
        if kind.isDateTime { return .scalar }
        if case .bytes(let bytes) = value {
            guard let text = String(bytes: bytes, encoding: .utf8) else { return .binary }
            if kind == .text || kind == .unknown("") {
                return text.count > 120 ? .longText : .scalar
            }
            return .scalar
        }
        return .scalar
    }

    /// hex dump：`偏移  十六进制  ASCII`。
    static func hexDump(_ bytes: [UInt8], limit: Int = hexDumpByteLimit) -> String {
        let slice = bytes.prefix(max(limit, 0))
        var lines: [String] = []
        var offset = 0
        let array = Array(slice)
        while offset < array.count {
            let end = min(offset + 16, array.count)
            let chunk = array[offset..<end]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> Character in
                (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            }
            lines.append(String(format: "%08X  %@  |%@|", offset, padded, String(ascii)))
            offset = end
        }
        if bytes.count > limit {
            lines.append("… 仅显示前 \(GridValueFormatter.byteCount(limit))，共 \(GridValueFormatter.byteCount(bytes.count))")
        }
        return lines.joined(separator: "\n")
    }

    /// 原始字节数（导出用）。
    static func byteCount(of value: CellValue) -> Int { value.byteCount }
}

// MARK: - JSON 树

/// 用于快速查看的 JSON 节点。
indirect enum JSONNode {
    case object([(String, JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    static func parse(_ text: String) -> JSONNode? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return from(any)
    }

    static func from(_ any: Any) -> JSONNode {
        switch any {
        case let dictionary as [String: Any]:
            return .object(dictionary.keys.sorted().map { ($0, from(dictionary[$0] as Any)) })
        case let array as [Any]:
            return .array(array.map(from))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.stringValue)
        case let string as String:
            return .string(string)
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }
}

struct JSONTreeView: View {
    let node: JSONNode
    var body: some View {
        JSONNodeView(node: node, label: nil)
    }
}

private struct JSONNodeView: View {
    let node: JSONNode
    let label: String?

    var body: some View {
        switch node {
        case .object(let entries):
            if entries.isEmpty {
                leaf("{}")
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            JSONNodeView(node: entry.1, label: entry.0)
                        }
                    }
                    .padding(.leading, 12)
                } label: {
                    label.map { Text("\($0):").font(.system(size: 12, design: .monospaced)) }
                }
            }
        case .array(let items):
            if items.isEmpty {
                leaf("[]")
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            JSONNodeView(node: item, label: "[\(index)]")
                        }
                    }
                    .padding(.leading, 12)
                } label: {
                    label.map { Text("\($0):").font(.system(size: 12, design: .monospaced)) }
                }
            }
        case .string(let value):
            leaf((label.map { "\($0): " } ?? "") + "\"\(value)\"")
        case .number(let value):
            leaf((label.map { "\($0): " } ?? "") + value)
        case .bool(let value):
            leaf((label.map { "\($0): " } ?? "") + (value ? "true" : "false"))
        case .null:
            leaf((label.map { "\($0): " } ?? "") + "null")
        }
    }

    private func leaf(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 长文本（等宽 + 行号）

struct LineNumberedText: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index].isEmpty ? " " : lines[index])
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - 快速查看内容模型

@MainActor
final class QuickLookContentModel: ObservableObject {
    @Published var title: String
    @Published var kind: ColumnKind
    @Published var value: CellValue?
    @Published var isLoading: Bool
    @Published var error: String?

    init(title: String, kind: ColumnKind, value: CellValue?, isLoading: Bool, error: String?) {
        self.title = title
        self.kind = kind
        self.value = value
        self.isLoading = isLoading
        self.error = error
    }
}

// MARK: - 快速查看视图

struct QuickLookView: View {
    @ObservedObject var model: QuickLookContentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let value = model.value, !value.isNull, !model.isLoading {
                    exportButton(value: value)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            VStack {
                Spacer()
                ProgressView("正在加载完整内容…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let error = model.error {
            VStack {
                Spacer()
                Text(error).foregroundStyle(.red)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let value = model.value {
            rendered(value: value)
        } else {
            Text("没有可显示的内容")
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }

    @ViewBuilder
    private func rendered(value: CellValue) -> some View {
        switch QuickLookFormatter.format(value: value, kind: model.kind) {
        case .json:
            if let text = value.strictText, let node = JSONNode.parse(text) {
                ScrollView {
                    JSONTreeView(node: node).padding(12)
                }
            } else {
                plainText(value.displayText)
            }
        case .image(let format):
            imageView(value: value, format: format)
        case .binary:
            ScrollView([.horizontal, .vertical]) {
                Text(QuickLookFormatter.hexDump(value.bytes ?? []))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        case .longText:
            LineNumberedText(text: value.displayText)
        case .scalar:
            plainText(value.isNull ? "NULL" : value.displayText)
        }
    }

    private func plainText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    @ViewBuilder
    private func imageView(value: CellValue, format: String) -> some View {
        VStack(spacing: 8) {
            if let data = value.data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                Text("无法解码图片（\(format)）")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportButton(value: CellValue) -> some View {
        Button("导出为文件…") {
            export(value: value)
        }
    }

    private func export(value: CellValue) {
        guard let data = value.data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName(value: value)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            model.error = "写入文件失败：\(error.localizedDescription)"
        }
    }

    private func suggestedFileName(value: CellValue) -> String {
        if case .bytes(let bytes) = value, let format = GridValueFormatter.imageFormat(bytes) {
            return "\(model.title).\(format.lowercased())"
        }
        return "\(model.title).bin"
    }
}
