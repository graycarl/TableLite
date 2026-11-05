#!/usr/bin/env swift
// AX 驱动工具（Agent 自测基建，见 docs/tech-designs/15-testing.md §9.4）。
//
// 只做「定位 → 读取 / 合成输入」，不做业务判断；全部输出 JSON。
// 由 scripts/dev/axctl.sh 编译到 .build/tools/axctl（源码更新时才重编）。
//
// 硬约束：
// - 一律按 --pid 定位进程（调试实例与真实实例 bundle id 相同）；
// - dump 必须剪枝：AXTable 默认不展开（200 列 × 1000 行 ≈ 20 万节点）；
// - 网格用 cell 按 (row, column) 寻址，不靠逐格 identifier。

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - 输出

func emit(_ object: [String: Any], status: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(status)
}

/// 失败一律 `exit 1`：脚本用退出码判断成败（selftest 的断言依赖这一点）。
func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message], status: 1)
}

// MARK: - 参数

struct Args {
    var command: String
    var positionals: [String]
    var flags: [String: String]
    /// 真正带值的 flag：`--text true` 里的 `true` 也是值，不能按字符串猜。
    var valued: Set<String>

    static func parse(_ argv: [String]) -> Args {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var valued: Set<String> = []
        var command = ""
        var index = 1
        while index < argv.count {
            let item = argv[index]
            if item.hasPrefix("--") {
                if let equals = item.firstIndex(of: "=") {
                    let name = String(item[item.index(item.startIndex, offsetBy: 2)..<equals])
                    flags[name] = String(item[item.index(after: equals)...])
                    valued.insert(name)
                    index += 1
                } else {
                    let name = String(item.dropFirst(2))
                    if index + 1 < argv.count, !argv[index + 1].hasPrefix("--") {
                        flags[name] = argv[index + 1]
                        valued.insert(name)
                        index += 2
                    } else {
                        flags[name] = "true"
                        index += 1
                    }
                }
            } else if command.isEmpty {
                command = item
                index += 1
            } else {
                positionals.append(item)
                index += 1
            }
        }
        return Args(command: command, positionals: positionals, flags: flags, valued: valued)
    }

    func flag(_ name: String) -> String? {
        valued.contains(name) ? flags[name] : nil
    }

    func bool(_ name: String) -> Bool {
        flags[name] != nil
    }

    func int(_ name: String) -> Int? {
        flag(name).flatMap(Int.init)
    }
}

let args = Args.parse(CommandLine.arguments)
let pid: pid_t = {
    if let value = args.flag("pid").flatMap(pid_t.init) { return value }
    // 没给 --pid 时读调试实例的 PID 文件（tl.sh 会传，这里兜底）。
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let devDir = ProcessInfo.processInfo.environment["TL_DEV_DIR"].map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent(".build/dev-data")
    let pidFile = devDir.appendingPathComponent("app.pid")
    if let text = try? String(contentsOf: pidFile, encoding: .utf8),
       let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return value
    }
    fail("缺少 --pid（调试实例的进程号；tl.sh 会自动注入）")
}()

let appElement = AXUIElementCreateApplication(pid)

// MARK: - AX 基础

func copyAttribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
    copyAttribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func attributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func axRole(_ element: AXUIElement) -> String {
    stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
}

func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let value = copyAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let value = copyAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

func frame(of element: AXUIElement) -> [String: Double]? {
    guard let origin = pointAttribute(element, kAXPositionAttribute as CFString),
          let size = sizeAttribute(element, kAXSizeAttribute as CFString) else { return nil }
    return ["x": origin.x, "y": origin.y, "width": size.width, "height": size.height]
}

func elementDescription(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var node: [String: Any] = [
        "role": axRole(element),
        "depth": depth
    ]
    if let subrole = stringAttribute(element, kAXSubroleAttribute as CFString), !subrole.isEmpty {
        node["subrole"] = subrole
    }
    if let title = stringAttribute(element, kAXTitleAttribute as CFString), !title.isEmpty {
        node["title"] = title
    }
    if let desc = stringAttribute(element, kAXDescriptionAttribute as CFString), !desc.isEmpty {
        node["desc"] = desc
    }
    if let identifier = stringAttribute(element, "AXIdentifier" as CFString), !identifier.isEmpty {
        node["id"] = identifier
    }
    if let value = copyAttribute(element, kAXValueAttribute as CFString) as? String, !value.isEmpty {
        node["value"] = value
    }
    if let position = frame(of: element) {
        node["frame"] = position
    }
    if let enabled = copyAttribute(element, kAXEnabledAttribute as CFString) as? Bool {
        node["enabled"] = enabled
    }
    return node
}

