#if DEBUG
import CoreGraphics
import Foundation

/// Agent 自测用的 Debug 启动参数（`docs/tech-designs/15-testing.md` §9.2）。
///
/// **只在 Debug 构建里存在**（S50）。解析与校验都是纯函数，便于单测；
/// 校验失败一律报错退出，绝不「猜一个目录继续跑」——调试实例写坏真实数据是不可接受的。
struct DevLaunchOptions: Equatable {

    /// `--dev-connect <host>:<port>/<db>`：临时连接，不落盘、不写凭据。
    struct ConnectionSpec: Equatable {
        var host: String
        var port: Int
        var database: String
    }

    /// `--dev-open-table <db.table>`；不带库名时用连接配置里的库。
    struct TableSpec: Equatable {
        var database: String?
        var table: String
    }

    /// 单元格引用，`row` 为 1-based（与网格行号一致），`column` 为列名。
    struct CellRef: Equatable {
        var row: Int
        var column: String
    }

    /// `--dev-edit-cell <row>,<column>=<value>`：造一条未提交改动。
    struct CellEdit: Equatable {
        var row: Int
        var column: String
        var value: SQLValue
    }

    enum TabTarget: String, Equatable {
        case query
        case history
        case console
        case structure
        case definition
    }

    var dataDirectory: URL?
    var defaultsSuite: String?
    var connection: ConnectionSpec?
    var openConnection: String?
    var openTable: TableSpec?
    var openTab: TabTarget?
    var selectCell: CellRef?
    var editCells: [CellEdit] = []
    var appearance: AppearanceMode?
    var windowSize: CGSize?
    var rowLimit: Int?
    var scenario: String?
    var readyFile: URL?

    /// 没有任何 `--dev-*` 参数时为 true：走完全正常的启动路径。
    var isEmpty: Bool {
        dataDirectory == nil && defaultsSuite == nil && connection == nil && openConnection == nil
            && openTable == nil && openTab == nil && selectCell == nil && editCells.isEmpty
            && appearance == nil && windowSize == nil && rowLimit == nil
            && scenario == nil && readyFile == nil
    }
}

// MARK: - 错误

enum DevLaunchError: Error, Equatable, CustomStringConvertible {

    case missingValue(flag: String)
    case invalidValue(flag: String, value: String, expectation: String)
    case unknownFlag(String)
    /// 数据目录指向真实存储根 / `$HOME` / 其祖先：拒绝，避免写坏真实数据。
    case dangerousDataDirectory(String)
    case inappropriateDefaultsSuite(String)
    case unknownScenario(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "\(flag) 缺少参数值"
        case .invalidValue(let flag, let value, let expectation):
            return "\(flag) 的值「\(value)」不合法，期望 \(expectation)"
        case .unknownFlag(let flag):
            return "未知的调试参数 \(flag)（支持的参数见 docs/tech-designs/15-testing.md §9.2）"
        case .dangerousDataDirectory(let path):
            return "--dev-data-dir 「\(path)」指向真实数据目录或它的祖先，拒绝使用"
        case .inappropriateDefaultsSuite(let suite):
            return "--dev-defaults-suite 「\(suite)」与主偏好域相同，拒绝使用"
        case .unknownScenario(let name):
            return "未知的场景「\(name)」（见 DevScenarioRegistry）"
        }
    }
}

// MARK: - 解析

extension DevLaunchOptions {

    /// 支持的参数名（`--dev-` 前缀）。用于「未知 `--dev-*` 直接报错」，防拼错。
    static let knownFlags: Set<String> = [
        "--dev-data-dir", "--dev-defaults-suite", "--dev-connect", "--dev-open-connection",
        "--dev-open-table", "--dev-open-tab", "--dev-select-cell", "--dev-edit-cell",
        "--dev-appearance", "--dev-window-size", "--dev-row-limit", "--dev-scenario",
        "--dev-ready-file"
    ]

