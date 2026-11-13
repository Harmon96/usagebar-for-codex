import AppKit
import SwiftUI

// 저장된 HEX를 검증하고 RGB 색으로 변환한다.
enum GaugeColor {
  static func normalized(_ hex: String) -> String? {
    let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return digits.uppercased()
  }

  static func color(hex: String) -> Color? {
    guard let normalized = normalized(hex), let value = UInt32(normalized, radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255
    )
  }
}

// 작은 팝업에서 HEX 입력과 RGB 슬라이더로 막대 색을 즉시 편집한다.
struct GaugeColorEditor: View {
  @Binding var hex: String
  @State private var draft = ""
  @State private var invalidHex = false

  private var selectedColor: Color { GaugeColor.color(hex: hex) ?? .purple }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("진행 막대 색상").font(.headline)
      ColorPicker("색상 선택", selection: colorBinding, supportsOpacity: false)
      HStack {
        Text("HEX").font(.caption).foregroundStyle(.secondary)
        TextField("RRGGBB", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { applyHex() }
          .onChange(of: draft) { _, value in
            if let normalized = GaugeColor.normalized(value) {
              hex = normalized
              invalidHex = false
            }
          }
        Button("적용") { applyHex() }
      }
      if invalidHex {
        Text("6자리 HEX를 입력하세요. 예: #A855F7")
          .font(.caption).foregroundStyle(.red)
      }
      ForEach(0..<3) { channel in
        HStack(spacing: 8) {
          Text(["R", "G", "B"][channel]).font(.caption.monospaced()).frame(width: 12)
          Slider(value: channelBinding(channel), in: 0...255, step: 1)
          Text("\(Int(channelBinding(channel).wrappedValue))")
            .font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
        }
      }
      RoundedRectangle(cornerRadius: 5)
        .fill(
          LinearGradient(
            colors: [selectedColor.opacity(0.5), selectedColor], startPoint: .leading, endPoint: .trailing)
        )
        .frame(height: 10)
      Text("잔여량 20% 이하는 경고 색상으로 표시됩니다.")
        .font(.caption2).foregroundStyle(.secondary)
      Button("기본 색상으로 복원") {
        hex = ""
        draft = ""
        invalidHex = false
      }
      .font(.caption)
    }
    .padding(16)
    .frame(width: 260)
    .onAppear { draft = hex }
    .onChange(of: hex) { _, value in
      if GaugeColor.normalized(draft) != value { draft = value }
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { selectedColor },
      set: { color in
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        hex = String(
          format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
          Int((rgb.blueComponent * 255).rounded()))
      })
  }

  // RGB 한 채널만 수정하면서 나머지 채널은 유지한다.
  private func channelBinding(_ channel: Int) -> Binding<Double> {
    Binding(
      get: {
        let rgb = NSColor(selectedColor).usingColorSpace(.sRGB) ?? .systemPurple
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent][channel] * 255
      },
      set: { value in
        let rgb = NSColor(selectedColor).usingColorSpace(.sRGB) ?? .systemPurple
        var channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        channels[channel] = value / 255
        colorBinding.wrappedValue = Color(red: channels[0], green: channels[1], blue: channels[2])
      })
  }

  private func applyHex() {
    guard let normalized = GaugeColor.normalized(draft) else {
      invalidHex = true
      return
    }
    hex = normalized
    draft = normalized
    invalidHex = false
  }
}