// MARK: - 定位

struct Selector {
    var id: String?
    var role: String?
    var title: String?
    var desc: String?
    var within: String?

    var isEmpty: Bool {
        id == nil && role == nil && title == nil && desc == nil
    }

    func matches(_ element: AXUIElement) -> Bool {
        if let id, stringAttribute(element, "AXIdentifier" as CFString) != id { return false }
        if let role, axRole(element) != role { return false }
        if let title, stringAttribute(element, kAXTitleAttribute as CFString) != title { return false }
        if let desc, stringAttribute(element, kAXDescriptionAttribute as CFString) != desc { return false }
        return true
    }
}

func selectorFrom(_ args: Args) -> Selector {
    Selector(
        id: args.flag("id"),
        role: args.flag("role"),
        title: args.flag("title"),
        desc: args.flag("desc"),
        within: args.flag("within")
    )
}

/// 深度优先搜索；`AXTable` 默认剪枝（除非目标就是行 / 单元格，或显式 `--no-prune`）。
func findElements(
    in root: AXUIElement,
    selector: Selector,
    limit: Int = 20,
    pruneTables: Bool = true
) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let targetIsGridChild = selector.role == "AXRow" || selector.role == "AXCell"
    func walk(_ element: AXUIElement, depth: Int) {
        guard results.count < limit, depth < 40 else { return }
        if selector.matches(element) {
            results.append(element)
        }
        if pruneTables, !targetIsGridChild, axRole(element) == "AXTable" {
            return
        }
        for child in children(element) { walk(child, depth: depth + 1) }
    }
    walk(root, depth: 0)
    return results
}

func rootForSearch(_ args: Args, selector: Selector) -> AXUIElement {
    guard let within = selector.within else { return appElement }
    var inner = selector
    inner.within = nil
    inner.id = within
    guard let anchor = findElements(in: appElement, selector: inner, limit: 1).first else {
        fail("找不到 --within 指定的容器「\(within)」")
    }
    return anchor
}

func resolve(_ args: Args, verb: String) -> AXUIElement {
    let selector = selectorFrom(args)
    guard !selector.isEmpty else { fail("\(verb) 需要 --id / --role / --title / --desc 之一") }
    let root = rootForSearch(args, selector: selector)
    var inner = selector
    inner.within = nil
    let matches = findElements(in: root, selector: inner, pruneTables: !args.bool("no-prune"))
    let index = args.int("nth") ?? 0
    guard index < matches.count else {
        fail("没找到匹配元素（共 \(matches.count) 个，nth=\(index)）")
    }
    return matches[index]
}

// MARK: - 网格

func tableElement() -> AXUIElement? {
    let selector = Selector(id: args.flag("table-id"), role: "AXTable", title: nil, desc: nil, within: nil)
    return findElements(in: appElement, selector: selector, limit: 1).first
}

func gridRows(_ table: AXUIElement) -> [AXUIElement] {
    (copyAttribute(table, "AXRows" as CFString) as? [AXUIElement]) ?? children(table)
}

/// 列名 → 列下标。`NSTableView` 的 `AXColumn` 带 `AXIdentifier`（就是列标识），
/// 自定义表头不会给出 `AXTitle`，所以 identifier 才是可靠来源。
func columnTitles(_ table: AXUIElement) -> [String] {
    guard let columns = copyAttribute(table, "AXColumns" as CFString) as? [AXUIElement] else { return [] }
    return columns.map { column in
        if let identifier = stringAttribute(column, "AXIdentifier" as CFString), !identifier.isEmpty { return identifier }
        if let title = stringAttribute(column, kAXTitleAttribute as CFString), !title.isEmpty { return title }
        if let value = stringAttribute(column, kAXValueAttribute as CFString), !value.isEmpty { return value }
        return ""
    }
}

struct CellTarget {
    var row: Int
    var column: Int
    var element: AXUIElement
}

