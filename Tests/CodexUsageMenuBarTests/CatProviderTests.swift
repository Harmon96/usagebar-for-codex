import Foundation
import SQLite3
import Testing

@testable import CodexUsageMenuBar

private enum Failure: Error { case assertion(String) }

struct CatProviderTests {
  @Test func scansLocalProviderFormatsAndKeepsStableIdentities() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let since = Date(timeIntervalSince1970: 1_790_000_000)
    let now = Date(timeIntervalSince1970: 1_805_000_000)
    let stamp = "2026-11-27T00:00:00Z"
    let sec = 1_795_737_600
    let ms = sec * 1000

    func check(_ provider: CatProvider, _ filename: String, tokens: Int64, estimated: Bool = false, cost: Double? = nil)
      async throws
    {
      let url = root.appendingPathComponent(filename)
      let data = await CatUsageProviders.scan(provider, roots: [url, url], since: since, now: now)
      guard data.samples.count == 1, let item = data.samples.first, tokens == item.tokens,
        item.estimated == estimated, item.costUSD == cost
      else {
        throw Failure.assertion(
          "\(provider.title) expected \(tokens), got \(data.samples.map(\.tokens)) (\(data.status ?? "-"))")
      }
      let warm = await CatUsageProviders.scan(provider, roots: [url], since: since, now: now)
      guard warm.samples.first?.id == item.id, warm.samples.first?.tokens == item.tokens else {
        throw Failure.assertion("warm mismatch: \(provider.title)")
      }
    }

    func file(_ filename: String, _ value: String) throws {
      try value.write(to: root.appendingPathComponent(filename), atomically: false, encoding: .utf8)
    }

