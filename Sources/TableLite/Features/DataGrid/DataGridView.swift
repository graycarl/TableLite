import AppKit
import SwiftUI

// MARK: - 数据网格（SwiftUI 桥）
//
// `NSViewRepresentable` 只声明参数与回调；数据源 / 委托 / 增量刷新都在
// `DataGridController` 里。见 docs/tech-designs/06-ui-layer.md §4。
struct DataGridView: NSViewRepresentable {

    @ObservedObject var model: TableDataViewModel
    var preferences: PreferencesStore
    var failedRow: RowIdentity?

    var onQuickLook: (RowIdentity, String) -> Void
    var onBeginEdit: (RowIdentity, String) -> Void
    var onForeignKeyJump: (RowIdentity, String, CellValue) -> Void
    var onToast: (String) -> Void
    var onFilterByValue: (String, CellValue, Bool) -> Void
    /// 右键列头 → 按此列筛选（加条件、值留空）。
    var onFilterByColumn: (String) -> Void = { _ in }
    var onExportSelected: ((Set<RowIdentity>) -> Void)?
    var onRequestPreview: () -> Void
    var onRequestCommit: () -> Void
    var onRequestDiscard: () -> Void
    var literalizerProvider: () async -> SQLValueLiteralizer

    func makeCoordinator() -> DataGridController {
        DataGridController(preferences: preferences)
    }

    func makeNSView(context: Context) -> DataGridTableView {
        let tableView = DataGridTableView()
        context.coordinator.configure(tableView: tableView)
        return tableView
    }

    func updateNSView(_ nsView: DataGridTableView, context: Context) {
        let controller = context.coordinator
        controller.onQuickLook = onQuickLook
        controller.onBeginEdit = onBeginEdit
        controller.onForeignKeyJump = onForeignKeyJump
        controller.onToast = onToast
        controller.onFilterByValue = onFilterByValue
        controller.onFilterByColumn = onFilterByColumn
        controller.onExportSelected = onExportSelected
        controller.onRequestPreview = onRequestPreview
        controller.onRequestCommit = onRequestCommit
        controller.onRequestDiscard = onRequestDiscard
        controller.literalizerProvider = literalizerProvider

        let appearance = GridAppearance(
            nullText: preferences.nullDisplayText,
            fontSize: preferences.gridFontSize,
            alternatingRows: preferences.gridAlternatingRows
        )
        controller.update(model: model,
                          preferences: preferences,
                          appearance: appearance,
                          failedRow: failedRow)
    }
}