func resolveCell(row requestedRow: Int, column requestedColumn: String) -> CellTarget {
    guard let table = tableElement() else { fail("找不到 AXTable（网格没打开？）") }
    let rows = gridRows(table)
    guard requestedRow >= 1 else { fail("行号从 1 开始") }

    var rowElement: AXUIElement?
    if let byIndex = rows.first(where: {
        (copyAttribute($0, kAXIndexAttribute as CFString) as? Int) == requestedRow - 1
    }) {
        rowElement = byIndex
    } else if requestedRow - 1 < rows.count {
        rowElement = rows[requestedRow - 1]
    }
    guard let rowElement else { fail("行号 \(requestedRow) 超出范围（共 \(rows.count) 行）") }

    let titles = columnTitles(table)
    let columnIndex: Int
    if let numeric = Int(requestedColumn) {
        columnIndex = numeric
    } else if let index = titles.firstIndex(of: requestedColumn) {
        columnIndex = index
    } else {
        fail("找不到列「\(requestedColumn)」；可用列：\(titles.prefix(40).joined(separator: ", "))")
    }

    let cells = children(rowElement)
    guard let cell = cells.first(where: { element in
        guard let range = copyAttribute(element, "AXColumnIndexRange" as CFString),
              CFGetTypeID(range) == AXValueGetTypeID() else { return false }
        var value = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &value) else { return false }
        return value.location == columnIndex
    }) else {
        fail("找不到第 \(columnIndex) 列的单元格（该行共 \(cells.count) 个）")
    }
    return CellTarget(row: requestedRow, column: columnIndex, element: cell)
}

func cellText(_ element: AXUIElement) -> String {
    var pieces: [String] = []
    func walk(_ node: AXUIElement, depth: Int) {
        guard depth < 6 else { return }
        if axRole(node) == "AXStaticText" {
            if let value = copyAttribute(node, kAXValueAttribute as CFString) as? String { pieces.append(value) }
        }
        for child in children(node) { walk(child, depth: depth + 1) }
    }
    walk(element, depth: 0)
    return pieces.joined()
}

// MARK: - 输入合成

/// 把目标 app 激活。用 AX 的 `AXFrontmost`（按 PID）而不是 `NSRunningApplication.activate`：
/// 两个实例同名时前者才能精确指定，后者可能作用到另一个同名进程上。
func activateTargetApp() {
    AXUIElementSetAttributeValue(appElement, "AXFrontmost" as CFString, kCFBooleanTrue)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
        usleep(50_000)
    }
    usleep(80_000)
}

func supportsPress(_ element: AXUIElement) -> Bool {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success,
          let names = actions as? [String] else { return false }
    return names.contains(kAXPressAction as String)
}

func click(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(30_000)
    up?.post(tap: .cghidEventTap)
}

func keyCode(for name: String) -> CGKeyCode? {
    let map: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "esc": kVK_Escape, "escape": kVK_Escape,
        "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
    ]
    return map[name.lowercased()].map { CGKeyCode($0) }
}

func pressKey(_ combo: String) {
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, let code = keyCode(for: keyName) else {
        fail("不认识的按键组合「\(combo)」")
    }
    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
        switch modifier {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: fail("不认识的修饰键「\(modifier)」")
        }
    }
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    // 带修饰键的快捷键走菜单路由，CGEventPostToPid 不一定能命中 SwiftUI 的 key equivalent；
    // 先把目标 app 激活，再发全局事件。
    activateTargetApp()
    down?.post(tap: .cghidEventTap)
    usleep(20_000)
    up?.post(tap: .cghidEventTap)
}

func typeText(_ text: String) {
    // 纯 ASCII 直接发 Unicode 事件；含非 ASCII（中文等）走剪贴板 + ⌘V，避免输入法依赖。
    if text.allSatisfy({ $0.isASCII }) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var unit = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down?.postToPid(pid)
            up?.postToPid(pid)
            // 逐字符间隔：灌太快会被 App 的输入节流合并，最后只剩几个字符。
            usleep(12_000)
        }
        return
    }
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pressKey("cmd+v")
    usleep(150_000)
    if let saved {
        pasteboard.clearContents()
        pasteboard.setString(saved, forType: .string)
    }
}

// MARK: - 命令

