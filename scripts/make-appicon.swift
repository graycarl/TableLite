#!/usr/bin/env swift
//
// 生成 TableLite 的 App 图标（不引入任何外部素材）。
//
// 用法：`swift scripts/make-appicon.swift`
// 产物：Sources/TableLite/Resources/Assets.xcassets/AppIcon.appiconset/ 下
//       1024 主图 + macOS 需要的全部 1x / 2x 尺寸，以及 Contents.json。
//
// 设计（关键决策见 docs/tech-designs/12-build-and-deps.md §4「App 图标」）：
//   · 圆角方块，靛蓝渐变底，左上角一点高光；
//   · 中间一块白色「数据表」面板：浅灰网格 + 各单元格里的数据条；
//   · 其中一整行用薄荷色高亮 —— 一眼看出「这是一个可以选中 / 编辑的数据网格」。
//   小尺寸不做等比缩小，而是减少行列、加粗网格线，保证 16 / 32 px 下仍然清楚。
//
// 尺寸对齐苹果 macOS 图标网格：1024 画布内形状 816×816，
// 加阴影后的不透明包围盒 ≈ 864（inset 上 88 / 左右 80 / 下 72），与系统自带图标一致。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 设计常量

/// 圆角方块在 1024 画布里的内缩量（816×816）。
private let shapeInset: CGFloat = 104
/// 面板相对方块的内缩量。
private let panelInset: CGFloat = 142
/// 面板圆角。
private let panelRadius: CGFloat = 86

private func rgb(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

private let gradientTop = rgb(0x5C7BFF)
private let gradientBottom = rgb(0x1C28C4)
private let highlightColor = rgb(0x36E2C0)   // 高亮行
private let gridColor = rgb(0xD5DCEB)        // 网格线与数据条
private let shadowColor = rgb(0x0A1024, 0.30)

// MARK: - 矢量绘制

/// 苹果风格 squircle（超椭圆 n = 5 的近似，n = 2 是椭圆，越大越方）。
private func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let exponent: CGFloat = 2 / 5
    let steps = 900
    for index in 0...steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * pow(abs(ct), exponent) * (ct < 0 ? -1 : 1)
        let y = rect.midY + b * pow(abs(st), exponent) * (st < 0 ? -1 : 1)
        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

private func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private extension CGContext {
    /// 用竖直渐变填充路径。
    func fillGradient(_ path: CGPath, _ colors: [NSColor], from start: CGPoint, to end: CGPoint) {
        saveGState()
        addPath(path)
        clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors.map(\.cgColor) as CFArray,
                                  locations: nil)!
        drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }

    func fill(_ path: CGPath, _ color: NSColor) {
        saveGState()
        addPath(path)
        setFillColor(color.cgColor)
        fillPath()
        restoreGState()
    }

    func strokeLines(_ color: NSColor, width: CGFloat, _ build: () -> Void) {
        saveGState()
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        setLineCap(.round)
        beginPath()
        build()
        strokePath()
        restoreGState()
    }
}

/// 小尺寸下的简化策略：行列更少、线更粗，信息量下降但轮廓不变。
private struct GridLayout {
    let columns: Int
    let rows: Int
    let lineWidth: CGFloat
    let showsBars: Bool

    static func forSize(_ size: CGFloat) -> GridLayout {
        switch size {
        case ..<48: GridLayout(columns: 2, rows: 3, lineWidth: 34, showsBars: false)
        case ..<96: GridLayout(columns: 3, rows: 3, lineWidth: 24, showsBars: false)
        default: GridLayout(columns: 3, rows: 4, lineWidth: 13, showsBars: true)
        }
    }
}

