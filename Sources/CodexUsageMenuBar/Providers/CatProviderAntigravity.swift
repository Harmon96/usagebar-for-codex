import Foundation

// Cascade protobuf field numbers and timing correlation adapted from PokeTokenBar (MIT).
extension CatProviderScan {
  func antigravityRecords(_ db: CatProviderDatabase, url: URL) -> [CatUsageSample]? {
    struct Step {
      let responseID: String?
      let executionID: String?
      let date: Date
    }
    guard let hasSteps = db.hasTable("steps") else { return nil }
    let steps: [Step]? =
      hasSteps
      ? db.rows("SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") { row in
        guard let data = row.data(0) else { return nil }
        let fields = CatProviderProto(data)
        guard let date = fields.timestamp(8) ?? fields.timestamp(1) else { return nil }
        return Step(responseID: fields.message(9)?.string(11), executionID: fields.string(12), date: date)
      }
      : []
    guard let steps else { return nil }
    var responseDates: [String: Date] = [:]
    var executionDates: [String: [Date]] = [:]
    for step in steps {
      if let id = step.responseID { responseDates[id] = step.date }
      if let id = step.executionID { executionDates[id, default: []].append(step.date) }
    }

    let conversation = url.deletingPathExtension().lastPathComponent
    var offsets: [String: Int] = [:]
    return db.rows("SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx") { row in
      guard let data = row.data(1) else { return nil }
      let record = CatProviderProto(data)
      guard let model = record.message(1), let usage = model.message(4) else { return nil }
      let response = usage.string(11)
      let date: Date?
      if let start = model.message(9), start.message(4) != nil {
        date = start.timestamp(4)
      } else if let response, let exact = responseDates[response] {
        date = exact
      } else if let execution = record.string(4), let candidates = executionDates[execution], !candidates.isEmpty {
        let offset = offsets[execution, default: 0]
        offsets[execution] = offset + 1
        date = candidates[min(offset, candidates.count - 1)]
      } else {
        date = nil
      }
      guard let date else { return nil }
      let tokens = (2...5).reduce(Int64(0)) { total, field in
        let number = usage.integer(field) ?? 0
        return total + (number <= 1_000_000_000 ? Int64(number) : 0)
      }
      return CatUsageSample(id: response ?? "\(conversation)|\(row.integer(0))", date: date, tokens: tokens)
    }
  }
}

private struct CatProviderProto {
  private var integers: [Int: UInt64] = [:]
  private var bytes: [Int: ArraySlice<UInt8>] = [:]

  init(_ data: Data) { self.init(Array(data)[...]) }

  private init(_ data: ArraySlice<UInt8>) {
    var position = data.startIndex
    func varint() -> UInt64? {
      var value: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        guard position < data.endIndex else { return nil }
        let byte = data[position]
        position += 1
        guard shift != 63 || byte <= 1 else { return nil }
        value |= UInt64(byte & 0x7f) << shift
        if byte & 0x80 == 0 { return value }
      }
      return nil
    }

    while position < data.endIndex {
      guard let key = varint(), key >> 3 > 0, key >> 3 <= 536_870_911 else { return }
      let field = Int(key >> 3)
      switch key & 7 {
      case 0:
        guard let value = varint() else { return }
        integers[field] = value
      case 1:
        guard data.endIndex - position >= 8 else { return }
        position += 8
      case 2:
        guard let length = varint(), length <= UInt64(data.endIndex - position) else { return }
        let end = position + Int(length)
        bytes[field] = data[position..<end]
        position = end
      case 5:
        guard data.endIndex - position >= 4 else { return }
        position += 4
      default:
        return
      }
    }
  }

  func integer(_ field: Int) -> UInt64? { integers[field] }

  func message(_ field: Int) -> CatProviderProto? { bytes[field].map(Self.init) }

  func string(_ field: Int) -> String? {
    guard let data = bytes[field], !data.isEmpty else { return nil }
    return String(bytes: data, encoding: .utf8)
  }

  func timestamp(_ field: Int) -> Date? {
    guard let stamp = message(field), let seconds = stamp.integer(1),
      (1_000_000_000...4_102_444_800).contains(seconds)
    else { return nil }
    let nanos = stamp.integer(2) ?? 0
    guard nanos < 1_000_000_000 else { return nil }
    return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
  }
}