switch args.command {
case "terminate":
    // 按 PID 发退出（走 applicationShouldTerminate，未提交改动的确认框有机会弹出）。
    // 绝不按 bundle id 找 app：调试实例与真实实例同名。
    guard let running = NSRunningApplication(processIdentifier: pid) else {
        fail("找不到 pid=\(pid) 的应用")
    }
    emit(["ok": running.terminate(), "pid": pid])

case "activate":
    activateTargetApp()
    emit([
        "ok": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
        "pid": pid,
        "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
        "frontmost_name": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    ])

case "doctor":
    emit([
        "ok": true,
        "accessibility": AXIsProcessTrusted(),
        "pid": pid
    ])

case "window":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    var windows = list.compactMap { info -> [String: Any]? in
        guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        var result: [String: Any] = [:]
        result["id"] = info[kCGWindowNumber as String] ?? 0
        result["name"] = info[kCGWindowName as String] ?? ""
        if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
            result["frame"] = bounds
            let width = (bounds["Width"] as? Double) ?? 0
            let height = (bounds["Height"] as? Double) ?? 0
            result["area"] = width * height
        }
        return result
    }
    // 主窗口在前：sheet / 确认框的 layer 也是 0，按面积排序避免截到弹窗。
    windows.sort { (($0["area"] as? Double) ?? 0) > (($1["area"] as? Double) ?? 0) }
    emit(["ok": true, "pid": pid, "windows": windows])

case "dump":
    let maxDepth = args.int("depth") ?? 6
    let roleFilter = args.flag("role")
    let prune = !args.bool("no-prune")
    var nodes: [[String: Any]] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth <= maxDepth, nodes.count < 4000 else { return }
        var node = elementDescription(element, depth: depth)
        let childCount = (copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement])?.count ?? 0
        node["childCount"] = childCount
        if roleFilter == nil || axRole(element) == roleFilter { nodes.append(node) }
        if prune, axRole(element) == "AXTable" {
            node["pruned"] = true
            return
        }
        for child in children(element) { walk(child, depth: depth + 1) }
    }
    walk(appElement, depth: 0)
    emit(["ok": true, "pid": pid, "nodes": nodes])

case "find":
    let selector = selectorFrom(args)
    guard !selector.isEmpty else { fail("find 需要 --id / --role / --title / --desc 之一") }
    let root = rootForSearch(args, selector: selector)
    var inner = selector
    inner.within = nil
    let matches = findElements(
        in: root,
        selector: inner,
        limit: args.int("limit") ?? 20,
        pruneTables: !args.bool("no-prune")
    )
    emit([
        "ok": true,
        "count": matches.count,
        "elements": matches.map { elementDescription($0) }
    ])

case "click":
    if let cellSpec = args.flag("cell") {
        let parts = cellSpec.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let row = Int(parts[0]) else { fail("--cell 需要 <行号>,<列名>") }
        let target = resolveCell(row: row, column: parts[1])
        if args.bool("press") {
            AXUIElementPerformAction(target.element, kAXPressAction as CFString)
        } else {
            guard let position = pointAttribute(target.element, kAXPositionAttribute as CFString),
                  let size = sizeAttribute(target.element, kAXSizeAttribute as CFString) else {
                fail("单元格没有位置信息")
            }
            activateTargetApp()
            click(at: CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
        }
        emit(["ok": true, "clicked": "cell", "row": row, "column": parts[1]])
    }
    let element = resolve(args, verb: "click")
    // 优先 AXPress：与真实点击等价，且不受窗口遮挡与焦点影响。
    if args.bool("press") || (!args.bool("coords") && supportsPress(element)) {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        emit(["ok": result == .success, "action": "AXPress", "element": elementDescription(element)])
    }
    guard let position = pointAttribute(element, kAXPositionAttribute as CFString),
          let size = sizeAttribute(element, kAXSizeAttribute as CFString) else {
        fail("元素没有位置信息，可能不可见")
    }
    activateTargetApp()
    click(at: CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2))
    emit(["ok": true, "clicked": elementDescription(element)])

case "press":
    let element = resolve(args, verb: "press")
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    emit(["ok": result == .success, "element": elementDescription(element)])

case "set-value":
    guard let text = args.flag("text") ?? args.positionals.first else { fail("set-value 需要 --text <值>") }
    let element = resolve(args, verb: "set-value")
    // 与 type 同一个坑：SwiftUI TextField 不在焦点上时，写 AXValue 不会进入 Binding。
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(80_000)
    let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
    emit(["ok": result == .success, "element": elementDescription(element)], status: result == .success ? 0 : 1)