/// 在一个边长为 `size` 的上下文中画图标。所有坐标按 `size / 1024` 缩放。
private func drawIcon(in context: CGContext, size: CGFloat) {
    context.scaleBy(x: size / 1024, y: size / 1024)

    let layout = GridLayout.forSize(size)
    let shape = CGRect(x: shapeInset, y: shapeInset,
                       width: 1024 - shapeInset * 2, height: 1024 - shapeInset * 2)
    let shapePath = squircle(shape)

    // 投影：小尺寸下省掉，避免 16px 糊成一团。
    if size >= 32 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: shadowColor.cgColor)
        context.fill(shapePath, .black)
        context.restoreGState()
    }

    // 底色
    context.fillGradient(shapePath, [gradientTop, gradientBottom],
                         from: CGPoint(x: 104, y: 920), to: CGPoint(x: 104, y: 104))
    // 左上角高光
    context.saveGState()
    context.addPath(shapePath)
    context.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.20).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    context.drawRadialGradient(sheen, startCenter: CGPoint(x: 360, y: 820), startRadius: 0,
                               endCenter: CGPoint(x: 360, y: 820), endRadius: 780, options: [])
    context.restoreGState()

    // 白色数据表面板
    let panel = shape.insetBy(dx: panelInset, dy: panelInset)
    let panelPath = roundedRect(panel, panelRadius)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: shadowColor.cgColor)
    context.fill(panelPath, .white)
    context.restoreGState()

    // 面板内容：网格 + 数据条 + 一整行高亮
    context.saveGState()
    context.addPath(panelPath)
    context.clip()

    let columns = layout.columns, rows = layout.rows
    let cellWidth = panel.width / CGFloat(columns), rowHeight = panel.height / CGFloat(rows)
    let highlightedRow = rows / 2

    func rowRect(_ row: Int) -> CGRect {
        CGRect(x: panel.minX, y: panel.maxY - rowHeight * CGFloat(row + 1),
               width: panel.width, height: rowHeight)
    }

    context.setFillColor(highlightColor.cgColor)
    context.fill(rowRect(highlightedRow))
    context.strokeLines(gridColor, width: layout.lineWidth) {
        for column in 1..<columns {
            let x = panel.minX + cellWidth * CGFloat(column)
            context.move(to: CGPoint(x: x, y: panel.minY))
            context.addLine(to: CGPoint(x: x, y: panel.maxY))
        }
        for row in 1..<rows {
            let y = panel.minY + rowHeight * CGFloat(row)
            context.move(to: CGPoint(x: panel.minX, y: y))
            context.addLine(to: CGPoint(x: panel.maxX, y: y))
        }
    }

    if layout.showsBars {
        let barHeight = rowHeight * 0.20
        for row in 0..<rows where row != highlightedRow {
            for column in 0..<columns {
                let cell = CGRect(x: panel.minX + cellWidth * CGFloat(column),
                                  y: panel.maxY - rowHeight * CGFloat(row + 1),
                                  width: cellWidth, height: rowHeight)
                let width = cell.width * (column == columns - 1 ? 0.42 : 0.62)
                let bar = CGRect(x: cell.minX + cell.width * 0.22, y: cell.midY - barHeight / 2,
                                 width: width, height: barHeight)
                context.fill(roundedRect(bar, barHeight / 2), gridColor)
            }
        }
    }

    context.restoreGState()
}

// MARK: - 输出

private func pngData(pixelSize: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("无法创建 \(pixelSize)x\(pixelSize) 的绘图上下文")
    }
    drawIcon(in: context, size: CGFloat(pixelSize))
    guard let image = context.makeImage() else {
        fatalError("无法生成位图")
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("无法编码 PNG")
    }
    return data
}

// 每个文件对应的像素尺寸。
let files: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root
    .appendingPathComponent("Sources/TableLite/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for file in files {
    let url = outputDirectory.appendingPathComponent(file.name)
    try pngData(pixelSize: file.size).write(to: url)
    print("写入 \(file.name)（\(file.size)×\(file.size)）")
}

// Contents.json（macOS AppIcon 集合）。
struct Entry: Encodable {
    let idiom = "mac"
    let scale: String
    let size: String
    let filename: String
}
struct Catalog: Encodable {
    struct Info: Encodable {
        let author = "xcode"
        let version = 1
    }
    let images: [Entry]
    let info = Info()
}

let entries: [Entry] = [
    Entry(scale: "1x", size: "16x16", filename: "icon_16x16.png"),
    Entry(scale: "2x", size: "16x16", filename: "icon_16x16@2x.png"),
    Entry(scale: "1x", size: "32x32", filename: "icon_32x32.png"),
    Entry(scale: "2x", size: "32x32", filename: "icon_32x32@2x.png"),
    Entry(scale: "1x", size: "128x128", filename: "icon_128x128.png"),
    Entry(scale: "2x", size: "128x128", filename: "icon_128x128@2x.png"),
    Entry(scale: "1x", size: "256x256", filename: "icon_256x256.png"),
    Entry(scale: "2x", size: "256x256", filename: "icon_256x256@2x.png"),
    Entry(scale: "1x", size: "512x512", filename: "icon_512x512.png"),
    Entry(scale: "2x", size: "512x512", filename: "icon_512x512@2x.png"),
]

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let contentsData = try encoder.encode(Catalog(images: entries))
try contentsData.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("写入 Contents.json")
