import Foundation

// Local record formats adapted from PokeTokenBar (MIT), commit 38e3e5532846d407ae1a80fe15c4e49a0c263d65.
extension CatProviderScan {
  mutating func readLog(_ url: URL) {
    do {
      if provider == .gemini {
        try readGemini(url)
      } else if provider == .openCode {
        let contents = try Data(contentsOf: url, options: .mappedIfSafe)
        if let object = Self.object(contents) {
          addOpenCode(object, fallbackID: url.deletingPathExtension().lastPathComponent)
        }
      } else if provider == .kiro {
        try readKiro(url)
      } else if provider != .grok || !Self.isGrokSubagent(url) {
        let needle =
          switch provider {
          case .grok: "turn_completed"
          case .kimi: "usage.record"
          default: "\"usage\""
          }
        try Self.forEachRow(in: url, containing: needle) { row in
          switch provider {
          case .claude: addClaude(row)
          case .grok: addGrok(row)
          case .kimi: addKimi(row)
          case .pi, .omp, .omo: addPi(row)
          default: break
          }
        }
      }
      filesRead += 1
    } catch {
      skipped += 1
    }
  }

  static func forEachRow(
    in url: URL, containing needle: String? = nil, _ body: (JSON) -> Void
  ) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let pattern = needle.map { Data($0.utf8) }
    let maximumLineBytes = 8 * 1024 * 1024
    var pending = Data()
    var droppingLargeLine = false
    func parse(_ line: Data) {
      guard !droppingLargeLine, line.count <= maximumLineBytes else { return }
      if let pattern, line.range(of: pattern) == nil { return }
      autoreleasepool {
        if let row = object(line) { body(row) }
      }
    }
    while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
      if Task.isCancelled { return }
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        if !droppingLargeLine {
          pending.append(chunk[start..<newline])
          parse(pending)
        }
        pending.removeAll(keepingCapacity: true)
        droppingLargeLine = false
        start = chunk.index(after: newline)
      }
      if !droppingLargeLine {
        pending.append(chunk[start...])
        if pending.count > maximumLineBytes {
          pending.removeAll()
          droppingLargeLine = true
        }
      }
    }
    if !pending.isEmpty { parse(pending) }
  }

  private mutating func addClaude(_ row: JSON) {
    guard row["type"] as? String == "assistant",
      let message = row["message"] as? JSON,
      let usage = message["usage"] as? JSON,
      let date = date(row["timestamp"]),
      let messageID = Self.string(message["id"]) ?? Self.string(row["uuid"])
    else { return }
    let requestID = Self.string(row["requestId"]) ?? ""
    add(
      .init(
        id: "\(messageID)|\(requestID)", date: date,
        tokens: Self.sum(
          usage, ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"])))
  }

  private mutating func readGemini(_ url: URL) throws {
    var byID: [String: CatUsageSample] = [:]
    var lastDate: Date?
    func absorb(_ row: JSON, fallback: Date?) {
      let rowDate = date(row["timestamp"])
      defer { if let rowDate { lastDate = rowDate } }
      guard let token = row["tokens"] as? JSON, let id = Self.string(row["id"]),
        let recordedAt = byID[id]?.date ?? rowDate ?? fallback
      else { return }
      let count = Self.sum(token, ["input", "output", "thoughts", "tool"])
      byID[id] = CatUsageSample(id: id, date: recordedAt, tokens: max(count, Self.count(token["total"])))
    }
    if url.pathExtension == "jsonl" {
      try Self.forEachRow(in: url) { row in
        absorb(row, fallback: lastDate)
      }
    } else {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      if let json = Self.object(data), let messages = json["messages"] as? [JSON] {
        let sessionDate = date(json["startTime"])
        for message in messages { absorb(message, fallback: sessionDate) }
      }
    }
    for sample in byID.values { add(sample) }
  }

  private static func isGrokSubagent(_ log: URL) -> Bool {
    let summary = log.deletingLastPathComponent().appendingPathComponent("summary.json")
    guard let data = try? Data(contentsOf: summary),
      let kind = object(data)?["session_kind"] as? String
    else { return false }
    return kind.hasPrefix("subagent")
  }

  private mutating func addGrok(_ row: JSON) {
    let notification = (row["params"] as? JSON) ?? row
    let meta = notification["_meta"] as? JSON
    guard meta?["isReplay"] as? Bool != true,
      let update = notification["update"] as? JSON,
      update["sessionUpdate"] as? String == "turn_completed",
      let usage = update["usage"] as? JSON,
      let id = Self.string(update["prompt_id"]),
      let date = date(meta?["agentTimestampMs"]) ?? date(row["timestamp"])
    else { return }
    func tokens(_ camel: String, _ snake: String) -> Int64 {
      Self.tokenCount(usage[camel]) ?? Self.tokenCount(usage[snake]) ?? 0
    }
    let cached = tokens("cachedReadTokens", "cached_read_tokens")
    let input = Self.tokenCount(usage["inputTokens"]) ?? (Self.count(usage["input_tokens"]) + cached)
    let output = tokens("outputTokens", "output_tokens")
    let amount = max(input + output, tokens("totalTokens", "total_tokens"))
    let partial = ["usageIsIncomplete", "usage_is_incomplete", "costIsPartial", "cost_is_partial"]
      .contains { usage[$0] as? Bool == true }
    let ticks = Self.number(usage["costUsdTicks"]) ?? Self.number(usage["cost_usd_ticks"])
    let cost = partial ? nil : ticks.flatMap { Self.cost($0 / 1e10) }
    add(.init(id: id, date: date, tokens: amount, costUSD: cost))
  }

  private mutating func addKimi(_ row: JSON) {
    guard row["type"] as? String == "usage.record", let usage = row["usage"] as? JSON,
      let millis = Self.number(row["time"]), let date = date(millis),
      [nil, "turn", "session"].contains(row["usageScope"] as? String)
    else { return }
    let parts = ["inputOther", "output", "inputCacheRead", "inputCacheCreation"].map { Self.count(usage[$0]) }
    let model = Self.string(row["model"]) ?? "kimi-code"
    let id =
      "\(Int64(millis))|\(model)|\(row["usageScope"] as? String ?? "-")|\(parts.map(String.init).joined(separator: "|"))"
    add(.init(id: id, date: date, tokens: parts.reduce(0, +)))
  }

  private mutating func addPi(_ row: JSON) {
    guard let type = Self.string(row["type"]), let sourceID = Self.string(row["id"]) else { return }
    let message: JSON
    switch type {
    case "message":
      guard let nested = row["message"] as? JSON,
        let role = nested["role"] as? String,
        role == "assistant" || (provider == .omo && role == "toolResult"),
        !["aborted", "error"].contains(nested["stopReason"] as? String ?? "")
      else { return }
      message = nested
    case "compaction", "branch_summary":
      message = row
    default:
      return
    }
    guard let usage = message["usage"] as? JSON,
      let date = date(message["timestamp"]) ?? date(row["timestamp"])
    else { return }
    let coarse = Self.count(usage["totalTokens"])
    var buckets = ["input", "output", "cacheWrite", "cacheRead"]
    if provider == .omo { buckets.append("cacheWrite1h") }
    let tokens = buckets.contains { Self.number(usage[$0]) != nil } ? Self.sum(usage, buckets) : coarse
    let cost = Self.cost((usage["cost"] as? JSON)?["total"])
    let id = "\(sourceID)|\(date.timeIntervalSince1970)"
    add(.init(id: id, date: date, tokens: tokens, costUSD: cost, costEstimated: cost != nil))
  }

  mutating func addOpenCode(_ row: JSON, fallbackID: String, v2Date: Date? = nil) {
    guard let usage = row["tokens"] as? JSON,
      let recordedAt = v2Date ?? date((row["time"] as? JSON)?["created"])
    else { return }
    if v2Date == nil {
      guard Self.string(row["modelID"]) != nil, Self.string(row["providerID"]) != nil else { return }
    } else {
      guard let model = row["model"] as? JSON, Self.string(model["id"]) != nil,
        Self.string(model["providerID"]) != nil
      else { return }
    }
    let cache = (usage["cache"] as? JSON) ?? [:]
    let tokens =
      Self.sum(usage, v2Date == nil ? ["input", "output"] : ["input", "output", "reasoning"])
      + Self.sum(cache, ["write", "read"])
    add(
      .init(
        id: Self.string(row["id"]) ?? fallbackID, date: recordedAt, tokens: max(tokens, Self.count(usage["total"])),
        costUSD: Self.cost(row["cost"]), costEstimated: true))
  }

  static func sum(_ usage: JSON, _ keys: [String]) -> Int64 {
    keys.reduce(0) { $0 + count(usage[$1]) }
  }

  static func cost(_ value: Any?) -> Double? {
    guard let amount = number(value), amount >= 0, amount <= 1e12 else { return nil }
    return amount
  }
}