    /// 解析参数。纯函数：`liveRoot` / `homeDirectory` 由调用方注入，便于单测。
    static func parse(
        arguments: [String],
        liveRoot: URL,
        homeDirectory: URL,
        mainDefaultsSuite: String = "com.graycarl.tablelite"
    ) throws -> DevLaunchOptions {
        var options = DevLaunchOptions()
        var index = 1 // 跳过可执行文件路径
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--dev-") else {
                index += 1
                continue
            }
            guard knownFlags.contains(argument) else { throw DevLaunchError.unknownFlag(argument) }
            guard index + 1 < arguments.count else { throw DevLaunchError.missingValue(flag: argument) }
            let raw = arguments[index + 1]
            index += 2

            switch argument {
            case "--dev-data-dir":
                options.dataDirectory = try validateDataDirectory(raw, liveRoot: liveRoot, homeDirectory: homeDirectory)
            case "--dev-defaults-suite":
                options.defaultsSuite = try validateDefaultsSuite(raw, mainDefaultsSuite: mainDefaultsSuite)
            case "--dev-connect":
                options.connection = try parseConnection(raw, flag: argument)
            case "--dev-open-connection":
                guard !raw.isEmpty else {
                    throw DevLaunchError.invalidValue(flag: argument, value: raw, expectation: "连接名或 id")
                }
                options.openConnection = raw
            case "--dev-open-table":
                options.openTable = try parseTable(raw, flag: argument)
            case "--dev-open-tab":
                guard let target = TabTarget(rawValue: raw) else {
                    throw DevLaunchError.invalidValue(
                        flag: argument, value: raw,
                        expectation: TabTarget.allCasesDescription
                    )
                }
                options.openTab = target
            case "--dev-select-cell":
                options.selectCell = try parseCell(raw, flag: argument)
            case "--dev-edit-cell":
                options.editCells.append(try parseEdit(raw, flag: argument))
            case "--dev-appearance":
                guard let mode = AppearanceMode(rawValue: raw) else {
                    throw DevLaunchError.invalidValue(flag: argument, value: raw, expectation: "light / dark / system")
                }
                options.appearance = mode
            case "--dev-window-size":
                options.windowSize = try parseWindowSize(raw, flag: argument)
            case "--dev-row-limit":
                guard let limit = Int(raw), RowLimit.isValid(limit) else {
                    throw DevLaunchError.invalidValue(
                        flag: argument, value: raw, expectation: "1…\(RowLimit.maximum) 的整数"
                    )
                }
                options.rowLimit = limit
            case "--dev-scenario":
                options.scenario = raw
            case "--dev-ready-file":
                guard !raw.isEmpty else {
                    throw DevLaunchError.invalidValue(flag: argument, value: raw, expectation: "文件路径")
                }
                options.readyFile = URL(fileURLWithPath: raw)
            default:
                throw DevLaunchError.unknownFlag(argument)
            }
        }
        // `--dev-scenario` 的注册表在运行期才可查；这里只做「写了名字」的形式检查。
        return options
    }

    /// 从当前进程解析；失败直接输出一行 JSON 并退出（脚本据此报错）。
    static func parseFromProcess() -> DevLaunchOptions {
        do {
            return try parse(
                arguments: CommandLine.arguments,
                liveRoot: liveRootURL(),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            let message = (error as? DevLaunchError)?.description ?? String(describing: error)
            DevLaunchOutput.printFailure(message)
            exit(2)
        }
    }

    /// 真实存储根（`Application Support/TableLite`），不创建目录。
    static func liveRootURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(LiveFileSystemLocator.directoryName, isDirectory: true)
    }

    // MARK: 单个参数

    /// 数据目录校验（硬约束，见 `15-testing.md` §9.1）：
    /// 拒绝真实根、真实根的祖先、`$HOME`、`$HOME` 的祖先（含 `/`）与空路径。
    static func validateDataDirectory(_ path: String, liveRoot: URL, homeDirectory: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DevLaunchError.invalidValue(flag: "--dev-data-dir", value: path, expectation: "非空路径")
        }
        let candidate = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        let live = liveRoot.standardizedFileURL
        let home = homeDirectory.standardizedFileURL
        func isAncestor(_ ancestor: URL, of target: URL) -> Bool {
            target.path == ancestor.path || target.path.hasPrefix(ancestor.path + "/")
        }
        guard !isAncestor(candidate, of: live), !isAncestor(candidate, of: home) else {
            throw DevLaunchError.dangerousDataDirectory(candidate.path)
        }
        return candidate
    }

    static func validateDefaultsSuite(_ suite: String, mainDefaultsSuite: String) throws -> String {
        let trimmed = suite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != mainDefaultsSuite else {
            throw DevLaunchError.inappropriateDefaultsSuite(suite)
        }
        return trimmed
    }

    /// `<host>:<port>/<db>`；端口缺省 3306。
    static func parseConnection(_ raw: String, flag: String) throws -> ConnectionSpec {
        let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hostPart = parts.first, !hostPart.isEmpty else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<host>:<port>/<db>")
        }
        let database = parts.count > 1 ? String(parts[1]) : ""
        let hostAndPort = hostPart.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(hostAndPort[0])
        var port = 3306
        if hostAndPort.count > 1 {
            guard let parsed = Int(hostAndPort[1]), (1...65535).contains(parsed) else {
                throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "1…65535 的端口")
            }
            port = parsed
        }
        guard !host.isEmpty else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<host>:<port>/<db>")
        }
        return ConnectionSpec(host: host, port: port, database: database)
    }

    /// `<db.table>`，或 `<table>`（库名留空，运行期回落到连接配置的库）。
    static func parseTable(_ raw: String, flag: String) throws -> TableSpec {
        guard !raw.isEmpty else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<db.table>")
        }
        guard let dot = raw.firstIndex(of: ".") else {
            return TableSpec(database: nil, table: raw)
        }
        let database = String(raw[raw.startIndex..<dot])
        let table = String(raw[raw.index(after: dot)...])
        guard !database.isEmpty, !table.isEmpty else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<db.table>")
        }
        return TableSpec(database: database, table: table)
    }

    /// `<row>,<column>`，行号 1-based。
    static func parseCell(_ raw: String, flag: String) throws -> CellRef {
        let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let row = Int(parts[0]), row >= 1,
              !parts[1].isEmpty else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<行号(1-based)>,<列名>")
        }
        return CellRef(row: row, column: String(parts[1]))
    }

    /// `<row>,<column>=<value>`；`NULL`（大小写不敏感）表示置空，空串表示空文本。
    static func parseEdit(_ raw: String, flag: String) throws -> CellEdit {
        guard let equals = raw.firstIndex(of: "=") else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<行号>,<列名>=<值>")
        }
        let target = String(raw[raw.startIndex..<equals])
        let value = String(raw[raw.index(after: equals)...])
        let cell = try parseCell(target, flag: flag)
        return CellEdit(row: cell.row, column: cell.column, value: value.uppercased() == "NULL" ? .null : .text(value))
    }

    /// `<w>x<h>`。
    static func parseWindowSize(_ raw: String, flag: String) throws -> CGSize {
        let parts = raw.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width >= 320, height >= 240 else {
            throw DevLaunchError.invalidValue(flag: flag, value: raw, expectation: "<宽>x<高>（不小于 320x240）")
        }
        return CGSize(width: width, height: height)
    }
}

// MARK: - 输出

/// 调试脚本消费的输出约定（`15-testing.md` §9.2）。
enum DevLaunchOutput {

    static func printFailure(_ message: String) {
        print(line(["ready": false, "error": message]))
        fflush(stdout)
    }

    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ready\":false,\"error\":\"编码失败\"}"
        }
        return text
    }
}

private extension DevLaunchOptions.TabTarget {
    static var allCasesDescription: String {
        "query / history / console / structure / definition"
    }
}
#endif
