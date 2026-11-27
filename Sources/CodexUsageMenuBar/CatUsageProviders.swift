import CoreFoundation
import Foundation

enum CatProvider: String, CaseIterable, Codable, Sendable, Identifiable {
  case codex, claude, gemini, antigravity, openCode, hermes, cursor, grok
  case copilot, kiro, pi, omp, omo, aside, kimi, devin

  var id: String { rawValue }

  var title: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .gemini: "Gemini CLI"
    case .antigravity: "Antigravity"
    case .openCode: "OpenCode"
    case .hermes: "Hermes Agent"
    case .cursor: "Cursor"
    case .grok: "Grok Build CLI"
    case .copilot: "Copilot CLI"
    case .kiro: "Kiro CLI"
    case .pi: "Pi Agent"
    case .omp: "omp"
    case .omo: "omo"
    case .aside: "Aside"
    case .kimi: "Kimi Code"
    case .devin: "Devin CLI"
    }
  }
}

struct CatUsageSample: Sendable {
  let id: String
  let date: Date
  let tokens: Int64
  let estimated: Bool
  let costUSD: Double?
  let costEstimated: Bool

  init(
    id: String, date: Date, tokens: Int64, estimated: Bool = false, costUSD: Double? = nil,
    costEstimated: Bool = false
  ) {
    self.id = id
    self.date = date
    self.tokens = tokens
    self.estimated = estimated
    self.costUSD = costUSD
    self.costEstimated = costEstimated
  }
}

struct CatUsageBatch: Sendable {
  let samples: [CatUsageSample]
  let status: String?
}

