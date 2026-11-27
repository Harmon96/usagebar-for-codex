import AppKit

// Each cell is one pixel of original artwork. Shapes and markings are rendered
// directly from the catalog so every variant is available without a download.
@MainActor
enum CatArt {
  private static let images: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 384
    return cache
  }()

  static func image(
    kind: CatKind?, coat: Int, adult: Bool, shiny: Bool, frame: Int = 0, size: CGFloat = 48
  ) -> NSImage {
    let phase = frame & 3
    let coatIndex = min(max(0, coat), max(0, (kind?.artworkCoats.count ?? 1) - 1))
    let key = "\(kind?.id ?? "box")/\(coatIndex)/\(adult)/\(shiny)/\(phase)/\(size)" as NSString
    if let cached = images.object(forKey: key) { return cached }

    let sprites =
      kind.flatMap { kind -> PixelSprite? in
        guard kind.artworkCoats.indices.contains(coatIndex) else { return nil }
        return renderCat(kind, coat: kind.artworkCoats[coatIndex], adult: adult, shiny: shiny, phase: phase)
      } ?? renderBox(phase: phase)
    let image = sprites.image(size: size)
    images.setObject(image, forKey: key)
    return image
  }

  private static let outline: UInt32 = 0x443449
  private static let glint: UInt32 = 0xFFF3BD

  private static func renderCat(
    _ kind: CatKind, coat: CatCoat, adult: Bool, shiny: Bool, phase: Int
  ) -> PixelSprite {
    let traits = kind.traits
    let floating = kind.fantasy == .ghost ? 1 + phase / 3 : 0
    let headY = (adult ? 4 : 7) + (traits.contains(.shortLegs) ? 1 : 0) - floating
    let headX = traits.contains(.round) ? 3 : 4
    let bodyY = (adult ? 10 : 13) - floating
    let base = shiny ? mix(coat.color, with: 0xF3CCFF, weight: 35) : coat.color
    let marks = shiny ? mix(coat.markings, with: 0xA48CDE, weight: 32) : coat.markings
    let lighter = mix(base, with: 0xFFF3E3, weight: 42)
    let shade = mix(base, with: 0x544967, weight: 30)

    var sprite = PixelSprite()
    sprite.rect(x: 4, y: 21, width: 15, height: 1, color: 0x9A879F)
    sprite.rect(x: 6, y: 22, width: 12, height: 1, color: 0xBAAABF)
    if let effect = kind.fantasy {
      paintAtmosphere(effect, phase: phase, color: marks, on: &sprite)
    }

    if !traits.contains(.tailless) {
      var tail = PixelSprite()
      if traits.contains(.bobtail) {
        tail.rows([1...2, 0...3, 0...3, 1...2], x: 16, y: 13 - floating, color: base)
        tail.rect(x: 17, y: 13 - floating, width: 2, height: 1, color: lighter)
      } else {
        let wag = phase == 1 ? -1 : 0
        let tailX = traits.contains(.slender) ? 19 : 18
        let tip = traits.contains(.fluffy) ? 3 : 2
        tail.rect(x: tailX + wag, y: 8 - floating, width: tip, height: 3, color: lighter)
        tail.rect(x: tailX + 1, y: 10 - floating, width: tip, height: 6, color: base)
        tail.rect(x: tailX, y: 14 - floating, width: tip + 1, height: 3, color: shade)
        tail.rect(x: 16, y: 16 - floating, width: tailX - 14, height: 3, color: base)
        if coat.pattern == .point || coat.pattern == .gloves || coat.pattern == .van {
          tail.tint(Rect(x: tailX - 1, y: 6 - floating, width: 5, height: 6), color: marks)
        } else if coat.pattern == .tabby || coat.pattern == .rosettes {
          tail.tint(Rect(x: tailX, y: 12 - floating, width: 4, height: 1), color: marks)
        }
      }
      sprite.stamp(tail, edged: outline)
    }

    var body = PixelSprite()
    let bodyRows: [ClosedRange<Int>] =
      adult
      ? [5...8, 4...9, 3...10, 2...11, 1...12, 0...13, 0...13, 0...13, 1...13, 1...12, 2...12]
      : [3...5, 2...7, 1...8, 0...9, 0...10, 0...10, 1...10, 1...9]
    body.rows(bodyRows, x: adult ? 4 : 5, y: bodyY, color: base)
    if traits.contains(.fluffy) {
      body.rect(x: 5, y: bodyY + 3, width: 5, height: 6, color: base)
      body.set(4, bodyY + 5, base)
      body.set(10, bodyY + 7, lighter)
    }
    if traits.contains(.slender) {
      body.set(17, bodyY + 5, nil)
      body.set(17, bodyY + 8, nil)
    }
    if traits.contains(.curly) {
      body.set(16, bodyY + 3, base)
      body.set(17, bodyY + 4, lighter)
      body.set(18, bodyY + 6, base)
    }
    body.tint(Rect(x: 4, y: bodyY + (adult ? 7 : 5), width: 15, height: 3), color: shade)
    body.tint(Rect(x: 7, y: bodyY + 2, width: 5, height: 5), color: lighter)
    paintBodyMarkings(coat.pattern, on: &body, y: bodyY, marks: marks, light: lighter)
    if kind.fantasy != .ghost {
      let pawY = 20
      let pawWide = traits.contains(.mittenPaws) ? 4 : 3
      let pawColor = coat.pattern == .gloves ? 0xF8EEE3 : lighter
      body.rect(x: 5, y: pawY - (traits.contains(.shortLegs) ? 0 : 1), width: pawWide, height: 2, color: pawColor)
      body.rect(x: 11, y: pawY, width: pawWide, height: 1, color: pawColor)
    }
    sprite.stamp(body, edged: outline)

    var head = PixelSprite()
    let faceRows: [ClosedRange<Int>] =
      traits.contains(.round)
      ? [2...10, 1...11, 0...12, 0...12, 0...12, 0...12, 1...11, 2...10]
      : [2...10, 1...11, 1...11, 0...12, 0...12, 1...11, 2...10, 3...9]
    head.rows(faceRows, x: headX, y: headY, color: base)
    if traits.contains(.fluffy) {
      head.set(headX - 1, headY + 5, base)
      head.set(headX + 13, headY + 5, base)
    }
    head.tint(Rect(x: headX + 2, y: headY + 1, width: 8, height: 2), color: lighter)
    head.tint(Rect(x: headX, y: headY + 6, width: 14, height: 2), color: shade)
    let innerEar = coat.pattern == .point || coat.pattern == .gloves ? marks : mix(base, with: 0xC67D99, weight: 56)
    paintEars(traits, on: &head, x: headX, y: headY, base: base, inner: innerEar)
    paintFaceMarkings(coat.pattern, on: &head, x: headX, y: headY, marks: marks)
    if traits.contains(.bare) {
      head.rect(x: headX + 4, y: headY + 1, width: 5, height: 1, color: shade)
      head.rect(x: headX + 5, y: headY + 2, width: 3, height: 1, color: shade)
    }
    let blink = phase == 3
    for offset in [3, 8] {
      let eyeX = headX + offset
      let eyeY = headY + (traits.contains(.flatFace) ? 3 : 4)
      head.rect(x: eyeX, y: eyeY, width: 2, height: blink ? 1 : 2, color: outline)
      if !blink {
        head.set(eyeX, eyeY + 1, coat.eyes)
        head.set(eyeX + 1, eyeY, 0xFFF9E7)
      }
    }
    let noseY = headY + (traits.contains(.flatFace) ? 4 : 5)
    head.set(headX + 6, noseY, 0x944C67)
    head.set(headX + 6, noseY + 1, outline)
    head.set(headX + 5, noseY + 1, lighter)
    head.set(headX + 7, noseY + 1, lighter)
    let blush = mix(base, with: 0xE7819E, weight: 55)
    head.set(headX + 2, headY + 6, blush)
    head.set(headX + 10, headY + 6, blush)
    sprite.stamp(head, edged: outline)

    if kind.fantasy == .mushroom {
      var cap = PixelSprite()
      cap.rows([2...6, 1...7, 0...8], x: headX + 2, y: headY - 3, color: marks)
      cap.rect(x: headX + 2, y: headY, width: 9, height: 1, color: 0xEFE0C4)
      cap.set(headX + 5, headY - 2, glint)
      cap.set(headX + 8, headY - 1, 0xFCE4D0)
      sprite.stamp(cap, edged: outline)
    }
    if shiny {
      sprite.sparkle(x: phase == 1 ? 21 : 20, y: 4, color: glint)
      sprite.sparkle(x: 2, y: phase < 2 ? 16 : 15, color: 0xF1AFE5)
    }
    return sprite
  }

  private static func paintEars(
    _ traits: CatTraits, on head: inout PixelSprite, x: Int, y: Int, base: UInt32, inner: UInt32
  ) {
    if traits.contains(.folded) {
      head.rect(x: x + 1, y: y - 1, width: 4, height: 2, color: base)
      head.rect(x: x + 8, y: y - 1, width: 4, height: 2, color: base)
      head.set(x + 2, y, inner)
      head.set(x + 10, y, inner)
      return
    }
    let height = traits.contains(.slender) ? 4 : 3
    head.rows([0...0, 0...1, 0...2], x: x + 1, y: y - height, color: base)
    head.rows([2...2, 1...2, 0...2], x: x + 9, y: y - height, color: base)
    head.rect(x: x + 1, y: y - 1, width: 3, height: 2, color: base)
    head.rect(x: x + 9, y: y - 1, width: 3, height: 2, color: base)
    head.rect(x: x + 2, y: y - 1, width: 1, height: 2, color: inner)
    head.rect(x: x + 10, y: y - 1, width: 1, height: 2, color: inner)
    if traits.contains(.tufted) {
      let tuftY = max(0, y - height - 1)
      head.set(x, tuftY, outline)
      head.set(x + 12, tuftY, outline)
    } else if traits.contains(.curledEars) {
      head.set(x, y - height + 1, base)
      head.set(x + 12, y - height + 1, base)
      head.set(x + 1, y - height, nil)
      head.set(x + 11, y - height, nil)
    }
  }

  private static func paintBodyMarkings(
    _ pattern: CatPattern, on body: inout PixelSprite, y: Int, marks: UInt32, light: UInt32
  ) {
    switch pattern {
    case .solid:
      break
    case .tabby:
      for dx in [0, 3, 6] {
        body.tint(Rect(x: 10 + dx, y: y + 3, width: 1, height: 3), color: marks)
        body.tint(Rect(x: 9 + dx, y: y + 5, width: 2, height: 1), color: marks)
      }
    case .waves:
      for (offset, width) in [(3, 5), (6, 4)] {
        body.tint(Rect(x: 9, y: y + offset, width: width, height: 1), color: marks)
        body.tint(Rect(x: 10 + width, y: y + offset - 1, width: 2, height: 1), color: marks)
      }
    case .spots, .rosettes:
      for (spotX, dy) in [(10, 3), (14, 3), (11, 6), (15, 6)] {
        let side = pattern == .spots ? 1 : 2
        body.tint(Rect(x: spotX, y: y + dy, width: side, height: side), color: marks)
        if pattern == .rosettes {
          body.tint(Rect(x: spotX, y: y + dy, width: 1, height: 1), color: light)
        }
      }
    case .ticked, .smoke:
      body.tint(Rect(x: 9, y: y + 4, width: 7, height: 1), color: marks)
      body.tint(Rect(x: 12, y: y + 6, width: 4, height: 1), color: marks)
    case .tuxedo, .gloves:
      body.tint(Rect(x: 5, y: y + 2, width: 5, height: 3), color: 0xF9EEE1)
      body.tint(Rect(x: 6, y: y + 4, width: 3, height: 3), color: 0xF9EEE1)
    case .point:
      body.tint(Rect(x: 4, y: y + 7, width: 6, height: 4), color: marks)
    case .calico, .tortie, .bicolor:
      body.tint(Rect(x: 12, y: y + 2, width: 6, height: 3), color: marks)
      body.tint(Rect(x: 11, y: y + 4, width: 5, height: 2), color: marks)
      let second = pattern == .calico ? 0x665471 : (pattern == .tortie ? light : marks)
      body.tint(Rect(x: 5, y: y + 6, width: 4, height: 3), color: second)
    case .van:
      break
    }
  }

  private static func paintFaceMarkings(
    _ pattern: CatPattern, on head: inout PixelSprite, x: Int, y: Int, marks: UInt32
  ) {
    switch pattern {
    case .ticked, .tabby, .waves:
      head.tint(Rect(x: x + 3, y: y + 2, width: 1, height: 2), color: marks)
      head.tint(Rect(x: x + 6, y: y + 1, width: 1, height: 3), color: marks)
      head.tint(Rect(x: x + 9, y: y + 2, width: 1, height: 2), color: marks)
    case .spots, .rosettes:
      head.set(x + 2, y + 3, marks)
      head.set(x + 9, y + 2, marks)
      head.set(x + 6, y + 2, marks)
    case .point, .gloves:
      head.tint(Rect(x: x + 2, y: y + 3, width: 9, height: 3), color: marks)
      head.tint(Rect(x: x + 4, y: y + 5, width: 5, height: 2), color: marks)
      if pattern == .gloves {
        head.rect(x: x + 6, y: y + 3, width: 1, height: 2, color: 0xF7EADF)
      }
    case .tuxedo:
      head.tint(Rect(x: x + 4, y: y + 5, width: 5, height: 3), color: marks)
      head.set(x + 6, y + 4, marks)
    case .calico, .tortie, .bicolor, .van:
      head.tint(Rect(x: x + 1, y: y - 2, width: 4, height: 6), color: marks)
      head.tint(
        Rect(x: x + 8, y: y - 2, width: 4, height: 4),
        color: pattern == .calico ? 0x665471 : marks)
    case .solid, .smoke:
      break
    }
  }

  private static func paintAtmosphere(
    _ effect: CatFantasy, phase: Int, color: UInt32, on sprite: inout PixelSprite
  ) {
    switch effect {
    case .moon:
      sprite.rows([2...3, 1...2, 0...1, 0...1, 0...2, 1...4, 2...3], x: 17, y: 0, color: glint)
      sprite.set(3, 4, color)
    case .ghost:
      sprite.rect(x: 2, y: 18 - phase / 3, width: 4, height: 1, color: color)
      sprite.rect(x: 16, y: 16, width: 6, height: 1, color: color)
      sprite.rect(x: 19, y: 18, width: 2, height: 1, color: 0xB9B0D4)
      sprite.set(4, 6, color)
    case .cloud:
      sprite.rows([1...3, 0...5, 0...6, 1...5], x: 16, y: 5, color: color)
      sprite.rect(x: 1, y: 15, width: 5, height: 2, color: color)
    case .mushroom:
      sprite.rect(x: 19, y: 19, width: 4, height: 1, color: color)
      sprite.set(20, 20, 0xF4DBB6)
    case .ember:
      sprite.rows([2...2, 2...3, 1...3, 0...4, 0...3, 1...2], x: 18, y: 3 - phase / 2, color: color)
      sprite.set(20, 8 - phase / 2, glint)
      sprite.set(17, 3, color)
    case .frost:
      sprite.sparkle(x: 19, y: 4, color: color)
      sprite.sparkle(x: 3, y: 15, color: 0x9BD8F5)
      sprite.set(21, 6, 0xDEFAFF)
    case .aurora:
      for i in 0..<8 {
        let y = 4 - i / 3 + (phase == 1 ? 1 : 0)
        sprite.set(14 + i, y, color)
        sprite.set(14 + i, y + 1, 0x9B84D5)
      }
      sprite.set(2, 5, color)
    case .constellation:
      sprite.sparkle(x: 19, y: 4, color: color)
      sprite.set(17, 2, glint)
      sprite.set(22, 7, color)
      sprite.set(2, 12, color)
      sprite.set(2, 17, glint)
    }
  }

  private static func renderBox(phase: Int) -> PixelSprite {
    var sprite = PixelSprite()
    sprite.rect(x: 4, y: 19, width: 16, height: 1, color: 0xA293AA)
    var box = PixelSprite()
    box.rows([3...13, 2...14, 1...15, 0...16, 0...16], x: 3, y: 5, color: 0xF0BA78)
    box.rect(x: 4, y: 10, width: 15, height: 9, color: 0xC88F61)
    box.rect(x: 4, y: 10, width: 11, height: 9, color: 0xE0A36D)
    box.rect(x: 4, y: 9, width: 15, height: 1, color: 0xF5CE8D)
    box.rect(x: 10, y: 6, width: 3, height: 5, color: 0xF6DEAC)
    box.set(10, 11, 0xF6DEAC)
    box.set(12, 11, 0xF6DEAC)
    box.rect(x: 7, y: 14, width: 5, height: 3, color: 0xF8ECCF)
    box.rect(x: 8, y: 15, width: 3, height: 1, color: 0xA37166)
    box.rect(x: 15, y: 16, width: 3, height: 1, color: 0xAD6D58)
    sprite.stamp(box, edged: outline)
    if phase == 1 || phase == 2 {
      sprite.sparkle(x: 19, y: 5, color: glint)
    }
    return sprite
  }

  private static func mix(_ color: UInt32, with other: UInt32, weight: UInt32) -> UInt32 {
    var result: UInt32 = 0
    for shift in [0, 8, 16] {
      let a = (color >> shift) & 0xFF
      let b = (other >> shift) & 0xFF
      result |= ((a * (100 - weight) + b * weight) / 100) << shift
    }
    return result
  }
}

