import Foundation
import Observation

// MARK: - 加载状态

/// 表结构视图的加载状态。
enum TableStructureLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// 结构加载失败时的结构化错误，供错误面板按 `specs/12-feedback.md` §5 展示：
/// 原始 message 不翻译、错误码与 SQLSTATE 单独一行。
struct SchemaLoadError: Sendable, Equatable {
    /// 服务器原文（或客户端侧说明），**原样展示，不翻译不截断**。
    var message: String
    /// 服务器错误码；客户端侧错误为 nil。
    var code: UInt32?
    var sqlState: String?
    /// 出错语句的前 200 字符。
    var statement: String?

    init(error: Error) {
        if let mysql = error as? MySQLError {
            self.message = mysql.message
            self.code = mysql.code == 0 ? nil : mysql.code
            self.sqlState = mysql.sqlState.isEmpty ? nil : mysql.sqlState
            self.statement = mysql.statement
        } else {
            self.message = String(describing: error)
            self.code = nil
            self.sqlState = nil
            self.statement = nil
        }
    }
}

// MARK: - 子页签

/// 结构视图的子页签。顺序即界面顺序（`specs/07-schema-view.md` §2.5）。
enum SchemaStructurePage: String, CaseIterable, Identifiable, Sendable {
    case columns
    case indexes
    case foreignKeys
    case triggers
    case definition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .columns: return "列"
        case .indexes: return "索引"
        case .foreignKeys: return "外键"
        case .triggers: return "触发器"
        case .definition: return "建表语句"
        }
    }
}

// MARK: - ViewModel

/// 表结构标签（P9）的 ViewModel。只读：只读取与展示，不做任何 DDL。
///
/// 状态归属见 `docs/tech-designs/06-ui-layer.md` §2：每个标签的 ViewModel 由标签自己持有。
/// 数据一律经 `MetaRepository`（协议 `TableStructureProviding`），不直接碰 `MySQLSession`。
///
/// 关键行为：
/// - 打开时读一次结构；`tab.isStale`（执行过 DDL）时强制刷新并清掉过期标记
///   （`specs/07-schema-view.md` §4）；
/// - 行数用 `information_schema.TABLES` 估算，标注「约」，绝不自动 `COUNT(*)`（L10）；
/// - 视图只展示「列」与「定义」两页；对象定义标签只展示「定义」页（§3）。
@MainActor
@Observable
final class TableStructureViewModel {

    // MARK: 身份

    let session: ConnectionSession
    let tab: Tab
    let database: String
    let objectName: String
    /// 打开标签时按标签种类推断的对象类型（表 / 视图）。
    let requestedKind: TableKind

    @ObservationIgnored private let provider: any TableStructureProviding
    @ObservationIgnored private let clipboard: any SchemaClipboard

    // MARK: 状态

    private(set) var structure: TableStructure?
    private(set) var loadState: TableStructureLoadState = .idle
    private(set) var loadError: SchemaLoadError?
    private(set) var copyNotice: String?

    var selectedPage: SchemaStructurePage

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var copyNoticeTask: Task<Void, Never>?

    // MARK: 初始化

    init(
        session: ConnectionSession,
        tab: Tab,
        provider: (any TableStructureProviding)? = nil,
        clipboard: (any SchemaClipboard)? = nil
    ) {
        self.session = session
        self.tab = tab
        self.provider = provider ?? LiveTableStructureProvider(repository: session.meta)
        self.clipboard = clipboard ?? SystemSchemaClipboard()

        switch tab.kind {
        case .tableStructure(let database, let table):
            self.database = database
            self.objectName = table
            // 对象树里视图“打开结构”也走 `.tableStructure`，没有单独的标签种类。
            // 从已加载的对象目录里认出视图，才能立即把页签收成「列 / 定义」
            // 并给 `SHOW CREATE VIEW` 传对类型（`specs/07-schema-view.md` §3）。
            self.requestedKind = session.objects.first {
                $0.database == database && $0.name == table
            }?.kind ?? .table
            self.selectedPage = .columns
        case .objectDefinition(let database, let object):
            self.database = database
            self.objectName = object
            self.requestedKind = .view
            self.selectedPage = .definition
        default:
            self.database = tab.kind.database ?? session.selectedDatabase ?? ""
            self.objectName = tab.kind.objectName ?? ""
            self.requestedKind = .table
            self.selectedPage = .columns
        }
    }

