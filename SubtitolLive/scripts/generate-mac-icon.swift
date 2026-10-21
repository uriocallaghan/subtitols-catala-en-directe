// Makes the Mac App Store icon set from the iPhone icon: the square artwork is set in
// the macOS icon grid (an 824 pt rounded square centred in 1024, corner radius 185),
// then written at every size the macOS AppIcon set needs.
//   swift scripts/generate-mac-icon.swift
import AppKit

let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = package.appendingPathComponent("iOS/SubtitolLiveiOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let output = package.appendingPathComponent("iOS/SubtitolLiveMac/Assets.xcassets/AppIcon.appiconset")

guard let artwork = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Missing \(source.path)")
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.clip()
    context.draw(artwork, in: tile)
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "AppIcon-\(points)@\(factor)x.png"
        try render(pixels: points * factor).write(to: output.appendingPathComponent(name))
        images.append([
            "filename": name, "idiom": "mac",
            "scale": "\(factor)x", "size": "\(points)x\(points)",
        ])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