private struct Rect {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
}

private struct PixelSprite {
  private static let side = 24
  private var cells = [UInt32?](repeating: nil, count: side * side)

  private func index(_ x: Int, _ y: Int) -> Int? {
    guard (0..<Self.side).contains(x), (0..<Self.side).contains(y) else { return nil }
    return y * Self.side + x
  }

  mutating func set(_ x: Int, _ y: Int, _ color: UInt32?) {
    guard let position = index(x, y) else { return }
    cells[position] = color
  }

  mutating func rows(_ spans: [ClosedRange<Int>], x: Int, y: Int, color: UInt32) {
    for (i, span) in spans.enumerated() {
      for dx in span { set(x + dx, y + i, color) }
    }
  }

  mutating func rect(x: Int, y: Int, width: Int, height: Int, color: UInt32) {
    for dy in 0..<height {
      for dx in 0..<width { set(x + dx, y + dy, color) }
    }
  }

  mutating func tint(_ rect: Rect, color: UInt32) {
    for y in rect.y..<(rect.y + rect.height) {
      for x in rect.x..<(rect.x + rect.width) {
        if let position = index(x, y), cells[position] != nil {
          cells[position] = color
        }
      }
    }
  }

  mutating func stamp(_ sprite: Self, edged outline: UInt32) {
    let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    for (position, pixel) in sprite.cells.enumerated() where pixel != nil {
      let x = position % Self.side
      let y = position / Self.side
      for (dx, dy) in neighbors {
        set(x + dx, y + dy, outline)
      }
    }
    for (position, pixel) in sprite.cells.enumerated() {
      if let pixel { cells[position] = pixel }
    }
  }

  mutating func sparkle(x: Int, y: Int, color: UInt32) {
    rect(x: x - 1, y: y, width: 3, height: 1, color: color)
    rect(x: x, y: y - 1, width: 1, height: 3, color: color)
    set(x, y, 0xFFFDF3)
  }

  @MainActor
  func image(size: CGFloat) -> NSImage {
    let bitmapSize = Self.side * 3
    let logicalSize = NSSize(width: size, height: size)
    var bytes = [UInt8](repeating: 0, count: bitmapSize * bitmapSize * 4)
    for y in 0..<bitmapSize {
      for x in 0..<bitmapSize {
        guard let color = cells[(y / 3) * Self.side + x / 3] else { continue }
        let offset = (y * bitmapSize + x) * 4
        bytes[offset] = UInt8(truncatingIfNeeded: color >> 16)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: color >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: color)
        bytes[offset + 3] = 255
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let cgImage = CGImage(
        width: bitmapSize, height: bitmapSize, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bitmapSize * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return NSImage(size: logicalSize) }
    return NSImage(cgImage: cgImage, size: logicalSize)
  }
}
