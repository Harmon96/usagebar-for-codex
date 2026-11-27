import Foundation

// Kiro stores text and credits in these logs. Only derived byte counts leave this reader.
extension CatProviderScan {
  mutating func readKiro(_ db: CatProviderDatabase) -> Bool {
    guard let hasLegacy = db.hasTable("conversations_v2"), let hasCurrent = db.hasTable("conversations"),
      hasLegacy || hasCurrent
    else { return false }
    let legacy: [(String?, JSON)]? =
      hasLegacy
      ? db.rows("SELECT conversation_id, value FROM conversations_v2") { row in
        row.object(1).map { (row.text(0), $0) }
      }
      : []
    let current: [(String?, JSON)]? =
      hasCurrent
      ? db.rows("SELECT value FROM conversations") { row in
        row.object(0).map { (Self.string($0["conversation_id"]), $0) }
      }
      : []
    guard let legacy, let current else { return false }
    for (databaseID, conversation) in legacy + current {
      guard let id = databaseID ?? Self.string(conversation["conversation_id"]),
        let turns = conversation["history"] as? [JSON]
      else { continue }
      var history = Self.byteCount(conversation["latest_summary"])
      for turn in turns {
        let prompt = Self.byteCount(turn["user"])
        defer { history += prompt + Self.byteCount(turn["assistant"]) }
        guard let metadata = turn["request_metadata"] as? JSON,
          let date = date(metadata["request_start_timestamp_ms"])
        else { continue }
        let tokens = (history + prompt) / 4 + Self.count(metadata["response_size"]) / 4
        add(.init(id: "\(id)|\(Self.milliseconds(date))", date: date, tokens: tokens, estimated: true))
      }
    }
    return true
  }

  mutating func readKiro(_ url: URL) throws {
    let v3 = url.lastPathComponent == "messages.jsonl"
    let companionURL =
      v3
      ? url.deletingLastPathComponent().appendingPathComponent("session.json")
      : url.deletingPathExtension().appendingPathExtension("json")
    let companion = (try? Data(contentsOf: companionURL)).flatMap(Self.object)
    let sessionID =
      Self.string(companion?[v3 ? "id" : "session_id"])
      ?? (v3 ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent)
    let startedAt = date(companion?["createdAt"])
    var history: Int64 = 0
    var prompt: Int64 = 0
    var assistant: Int64 = 0
    var tool: Int64 = 0
    var turnDate: Date?
    var active = false
    var ordinal = 0
    var turns: [CatUsageSample] = []

    func flush() {
      guard active else { return }
      defer {
        ordinal += 1
        history += prompt + assistant + tool
        prompt = 0
        assistant = 0
        tool = 0
        turnDate = nil
        active = false
      }
      guard let date = turnDate ?? startedAt else { return }
      let count = (history + prompt + tool) / 4 + assistant / 4
      let id =
        v3
        ? "\(sessionID)|\(Self.milliseconds(date))|\(ordinal)"
        : "\(sessionID)|\(Self.milliseconds(date))"
      turns.append(.init(id: id, date: date, tokens: count, estimated: true))
    }

    try Self.forEachRow(in: url) { row in
      if v3 {
        let payload = (row["payload"] as? JSON) ?? row
        let kind = Self.string(payload["type"]) ?? Self.string(payload["role"])
        let rowDate = date(row["timestamp"])
        switch kind {
        case "user", "human", "prompt":
          flush()
          active = true
          turnDate = rowDate
          prompt = Self.contentBytes(payload["content"])
        case "assistant", "bot", "tool_call":
          active = true
          turnDate = turnDate ?? rowDate
          assistant += kind == "tool_call" ? Self.byteCount(payload["args"]) : Self.contentBytes(payload["content"])
        case "tool_result":
          tool += Self.contentBytes(payload["content"])
        case "turn_end":
          turnDate = turnDate ?? rowDate
          flush()
        default: break
        }
      } else {
        let payload = row["data"] as? JSON
        switch Self.string(row["kind"]) {
        case "Prompt":
          flush()
          active = true
          turnDate = date((payload?["meta"] as? JSON)?["timestamp"])
          prompt = Self.contentBytes(payload?["content"])
        case "AssistantMessage":
          assistant += Self.contentBytes(payload?["content"])
        case "ToolResults":
          tool += Self.contentBytes(payload?["content"])
        case "Clear":
          flush()
          history = 0
        default: break
        }
      }
    }
    flush()
    for sample in turns { add(sample) }
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000)
  }

  private static func contentBytes(_ value: Any?) -> Int64 {
    if let text = value as? String { return Int64(text.utf8.count) }
    if let blocks = value as? [Any] { return blocks.reduce(0) { $0 + contentBytes($1) } }
    guard let object = value as? JSON else { return 0 }
    let data = object["data"]
    switch string(object["kind"]) {
    case "text": return contentBytes(data)
    case "toolUse": return byteCount((data as? JSON)?["input"])
    case "toolResult": return contentBytes((data as? JSON)?["content"])
    case "thinking": return contentBytes((data as? JSON)?["text"])
    case "json": return byteCount(data)
    case nil: return contentBytes(object["content"] ?? object["text"] ?? data)
    default: return 0
    }
  }

  private static func byteCount(_ value: Any?) -> Int64 {
    if let text = value as? String { return Int64(text.utf8.count) }
    if let number = value as? NSNumber { return Int64(number.stringValue.utf8.count) }
    if let list = value as? [Any] { return list.reduce(0) { $0 + byteCount($1) } }
    if let object = value as? JSON {
      return object.reduce(0) { total, entry in
        let keys = ["images", "image", "redacted", "signature"]
        return total + (keys.contains(entry.key) ? 0 : byteCount(entry.value))
      }
    }
    return 0
  }
}
