import Foundation

// MARK: - 推断类型

/// 从 CSV 内容推断出的列类型。UI 下拉里可手改（`specs/08-import-export.md` §2「从 CSV 新建表」）。
public enum CSVColumnType: String, Sendable, CaseIterable, Equatable, Hashable {
    case int
    case bigint
    case decimal
    case dateTime
    case varchar
    case text

    public var sqlText: String {
        switch self {
        case .int: return "INT"
        case .bigint: return "BIGINT"
        case .decimal: return "DECIMAL(10,2)"
        case .dateTime: return "DATETIME"
        case .varchar: return "VARCHAR(255)"
        case .text: return "TEXT"
        }
    }

    public var displayName: String { sqlText }
}

/// 一列的推断结果。
public struct CSVColumnInference: Sendable, Equatable, Identifiable {
    public var name: String
    public var type: CSVColumnType
    /// 推断依据，展示在「推断依据」列。
    public var reason: String

    public var id: String { name }

    public init(name: String, type: CSVColumnType, reason: String) {
        self.name = name
        self.type = type
        self.reason = reason
    }
}

/// CSV 列名规整与类型推断。纯函数。
public enum CSVTypeInference {

    /// 默认采样行数。
    public static let defaultSampleCount = 100

    // MARK: 列名

    /// 生成目标列名：优先用表头；为空 / 重复时用 `col_N`（N 从 1 开始）。
    public static func columnNames(header: [String]?, columnCount: Int) -> [String] {
        guard columnCount > 0 else { return [] }
        var seen: Set<String> = []
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            let raw = header.flatMap { index < $0.count ? $0[index] : nil }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var candidate = raw
            if candidate.isEmpty || seen.contains(candidate) {
                candidate = "col_\(index + 1)"
            }
            // 极端情况下 col_N 也可能撞名，继续退让。
            var suffix = index + 1
            while seen.contains(candidate) {
                suffix += 1
                candidate = "col_\(suffix)"
            }
            seen.insert(candidate)
            names.append(candidate)
        }
        return names
    }

    // MARK: 推断

    /// 按前 `sampleCount` 行推断每列类型。空值行参与判断时被忽略。
    public static func infer(
        header: [String]?,
        rows: [[String]],
        sampleCount: Int = defaultSampleCount
    ) -> [CSVColumnInference] {
        let columnCount = header?.count ?? rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return [] }
        let names = columnNames(header: header, columnCount: columnCount)
        let sample = rows.prefix(max(1, sampleCount))

        return (0..<columnCount).map { index in
            let values = sample.compactMap { row -> String? in
                guard index < row.count else { return nil }
                let value = row[index]
                return value.isEmpty ? nil : value
            }
            let (type, reason) = classify(values)
            return CSVColumnInference(name: names[index], type: type, reason: reason)
        }
    }

    /// 单列分类。
    public static func classify(_ values: [String]) -> (CSVColumnType, String) {
        guard !values.isEmpty else { return (.varchar, "空列，按文本") }

        if values.allSatisfy({ isInteger($0) }) {
            let exceedsInt32 = values.contains { value in
                guard let number = Int64(value) else { return true }
                return number > Int64(Int32.max) || number < Int64(Int32.min)
            }
            return exceedsInt32 ? (.bigint, "整数超出 INT 范围") : (.int, "全是整数")
        }

        if values.allSatisfy({ isDecimal($0) }) {
            return (.decimal, "带小数点的数字")
        }

        if values.allSatisfy({ isDateTime($0) }) {
            return (.dateTime, "形如日期时间")
        }

        let longest = values.map(\.count).max() ?? 0
        if longest > 1024 {
            return (.text, "文本，内容较长")
        }
        return (.varchar, "文本")
    }

    // MARK: 判定

    /// `[+-]?digits`。
    public static func isInteger(_ text: String) -> Bool {
        var index = text.startIndex
        guard index < text.endIndex else { return false }
        if text[index] == "+" || text[index] == "-" { index = text.index(after: index) }
        guard index < text.endIndex else { return false }
        var sawDigit = false
        while index < text.endIndex {
            guard let value = text[index].asciiValue, (48...57).contains(value) else { return false }
            sawDigit = true
            index = text.index(after: index)
        }
        return sawDigit
    }

    /// `[+-]?digits[.digits]`，必须含小数点。
    public static func isDecimal(_ text: String) -> Bool {
        var index = text.startIndex
        guard index < text.endIndex else { return false }
        if text[index] == "+" || text[index] == "-" { index = text.index(after: index) }
        var sawDigit = false
        var sawDot = false
        while index < text.endIndex {
            let character = text[index]
            if let value = character.asciiValue, (48...57).contains(value) {
                sawDigit = true
            } else if character == ".", !sawDot {
                sawDot = true
            } else {
                return false
            }
            index = text.index(after: index)
        }
        return sawDigit && sawDot
    }

    /// `YYYY-MM-DD`（可带 `[ T]HH:MM[:SS[.fff]]`）。
    public static func isDateTime(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 10 else { return false }

        func digits(_ range: Range<Int>) -> Bool {
            guard range.lowerBound >= 0, range.upperBound <= characters.count else { return false }
            return range.allSatisfy { index in
                guard let value = characters[index].asciiValue else { return false }
                return (48...57).contains(value)
            }
        }

        guard characters[4] == "-", characters[7] == "-",
              digits(0..<4), digits(5..<7), digits(8..<10) else { return false }
        if characters.count == 10 { return true }

        guard characters[10] == " " || characters[10] == "T", characters.count >= 16,
              characters[13] == ":", digits(11..<13), digits(14..<16) else { return false }

        var index = 16
        if index < characters.count, characters[index] == ":" {
            guard index + 3 <= characters.count, digits((index + 1)..<(index + 3)) else { return false }
            index += 3
        }
        if index < characters.count, characters[index] == "." {
            index += 1
            var sawDigit = false
            while index < characters.count, let value = characters[index].asciiValue, (48...57).contains(value) {
                sawDigit = true
                index += 1
            }
            guard sawDigit else { return false }
        }
        return index == characters.count
    }
}
