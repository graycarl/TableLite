import AppKit
import SwiftUI

// MARK: - 横向分栏拖拽手柄

/// 主体区横向分栏之间的拖拽手柄（左侧栏 / 右侧字段栏共用）。
///
/// 只负责「把拖拽位移换算成新的宽度并夹到区间内」，宽度本身由调用方持有的
/// `PreferencesStore` 持久化（见 `specs/02-workspace.md` §1）。
/// 右侧字段栏由表数据视图自己渲染，本组件不感知它的内容。
struct SplitHandle: View {

    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 拖拽结束时回调一次，用于落盘（拖动过程中只改内存值）。
    var onCommit: (Double) -> Void = { _ in }

    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? width
                        if dragStart == nil { dragStart = start }
                        let next = start + Double(value.translation.width)
                        width = min(max(next, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit(width)
                    }
            )
    }
}