enum CatUsageProviders {
  static func defaultRoots(_ provider: CatProvider) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let environment = ProcessInfo.processInfo.environment
    func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    func override(_ key: String, suffix: String? = nil) -> [URL] {
      guard let value = environment[key], !value.isEmpty else { return [] }
      let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
      return [suffix.map { url.appendingPathComponent($0) } ?? url]
    }
    switch provider {
    case .codex:
      return [path(".codex")] + override("CODEX_HOME")
    case .claude:
      return [path(".claude/projects")] + override("CLAUDE_CONFIG_DIR", suffix: "projects")
    case .gemini:
      return [path(".gemini/tmp")] + override("GEMINI_CLI_HOME", suffix: ".gemini/tmp")
    case .antigravity:
      return ["antigravity", "antigravity-cli", "antigravity-ide"].map {
        path(".gemini/\($0)/conversations")
      }
    case .openCode:
      return [path(".local/share/opencode")] + override("OPENCODE_DATA_DIR")
        + override("XDG_DATA_HOME", suffix: "opencode")
    case .hermes:
      return [path(".hermes")] + override("HERMES_HOME")
    case .cursor:
      return ["Cursor", "Cursor Nightly"].map { path("Library/Application Support/\($0)/User/globalStorage") }
        + override("CURSOR_DATA_DIR")
    case .grok:
      return [path(".grok/sessions")] + override("GROK_HOME", suffix: "sessions")
    case .copilot:
      return [path(".copilot")] + override("COPILOT_HOME")
    case .kiro:
      return [path("Library/Application Support/kiro-cli"), path(".kiro/sessions")]
        + override("KIRO_CLI_HOME") + override("KIRO_HOME", suffix: "sessions")
    case .pi:
      return [path(".pi/agent/sessions")] + override("PI_CODING_AGENT_DIR", suffix: "sessions")
        + override("PI_CODING_AGENT_SESSION_DIR")
    case .omp:
      return [path(".omp/agent/sessions")] + override("OMP_CODING_AGENT_DIR", suffix: "sessions")
    case .omo:
      return [path(".omo/agent/sessions"), path(".senpi/agent/sessions")]
        + override("OMO_CODING_AGENT_DIR", suffix: "sessions") + override("SENPI_CODING_AGENT_DIR", suffix: "sessions")
    case .aside:
      return [path(".aside/u")]
    case .kimi:
      return [
        path(".kimi-code/sessions"),
        path("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"),
      ]
        + override("KIMI_CODE_HOME", suffix: "sessions")
    case .devin:
      return [path(".local/share/devin")] + override("XDG_DATA_HOME", suffix: "devin")
    }
  }

  static func scan(
    _ provider: CatProvider, roots: [URL], customRoots: [URL] = [], since: Date, now: Date
  ) async -> CatUsageBatch {
    guard provider != .codex else { return CatUsageBatch(samples: [], status: nil) }
    let task = Task.detached(priority: .utility) {
      var scan = CatProviderScan(provider: provider, since: since)
      scan.read(roots, custom: false)
      scan.read(customRoots, custom: true)
      let samples = scan.samples.values.filter { $0.date >= since && $0.date <= now }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
      var notes: [String] = []
      if scan.skipped > 0 { notes.append("일부 기록을 읽지 못했습니다. (\(scan.skipped)개)") }
      if scan.filesRead == 0 && scan.skipped == 0 { notes.append("읽을 수 있는 로컬 사용 기록을 찾지 못했습니다.") }
      switch provider {
      case .cursor: notes.append("로컬에 토큰 수가 남은 대화만 포함합니다.")
      case .kiro: notes.append("대화 바이트 길이로 토큰 수를 추정합니다.")
      case .hermes: notes.append("세션 시작일에 집계한 세션 합계입니다.")
      default: break
      }
      return CatUsageBatch(samples: samples, status: notes.isEmpty ? nil : notes.joined(separator: " "))
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

struct CatProviderScan {
  typealias JSON = [String: Any]

  let provider: CatProvider
  let since: Date
  var samples: [String: CatUsageSample] = [:]
  var filesRead = 0
  var skipped = 0
  private(set) var seen = Set<URL>()
  private let isoFractional = ISO8601DateFormatter()
  private let isoSeconds = ISO8601DateFormatter()

  init(provider: CatProvider, since: Date) {
    self.provider = provider
    self.since = since
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    isoSeconds.formatOptions = [.withInternetDateTime]
  }

  mutating func read(_ roots: [URL], custom: Bool) {
    for root in roots {
      let url = root.standardizedFileURL.resolvingSymlinksInPath()
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
      if !directory.boolValue {
        readIfMatching(url, explicit: true, custom: custom)
        continue
      }

      let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ]
      var failedEnumeration = false
      guard
        let enumerator = FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, _ in
            failedEnumeration = true
            return true
          }
        )
      else {
        skipped += 1
        continue
      }
      for case let entry as URL in enumerator {
        if Task.isCancelled { return }
        if skipDirectory(entry) {
          enumerator.skipDescendants()
        } else if (try? entry.resourceValues(forKeys: keys).isRegularFile) == true {
          readIfMatching(entry, explicit: false, custom: custom)
        }
      }
      if failedEnumeration { skipped += 1 }
    }
  }

  private func skipDirectory(_ url: URL) -> Bool {
    if provider == .openCode {
      return ["node_modules", "bin", "cache", "log", "project", "session", "part"].contains(url.lastPathComponent)
    }
    return provider == .omp && url.lastPathComponent == "bridge"
  }

  private mutating func readIfMatching(_ url: URL, explicit: Bool, custom: Bool) {
    let name = url.lastPathComponent
    let ext = url.pathExtension.lowercased()
    if ["auth.json", "credentials.json", "secrets.json"].contains(name.lowercased()) { return }
    let path = url.pathComponents
    let log: Bool
    let database: Bool
    switch provider {
    case .claude, .pi, .omp, .omo:
      log = ext == "jsonl"
      database = false
    case .gemini:
      log =
        ["json", "jsonl"].contains(ext)
        && (explicit || (name.hasPrefix("session-") && (custom || path.contains("chats"))))
      database = false
    case .grok:
      log = name == "updates.jsonl"
      database = false
    case .kimi:
      log = name == "wire.jsonl"
      database = false
    case .openCode:
      log = ext == "json" && (explicit || path.contains("message") || (custom && name.hasPrefix("msg_")))
      database = ext == "db" && (explicit || name == "opencode.db" || name.hasPrefix("opencode-"))
    case .kiro:
      log =
        ext == "jsonl"
        && (explicit || name == "messages.jsonl" || url.deletingLastPathComponent().lastPathComponent == "cli")
      database = name == "data.sqlite3" || (explicit && ["db", "sqlite3"].contains(ext))
    case .antigravity:
      log = false
      database = ext == "db"
    case .aside, .hermes:
      log = false
      database = name == "state.db" || (explicit && ext == "db")
    case .cursor:
      log = false
      database = ext == "vscdb"
    case .copilot:
      log = false
      database = name == "session-store.db" || (explicit && ext == "db")
    case .devin:
      log = false
      database = name == "sessions.db" || (explicit && ext == "db")
    case .codex:
      return
    }
    guard log || database, seen.insert(url.standardizedFileURL.resolvingSymlinksInPath()).inserted else { return }

    guard !Task.isCancelled else { return }
    let signature = CatProviderFileSignature(url, provider: provider, database: database)
    if let modified = signature.lastModified, modified < since { return }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      skipped += 1
      return
    }

    let key = "\(provider.rawValue)|\(since.timeIntervalSinceReferenceDate)|\(url.path)"
    let cache = CatProviderFileCache.shared
    if let previous = cache.value(for: key), previous.signature == signature {
      filesRead += 1
      for sample in previous.samples { add(sample) }
      return
    }

    var source = CatProviderScan(provider: provider, since: since)
    if database {
      source.readDatabase(url)
    } else {
      source.readLog(url)
    }
    guard !Task.isCancelled else { return }
    filesRead += source.filesRead
    skipped += source.skipped
    for sample in source.samples.values { add(sample) }
    if source.filesRead > 0, source.skipped == 0, signature.lastModified != nil {
      cache.store(Array(source.samples.values), signature: signature, for: key)
    }
  }

  func date(_ value: Any?) -> Date? {
    if let raw = value as? String {
      if let parsed = isoFractional.date(from: raw) ?? isoSeconds.date(from: raw) { return parsed }
      if raw.count >= 19, let separator = raw.index(raw.startIndex, offsetBy: 10, limitedBy: raw.endIndex),
        raw[separator] == " " || raw[separator] == "T"
      {
        var iso = raw
        iso.replaceSubrange(separator...separator, with: "T")
        let time = iso.dropFirst(11)
        if !time.contains("Z") && !time.contains("+") && !time.contains("-") { iso += "Z" }
        if let parsed = isoFractional.date(from: iso) ?? isoSeconds.date(from: iso) { return parsed }
      }
    }
    guard let epoch = Self.number(value), epoch > 0, epoch < 100_000_000_000_000 else { return nil }
    return Date(timeIntervalSince1970: epoch >= 100_000_000_000 ? epoch / 1_000 : epoch)
  }

  static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
      return number.doubleValue
    }
    if let text = value as? String, let number = Double(text), number.isFinite { return number }
    return nil
  }

  static func count(_ value: Any?) -> Int64 { tokenCount(value) ?? 0 }

  static func tokenCount(_ value: Any?) -> Int64? {
    guard let number = number(value), number >= 0, number <= 1_000_000_000_000, number.rounded(.towardZero) == number
    else { return nil }
    return Int64(number)
  }

  static func string(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }

  static func object(_ data: Data) -> JSON? {
    (try? JSONSerialization.jsonObject(with: data)) as? JSON
  }

  mutating func add(_ sample: CatUsageSample) {
    guard sample.date >= since, !sample.id.isEmpty, sample.tokens > 0 else { return }
    if let old = samples[sample.id], old.tokens >= sample.tokens { return }
    samples[sample.id] = sample
  }
}