case "cell":
    guard let row = args.int("row"), let column = args.flag("column") ?? args.positionals.first else {
        fail("cell 需要 --row <行号> --column <列名|列序号>")
    }
    let target = resolveCell(row: row, column: column)
    if args.bool("scroll") {
        AXUIElementPerformAction(target.element, "AXScrollToVisible" as CFString)
    }
    emit([
        "ok": true,
        "row": target.row,
        "column": target.column,
        "text": cellText(target.element),
        "frame": frame(of: target.element) ?? [:]
    ])

case "type":
    guard let text = args.flag("text") ?? args.positionals.first else { fail("type 需要 --text <文本>") }
    if let id = args.flag("id") {
        var inner = args
        inner.flags["id"] = id
        let element = resolve(inner, verb: "type")
        if !args.bool("keys") {
            // 默认直接写 AXValue：实测能触发 SwiftUI 的 Binding，且比逐字符灌键稳定得多
            // （逐字符灌键会被 App 的输入节流合并，长文本可能只剩前几个字符）。
            // **必须先聚焦**：TextField 不在焦点上时，AXValue 改动不会进入 Binding，
            // 随后点「应用」会读到旧草稿（2026-11-04 踩过）。
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(80_000)
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            guard result == .success else { fail("写入 AXValue 失败（\(result.rawValue)）") }
            emit(["ok": true, "mode": "set-value", "element": elementDescription(element)])
        }
        // `--keys`：走真实键盘输入，用来验证输入法 / 输入事件路径本身。
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(120_000)
        pressKey("cmd+a")   // 覆盖原内容：自动化输入默认是「替换整段」
        usleep(60_000)
        typeText(text)
        emit(["ok": true, "mode": "keys", "text": text])
    }
    typeText(text)
    emit(["ok": true, "mode": "keys", "text": text])

case "key":
    guard let combo = args.flag("combo") ?? args.positionals.first else { fail("key 需要 --combo <cmd+shift+f>") }
    pressKey(combo)
    emit(["ok": true, "key": combo])

case "wait":
    let selector = selectorFrom(args)
    guard !selector.isEmpty else { fail("wait 需要 --id / --role / --title / --desc 之一") }
    let timeout = args.flag("timeout").flatMap(Double.init) ?? 10
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let root = rootForSearch(args, selector: selector)
        var inner = selector
        inner.within = nil
        if !findElements(in: root, selector: inner, limit: 1).isEmpty {
            emit(["ok": true, "waited": Date().timeIntervalSince1970])
        }
        usleep(100_000)
    }
    fail("等待超时（\(Int(timeout))s，条件 \(selector.id ?? selector.role ?? selector.title ?? selector.desc ?? "?")）")

case "attr":
    guard let name = args.flag("name") ?? args.positionals.first else { fail("attr 需要 --name <AX 属性名>") }
    let element = resolve(args, verb: "attr")
    guard let value = copyAttribute(element, name as CFString) else {
        fail("元素没有属性 \(name)；可用属性：\(attributeNames(element).joined(separator: ", "))")
    }
    if let list = value as? [AXUIElement] {
        emit(["ok": true, "count": list.count, "elements": list.map { elementDescription($0) }])
    }
    emit(["ok": true, "value": String(describing: value)])

case "attributes":
    let element = resolve(args, verb: "attributes")
    emit(["ok": true, "attributes": attributeNames(element), "element": elementDescription(element)])

case "help", "":
    print("""
    axctl — TableLite 的 AX 驱动（见 docs/tech-designs/15-testing.md §9.4）

      axctl doctor                      --pid P
      axctl window                      --pid P
      axctl dump [--depth N] [--role R] [--no-prune]
      axctl find   --id X | --role R [--title T] [--within ID] [--nth N] [--limit N]
      axctl click  --id X [--press] | --cell <row>,<column>
      axctl press  --id X
      axctl set-value --id X --text V
      axctl type   --text V [--id X]
      axctl key    --combo cmd+shift+f
      axctl cell   --row N --column <列名|序号> [--scroll]
      axctl wait   --id X [--timeout S]
      axctl attributes --id X
    """)

default:
    fail("未知命令「\(args.command)」，用 axctl help 查看用法")
}