    // MARK: 派生属性

    /// 「可能过期」提示条是否显示（`specs/07-schema-view.md` §4、`specs/12-feedback.md` §7）。
    var isStale: Bool { tab.isStale }

    var isView: Bool {
        structure?.table.kind == .view || requestedKind == .view
    }

    /// 对象定义标签只显示「定义」页；表结构标签按对象类型给页签。
    var isObjectDefinitionTab: Bool {
        if case .objectDefinition = tab.kind { return true }
        return false
    }

    /// 是否为「表结构」标签（底部概况条只在这一类标签上显示，`specs/07-schema-view.md` §5）。
    var isTableStructureTab: Bool {
        if case .tableStructure = tab.kind { return true }
        return false
    }

    /// 当前对象可用的子页签。
    var pages: [SchemaStructurePage] {
        if isObjectDefinitionTab { return [.definition] }
        if isView { return [.columns, .definition] }
        return SchemaStructurePage.allCases
    }

    /// 「定义」页签在视图上叫「定义」，表上叫「建表语句」（`specs/07-schema-view.md` §2.5）。
    var definitionPageTitle: String { isView ? "定义" : "建表语句" }

    func pageTitle(_ page: SchemaStructurePage) -> String {
        page == .definition ? definitionPageTitle : page.title
    }

    /// 结构标签底部条的概况：`11 列 · 3 索引 · 1 外键 · 0 触发器`（`specs/07-schema-view.md` §5）。
    /// 视图没有索引 / 外键 / 触发器，不显示。
    var statusSummary: String? { isTableStructureTab ? structure?.summary : nil }

    var tableComment: String? {
        guard let comment = structure?.table.comment, !comment.isEmpty else { return nil }
        return comment
    }

    var isEmptyDefinition: Bool {
        (structure?.createStatement ?? "").isEmpty
    }

    // MARK: 生命周期

    /// 首次进入标签时加载。`tab.isStale` 为真时强制刷新（恢复的连接会话 / 执行过 DDL）。
    func start() async {
        guard !didStart else { return }
        didStart = true
        await load(forceRefresh: tab.isStale)
    }

    /// `⌘R` 或过期提示条里的「刷新」：先失效 `MetaRepository` 缓存再强制读一次。
    func refresh() async {
        await session.meta.invalidateTable(database: database, table: objectName)
        await load(forceRefresh: true)
    }

    private func load(forceRefresh: Bool) async {
        loadState = .loading
        loadError = nil
        do {
            let result = try await provider.loadStructure(
                database: database,
                table: objectName,
                kind: requestedKind,
                forceRefresh: forceRefresh
            )
            structure = result
            // 读到最新结构后过期提示条消失（`specs/07-schema-view.md` §4）。
            if tab.isStale { tab.isStale = false }
            loadState = .loaded
        } catch {
            loadError = SchemaLoadError(error: error)
            loadState = .failed
        }
    }

    /// 标签关闭时取消在途的轻提示，避免泄漏。
    func cancelInFlight() {
        copyNoticeTask?.cancel()
        copyNoticeTask = nil
    }

    // MARK: 操作

    /// 复制建表 / 定义语句到剪贴板。
    func copyDefinition() {
        guard let sql = structure?.createStatement, !sql.isEmpty else { return }
        clipboard.write(sql)
        showCopyNotice(isView ? "已复制定义语句" : "已复制建表语句")
    }

    /// 「在新查询标签中编辑」：把定义原文填进新的查询标签，改完由用户自己执行
    /// （`specs/07-schema-view.md` §3）。
    func editDefinitionInNewQuery() {
        guard let sql = structure?.createStatement, !sql.isEmpty else { return }
        session.newQueryTab(initialSQL: sql)
    }

    /// 点外键的「引用表」：跳到那张表的数据标签（`specs/07-schema-view.md` §2.3）。
    func openReferencedTable(_ foreignKey: ForeignKeyInfo) {
        let referenced = foreignKey.referencedDatabase.flatMap { $0.isEmpty ? nil : $0 }
        session.openTableData(
            database: referenced ?? database,
            table: foreignKey.referencedTable
        )
    }

    private func showCopyNotice(_ text: String) {
        copyNotice = text
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.copyNotice = nil
        }
    }
}
