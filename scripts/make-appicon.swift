#!/usr/bin/env swift
//
// 生成 TableLite 的 App 图标（不引入任何外部素材）。
//
// 用法：`swift scripts/make-appicon.swift`
// 产物：Sources/TableLite/Resources/Assets.xcassets/AppIcon.appiconset/ 下
//       1024 主图 + macOS 需要的全部 1x / 2x 尺寸，以及 Contents.json。
//
// 图标主题：圆角矩形底 + 蓝紫渐变，中间是一张白底的「表」（表头条 + 2 列 3 行网格）。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 矢量绘制

/// 在一个边长为 `size` 的上下文中画图标。所有坐标按 `size / 1024` 缩放。
func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)

    // 圆角矩形底（macOS Big Sur 的 squircle 近似半径）。
    let cornerRadius = 1024 * 0.2237 * scale
    let background = CGPath(
        roundedRect: canvas,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let topColor = NSColor(calibratedRed: 0.29, green: 0.53, blue: 0.98, alpha: 1).cgColor
    let bottomColor = NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.82, alpha: 1).cgColor
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // 白底卡片。
    let margin = 190 * scale
    let card = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cardRadius = 110 * scale
    let cardPath = CGPath(
        roundedRect: card,
        cornerWidth: cardRadius,
        cornerHeight: cardRadius,
        transform: nil
    )
    context.addPath(cardPath)
    context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    context.fillPath()

    // 表头条（更深的蓝）。
    context.saveGState()
    context.addPath(cardPath)
    context.clip()
    let headerHeight = card.height * 0.24
    let header = CGRect(x: card.minX, y: card.maxY - headerHeight, width: card.width, height: headerHeight)
    context.setFillColor(NSColor(calibratedRed: 0.20, green: 0.38, blue: 0.88, alpha: 1).cgColor)
    context.fill(header)
    context.restoreGState()

    // 网格线：2 列 × 3 行，用浅蓝灰。
    let lineColor = NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.86, alpha: 1).cgColor
    let lineWidth = 12 * scale
    let bodyTop = card.maxY - headerHeight
    let columnDividerX = card.midX

    context.setStrokeColor(lineColor)
    context.setLineWidth(lineWidth)
    // 竖线
    context.move(to: CGPoint(x: columnDividerX, y: card.minY + 6 * scale))
    context.addLine(to: CGPoint(x: columnDividerX, y: bodyTop - 6 * scale))
    context.strokePath()
    // 横线（把表体分成 3 行）
    for index in 1..<3 {
        let y = card.minY + card.height * CGFloat(index) / 3
        context.move(to: CGPoint(x: card.minX + 6 * scale, y: y))
        context.addLine(to: CGPoint(x: card.maxX - 6 * scale, y: y))
    }
    context.strokePath()

    // 表头里两处「列名」色块，弱化。
    let chipColor = NSColor.white.withAlphaComponent(0.75).cgColor
    context.setFillColor(chipColor)
    let chipHeight = headerHeight * 0.30
    let chipY = header.midY - chipHeight / 2
    let chipWidths: [CGFloat] = [0.24, 0.30]
    var chipX = card.minX + card.width * 0.10
    for widthRatio in chipWidths {
        let width = card.width * widthRatio
        context.fill(CGRect(x: chipX, y: chipY, width: width, height: chipHeight))
        chipX += width + card.width * 0.10
    }

    context.restoreGState()
}

// MARK: - 输出

func pngData(pixelSize: Int) -> Data {
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