    func database(_ filename: String, _ sql: String) throws {
      let url = root.appendingPathComponent(filename)
      var db: OpaquePointer?
      guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.assertion("open") }
      defer { sqlite3_close(db) }
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw Failure.assertion("sqlite: \(String(cString: sqlite3_errmsg(db)))")
      }
    }

    func json(_ raw: String) -> String { "'" + raw.replacingOccurrences(of: "'", with: "''") + "'" }
    try file(
      "claude.jsonl",
      """
      {"type":"assistant","timestamp":"\(stamp)","requestId":"r","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":30,"cache_read_input_tokens":15,"cache_creation_input_tokens":5}}}
      {"type":"assistant","timestamp":"\(stamp)","requestId":"r","message":{"id":"m","usage":{"input_tokens":10,"output_tokens":25,"cache_read_input_tokens":15,"cache_creation_input_tokens":5}}}
      """)
    try await check(.claude, "claude.jsonl", tokens: 60)
    try file(
      "claude.jsonl",
      """
      {"type":"assistant","timestamp":"\(stamp)","requestId":"r","message":{"id":"m","usage":{"input_tokens":100,"output_tokens":30}}}
      """)
    try await check(.claude, "claude.jsonl", tokens: 130)

    try file(
      "session-test.jsonl",
      """
      {"id":"m","type":"gemini","timestamp":"\(stamp)","tokens":{"input":100,"cached":60,"output":12,"thoughts":5}}
      {"id":"m","type":"message_update","tokens":{"input":100,"cached":60,"output":13,"thoughts":5}}
      """)
    try await check(.gemini, "session-test.jsonl", tokens: 118)
    let defaultGemini = await CatUsageProviders.scan(.gemini, roots: [root], since: since, now: now)
    let customGemini = await CatUsageProviders.scan(.gemini, roots: [], customRoots: [root], since: since, now: now)
    guard defaultGemini.samples.isEmpty, customGemini.samples.map(\.tokens) == [118] else {
      throw Failure.assertion("Gemini custom directory")
    }

    try file(
      "updates.jsonl",
      """
      {"timestamp":\(sec),"params":{"_meta":{"agentTimestampMs":\(ms)},"update":{"sessionUpdate":"turn_completed","prompt_id":"aaa","usage":{"inputTokens":50,"outputTokens":10,"cachedReadTokens":15,"costUsdTicks":10000000000}}}}
      """)
    try await check(.grok, "updates.jsonl", tokens: 60, cost: 1)
    try file(
      "updates.jsonl",
      """
      {"timestamp":\(sec),"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"mixed","usage":{"inputTokens":null,"input_tokens":6,"outputTokens":null,"output_tokens":3,"cachedReadTokens":null,"cached_read_tokens":4,"costUsdTicks":null,"cost_usd_ticks":5000000000}}}}
      """)
    try await check(.grok, "updates.jsonl", tokens: 13, cost: 0.5)
    try file("summary.json", #"{"session_kind":"subagent"}"#)
    let grokExcluded = await CatUsageProviders.scan(
      .grok, roots: [root.appendingPathComponent("updates.jsonl")], since: since, now: now)
    guard grokExcluded.samples.isEmpty else { throw Failure.assertion("Grok sidecar cache invalidation") }

    try file(
      "pi.jsonl",
      """
      {"id":"p","type":"message","timestamp":"\(stamp)","message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":4,"cacheWrite":3,"reasoning":12,"cost":{"total":0.25}}}}
      """)
    try await check(.pi, "pi.jsonl", tokens: 37, cost: 0.25)
    try await check(.omp, "pi.jsonl", tokens: 37, cost: 0.25)
    try file(
      "omo.jsonl",
      """
      {"id":"q","type":"message","timestamp":"\(stamp)","message":{"role":"toolResult","usage":{"input":10,"output":25,"cacheWrite1h":5}}}
      """)
    try await check(.omo, "omo.jsonl", tokens: 40)

    try file(
      "wire.jsonl",
      """
      {"type":"usage.record","time":\(ms),"usageScope":"turn","usage":{"inputOther":100,"output":12,"inputCacheRead":80,"inputCacheCreation":2}}
      """)
    try await check(.kimi, "wire.jsonl", tokens: 194)

    let open =
      #"{"id":"one","modelID":"a","providerID":"b","time":{"created":1795737600000},"tokens":{"input":6,"output":14,"cache":{"read":8,"write":2}},"cost":0.75}"#
    try database(
      "opencode.db",
      """
      CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT);
      INSERT INTO message VALUES ('one', \(ms), \(json(open)));
      """)
    try await check(.openCode, "opencode.db", tokens: 30, cost: 0.75)
    let extraOpenCode = root.appendingPathComponent("renamed-opencode-export", isDirectory: true)
    try FileManager.default.createDirectory(at: extraOpenCode, withIntermediateDirectories: true)
    try open.write(to: extraOpenCode.appendingPathComponent("msg_sample.json"), atomically: true, encoding: .utf8)
    let pickedOpenCode = await CatUsageProviders.scan(
      .openCode, roots: [], customRoots: [extraOpenCode], since: since, now: now)
    guard pickedOpenCode.samples.map(\.tokens) == [30] else {
      throw Failure.assertion("OpenCode custom directory")
    }

    try database(
      "hermes.db",
      """
      CREATE TABLE sessions (id TEXT, started_at REAL, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, actual_cost_usd REAL, estimated_cost_usd REAL);
      INSERT INTO sessions VALUES ('h', \(sec), 20, 30, 15, 5, 1, NULL, 0.4);
      """)
    try await check(.hermes, "hermes.db", tokens: 71, cost: 0.4)

    let tiny = #"{"input":10,"output":20,"cacheWrite":4,"cacheRead":6,"cost":{"total":0.5}}"#
    try database(
      "aside.db",
      """
      CREATE TABLE session_turns (id INTEGER, session_id TEXT, token_usage TEXT, started_at REAL, finished_at REAL, last_message_timestamp REAL);
      INSERT INTO session_turns VALUES (1, 'aside-session', \(json(tiny)), \(sec), \(sec), \(sec)),
                                        (2, 'old-session', \(json(tiny)), 1700000000, \(sec), \(sec));
      """)
    try await check(.aside, "aside.db", tokens: 40, cost: 0.5)

    try database(
      "copilot.db",
      """
      CREATE TABLE assistant_usage_events (id INTEGER, session_id TEXT, input_tokens INTEGER, output_tokens INTEGER, created_at TEXT);
      INSERT INTO assistant_usage_events VALUES (1, 'copilot-session', 40, 13, '2026-11-27 00:00:00.123');
      """)
    try await check(.copilot, "copilot.db", tokens: 53)
    let secondCopilot = root.appendingPathComponent("copilot-copy.db")
    try FileManager.default.copyItem(at: root.appendingPathComponent("copilot.db"), to: secondCopilot)
    let copilotCopies = await CatUsageProviders.scan(
      .copilot, roots: [root.appendingPathComponent("copilot.db"), secondCopilot], since: since, now: now)
    guard copilotCopies.samples.count == 1 else { throw Failure.assertion("Copilot copied database") }

    let bubble = #"{"createdAt":"2026-11-27T00:00:00Z","tokenCount":{"inputTokens":10,"outputTokens":50}}"#
    try database(
      "state.vscdb",
      """
      CREATE TABLE cursorDiskKV (key TEXT UNIQUE, value TEXT);
      INSERT INTO cursorDiskKV VALUES ('bubbleId:one', \(json(bubble)));
      """)
    try await check(.cursor, "state.vscdb", tokens: 60)

    let message =
      #"{"message_id":"one","metadata":{"metrics":{"input_tokens":4,"output_tokens":8,"cache_creation_tokens":3,"cache_read_tokens":5}}}"#
    try database(
      "devin.db",
      """
      CREATE TABLE message_nodes (row_id INTEGER, chat_message TEXT, session_id TEXT, created_at REAL);
      INSERT INTO message_nodes VALUES (1, \(json(message)), 's', \(sec)), (2, \(json(message)), 's', \(sec));
      """)
    try await check(.devin, "devin.db", tokens: 20)

    try file(
      "kiro.jsonl",
      """
      {"kind":"Prompt","data":{"meta":{"timestamp":"\(stamp)"},"content":"12345678"}}
      {"kind":"AssistantMessage","data":{"content":"1234"}}
      """)
    try await check(.kiro, "kiro.jsonl", tokens: 3, estimated: true)
    let kiro = """
      {"conversation_id":"x","history":[{"user":{"content":"12345678"},"assistant":{"content":"1234"},"request_metadata":{"request_start_timestamp_ms":\(ms),"response_size":4}}]}
      """
    try database(
      "kiro.db",
      """
      CREATE TABLE conversations (value TEXT);
      INSERT INTO conversations VALUES (\(json(kiro)));
      """)
    try await check(.kiro, "kiro.db", tokens: 3, estimated: true)

    func varint(_ value: UInt64) -> [UInt8] {
      var current = value
      var digits: [UInt8] = []
      while current >= 128 {
        digits.append(UInt8(current & 127) | 128)
        current >>= 7
      }
      return digits + [UInt8(current)]
    }
    func number(_ field: Int, _ value: UInt64) -> [UInt8] {
      varint(UInt64(field << 3)) + varint(value)
    }
    func nested(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
      varint(UInt64(field << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }
    func text(_ field: Int, _ value: String) -> [UInt8] { nested(field, Array(value.utf8)) }
    func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    let tokenFields = number(2, 10) + number(3, 20) + number(4, 3) + number(5, 13) + text(11, "response")
    let record = nested(1, nested(4, tokenFields)) + text(4, "execution")
    let step = nested(8, number(1, UInt64(sec))) + text(12, "execution")
    try database(
      "antigravity.db",
      """
      CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
      CREATE TABLE steps (idx INTEGER, metadata BLOB);
      INSERT INTO gen_metadata VALUES (1, X'\(hex(record))');
      INSERT INTO steps VALUES (1, X'\(hex(step))');
      """)
    try await check(.antigravity, "antigravity.db", tokens: 46)
    let timedRecord = nested(1, nested(4, tokenFields) + nested(9, nested(4, number(1, UInt64(sec)))))
    try database(
      "antigravity-v1.db",
      """
      CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
      INSERT INTO gen_metadata VALUES (1, X'\(hex(timedRecord))');
      """)
    try await check(.antigravity, "antigravity-v1.db", tokens: 46)
    try database("antigravity-v1.db", "CREATE TABLE steps (unexpected_column TEXT)")
    let partialScan = await CatUsageProviders.scan(
      .antigravity, roots: [root.appendingPathComponent("antigravity-v1.db")], since: since, now: now)
    guard partialScan.samples.isEmpty, partialScan.status?.contains("1개") == true else {
      throw Failure.assertion("Antigravity partial table read")
    }

  }
}
