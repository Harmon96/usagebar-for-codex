import Combine
import CryptoKit
import Foundation

enum CatPhase: String, Codable, Sendable {
  case box, kitten, adult
}

enum CatDisplay: String, CaseIterable, Codable, Identifiable {
  case original, catAndPercentage, catOnly
  var id: Self { self }
}

enum CatItem: String, CaseIterable, Codable, Identifiable {
  case treat, toy, charm, normalBox, uncommonBox, rareBox

  var id: Self { self }

  var title: String {
    switch self {
    case .treat: "간식"
    case .toy: "장난감"
    case .charm: "반짝 부적"
    case .normalBox: "일반 상자"
    case .uncommonBox: "고급 상자"
    case .rareBox: "희귀 상자"
    }
  }

  func price(percent: Int) -> Int64 {
    let base: Int
    switch self {
    case .treat: base = 2
    case .toy: base = 5
    case .charm: base = 20
    case .normalBox: base = 5
    case .uncommonBox: base = 12
    case .rareBox: base = 25
    }
    return Int64(max(1, (base * percent + 99) / 100))
  }

  var boxGrade: CatRarity? {
    switch self {
    case .normalBox: .common
    case .uncommonBox: .uncommon
    case .rareBox: .rare
    default: nil
    }
  }
}

struct CatPet: Identifiable, Codable, Sendable {
  let id: UUID
  let kindID: String
  let coat: Int
  let shiny: Bool
  var name: String
  var personality: String
  let discoveredAt: Date
  var settledAt: Date?
  var reachedAdult: Bool?

  var isAdult: Bool { reachedAdult == true || settledAt != nil }
}

struct CatUsageDay: Identifiable, Codable, Sendable {
  let date: Date
  let provider: CatProvider
  var tokens: Int64
  var estimatedTokens: Int64
  var recordedCostUSD: Double?
  var estimatedCostUSD: Double?

  var costUSD: Double? {
    guard recordedCostUSD != nil || estimatedCostUSD != nil else { return nil }
    return (recordedCostUSD ?? 0) + (estimatedCostUSD ?? 0)
  }

  var costEstimated: Bool { estimatedCostUSD != nil }

  var id: String { provider.rawValue + ":" + String(date.timeIntervalSince1970) }
}

private let personalities = ["호기심 많음", "장난꾸러기", "느긋함", "수줍음", "새침함", "사교적"]

struct CatCollectionState: Codable {
  var version = 1
  var enabled = false
  var phase = CatPhase.box
  var progress: Int64 = 0
  var activeID: UUID?
  var pinnedID: UUID?
  var pets: [CatPet] = []
  var coins: Int64 = 0
  var coinRemainder: Int64 = 0
  var inventory: [String: Int] = [:]
  var shinyCharm = false
  var providers: Set<CatProvider> = [.codex]
  var roots: [String: [String]] = [:]
  var providerStart: [String: Date] = [:]
  var statuses: [String: String] = [:]
  var daily: [CatUsageDay] = []
  var difficulty = 100
  var prices = 100
  var display = CatDisplay.catAndPercentage
  var nextBox = CatRarity.common
  var startedAt: Date?
  var lastScan: Date?

  var target: Int64 { target(for: phase) }
  var active: CatPet? { pets.first { $0.id == activeID } }

  func target(for phase: CatPhase) -> Int64 {
    let base: Int64
    switch phase {
    case .box: base = 500_000
    case .kitten: base = 2_000_000
    case .adult: base = 5_000_000
    }
    return base * Int64(difficulty) / 100
  }

  mutating func grow<R: RandomNumberGenerator>(
    _ tokens: Int64, at now: Date, carryAfterSettlement: Bool = true, using random: inout R
  ) {
    var unspent = tokens
    while unspent > 0 {
      let consumed = min(unspent, target - progress)
      progress += consumed
      unspent -= consumed
      guard progress == target else { break }
      progress = 0
      switch phase {
      case .box:
        meet(at: now, using: &random)
      case .kitten:
        if let index = pets.firstIndex(where: { $0.id == activeID }) {
          pets[index].reachedAdult = true
        }
        phase = .adult
      case .adult:
        if let index = pets.firstIndex(where: { $0.id == activeID }) {
          pets[index].settledAt = now
        }
        activeID = nil
        phase = .box
        if !carryAfterSettlement { return }
      }
    }
  }

  private mutating func meet<R: RandomNumberGenerator>(at now: Date, using random: inout R) {
    let eligible = zip(CatRarity.allCases, [55, 36, 8, 1]).filter { rarity, _ in
      rarity.rawValue >= nextBox.rawValue && CatCatalog.all.contains { $0.rarity == rarity }
    }
    let weightSum = eligible.reduce(0) { $0 + $1.1 }
    guard weightSum > 0 else { return }
    var roll = Int.random(in: 0..<weightSum, using: &random)
    var grade = nextBox
    for (rarity, weight) in eligible {
      grade = rarity
      if roll < weight { break }
      roll -= weight
    }
    let kinds = CatCatalog.all.filter { $0.rarity == grade }
    let seen = Set(pets.map(\.kindID))
    let unseen = kinds.filter { !seen.contains($0.id) }
    guard let kind = (unseen.isEmpty ? kinds : unseen).randomElement(using: &random) else { return }
    let pet = CatPet(
      id: UUID(), kindID: kind.id, coat: Int.random(in: kind.coats.indices, using: &random),
      shiny: Int.random(in: 0..<100, using: &random) < (shinyCharm ? 3 : 1),
      name: kind.name, personality: personalities.randomElement(using: &random) ?? personalities[0],
      discoveredAt: now, settledAt: nil
    )
    pets.append(pet)
    activeID = pet.id
    phase = .kitten
    nextBox = .common
  }

  func validate() throws {
    guard version == 1, [50, 100, 200].contains(difficulty), [50, 100, 200].contains(prices),
      coins >= 0, (0..<1_000_000).contains(coinRemainder),
      (0..<target).contains(progress),
      inventory.values.allSatisfy({ (0...1_000_000).contains($0) }),
      Set(pets.map(\.id)).count == pets.count, Set(daily.map(\.id)).count == daily.count,
      !enabled || (startedAt != nil && providers.allSatisfy({ providerStart[$0.rawValue] != nil })),
      pinnedID == nil || pets.contains(where: { $0.id == pinnedID }),
      daily.allSatisfy({ $0.tokens >= 0 && (0...$0.tokens).contains($0.estimatedTokens) }),
      (phase == .box && activeID == nil) || (phase != .box && active != nil),
      pets.allSatisfy({ pet in CatCatalog.kind(pet.kindID)?.coats.indices.contains(pet.coat) == true })
    else { throw CatSaveError.invalidSave }
  }

  private enum CodingKeys: String, CodingKey {
    case version, enabled, phase, progress, activeID, pinnedID, pets, coins, coinRemainder, inventory, shinyCharm
    case providers, roots, providerStart, statuses, daily, difficulty, prices, display, nextBox, startedAt, lastScan
  }
}

@MainActor
final class CatCollectionStore: ObservableObject {
  @Published private(set) var state = CatCollectionState()
  @Published private(set) var scanning = false
  @Published private(set) var error: String?

  private let directory: URL
  private var database: CatDatabase?
  private var scanTask: Task<Void, Never>?
  private var generation = 0
  private var lastAttempt: Date?
  private var pendingLimits: [(CatProvider, Int, Date, Date)] = []

  var enabled: Bool { state.enabled }

  var displayedCat: CatPet? {
    if let pinned = state.pets.first(where: { $0.id == state.pinnedID }) { return pinned }
    return state.active
  }

  var displayedCatIsAdult: Bool {
    guard let cat = displayedCat else { return false }
    return cat.isAdult || (cat.id == state.activeID && state.phase == .adult)
  }

  init(
    directory: URL = .applicationSupportDirectory.appending(
      path: "app.usagebar.menubar/cats", directoryHint: .isDirectory)
  ) {
    self.directory = directory
    let active = directory.appending(path: "collection.sqlite")
    guard FileManager.default.fileExists(atPath: active.path) else { return }
    do {
      let stored = try CatDatabase(url: active, create: false)
      state = try stored.load()
      database = stored
    } catch {
      recoverNewestBackup()
    }
  }

  func setEnabled(_ value: Bool) {
    guard state.enabled != value else { return }
    if update({ draft in
      draft.enabled = value
      if value {
        let date = Date()
        if draft.startedAt == nil {
          draft.startedAt = date
          if UserDefaults.standard.bool(forKey: claudeUsageEnabledPreferenceKey) {
            draft.providers.insert(.claude)
          }
        }
        for provider in draft.providers {
          draft.providerStart[provider.rawValue] = date
        }
      }
    }) {
      resetScan()
      if value { refresh(force: true) }
    }
  }

  func setProvider(_ provider: CatProvider, _ enabled: Bool) {
    guard state.providers.contains(provider) != enabled else { return }
    if update({ draft in
      if enabled {
        draft.providers.insert(provider)
        draft.providerStart[provider.rawValue] = Date()
      } else {
        draft.providers.remove(provider)
        draft.statuses.removeValue(forKey: provider.rawValue)
      }
    }) {
      resetScan()
      refresh(force: true)
    }
  }

  func addRoot(_ url: URL, for provider: CatProvider) {
    let path = url.standardizedFileURL.path
    if update({ draft in
      if !draft.roots[provider.rawValue, default: []].contains(path) {
        draft.roots[provider.rawValue, default: []].append(path)
      }
    }) {
      resetScan()
      refresh(force: true)
    }
  }

  func removeRoot(_ path: String, for provider: CatProvider) {
    if update({ $0.roots[provider.rawValue]?.removeAll { $0 == path } }) {
      resetScan()
      refresh(force: true)
    }
  }

  func pin(_ id: UUID?) {
    update { draft in
      guard id == nil || draft.pets.contains(where: { $0.id == id }) else { return }
      draft.pinnedID = id
    }
  }

  func rename(_ id: UUID, to name: String) {
    let text = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(28))
    guard !text.isEmpty else { return }
    update { draft in
      guard let index = draft.pets.firstIndex(where: { $0.id == id }) else { return }
      draft.pets[index].name = text
    }
  }

  func setDisplay(_ value: CatDisplay) { update { $0.display = value } }

  func setDifficulty(_ value: Int) {
    guard [50, 100, 200].contains(value), value != state.difficulty else { return }
    update {
      let previousTarget = $0.target
      $0.difficulty = value
      $0.progress = $0.progress * $0.target / previousTarget
    }
  }

  func setPrices(_ value: Int) {
    guard [50, 100, 200].contains(value) else { return }
    update { $0.prices = value }
  }

  func buy(_ item: CatItem, count: Int) {
    guard (1...99).contains(count) else { return }
    update { draft in
      let owned = draft.inventory[item.rawValue, default: 0]
      if item == .charm && (count != 1 || owned > 0 || draft.shinyCharm) { return }
      let cost = item.price(percent: draft.prices) * Int64(count)
      guard draft.coins >= cost, owned + count <= 1_000_000 else { return }
      draft.coins -= cost
      draft.inventory[item.rawValue] = owned + count
    }
  }

  func use(_ item: CatItem, count: Int) {
    guard count > 0, item == .treat || count == 1 else { return }
    update { draft in
      let owned = draft.inventory[item.rawValue, default: 0]
      guard owned >= count else { return }
      var spent = count
      if let grade = item.boxGrade {
        if draft.phase == .adult, let index = draft.pets.firstIndex(where: { $0.id == draft.activeID }) {
          draft.pets[index].reachedAdult = true
        }
        draft.phase = .box
        draft.progress = 0
        draft.activeID = nil
        draft.nextBox = grade
      } else {
        switch item {
        case .treat:
          guard draft.phase != .box else { return }
          let remaining = draft.target - draft.progress + (draft.phase == .kitten ? draft.target(for: .adult) : 0)
          spent = min(count, Int((remaining + 499_999) / 500_000))
          var random = SystemRandomNumberGenerator()
          draft.grow(Int64(spent) * 500_000, at: .now, carryAfterSettlement: false, using: &random)
        case .charm:
          guard !draft.shinyCharm else { return }
          draft.shinyCharm = true
        case .toy:
          guard let index = draft.pets.firstIndex(where: { $0.id == draft.activeID }),
            let trait = personalities.filter({ $0 != draft.pets[index].personality }).randomElement()
          else { return }
          draft.pets[index].personality = trait
        default: return
        }
      }
      draft.inventory[item.rawValue] = owned - spent
    }
  }

  func observeLimit(_ provider: CatProvider, minutes: Int, used: Double, resetsAt: Date, receivedAt: Date) {
    guard enabled, state.providers.contains(provider),
      let started = state.providerStart[provider.rawValue], receivedAt >= started,
      resetsAt > .now, used >= 100, minutes == 300 || minutes == 10080
    else { return }
    let entry = (provider, minutes, resetsAt, receivedAt)
    pendingLimits.append(entry)
    applyLimits()
  }

  private func applyLimits() {
    guard !pendingLimits.isEmpty else { return }
    let limits = pendingLimits
    if updateLedger({ draft, disk in
      for (provider, minutes, reset, _) in limits {
        let id = "limit:\(provider.rawValue):\(minutes):\(Int64(reset.timeIntervalSince1970))"
        if try disk.credit(id: id, total: 1) == 1 {
          draft.inventory[CatItem.treat.rawValue, default: 0] += minutes == 300 ? 1 : 3
        }
      }
    }) {
      pendingLimits.removeAll()
    }
  }

  func refresh(force: Bool = false) {
    guard enabled, !scanning, state.startedAt != nil else { return }
    let now = Date()
    guard force || lastAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return }
    lastAttempt = now
    let offsets = state.providerStart
    let customRoots = state.roots
    let providers = state.providers
    let revision = generation
    scanning = true
    scanTask = Task { [weak self] in
      let batches = await withTaskGroup(of: (CatProvider, CatUsageBatch).self) { group in
        for provider in providers {
          guard let since = offsets[provider.rawValue] else { continue }
          let extra = (customRoots[provider.rawValue] ?? []).map { URL(fileURLWithPath: $0) }
          group.addTask {
            if provider == .codex {
              return (provider, await UsageAnalyticsLoader.loadForCats(extra: extra, since: since, now: now))
            }
            return (
              provider,
              await CatUsageProviders.scan(
                provider, roots: CatUsageProviders.defaultRoots(provider), customRoots: extra, since: since, now: now)
            )
          }
        }
        var results: [CatProvider: CatUsageBatch] = [:]
        for await (provider, batch) in group { results[provider] = batch }
        return results
      }
      guard let self, !Task.isCancelled, self.generation == revision else { return }
      self.scanning = false
      self.scanTask = nil
      self.apply(batches, now: now)
      self.applyLimits()
    }
  }

  private func resetScan() {
    generation += 1
    scanning = false
    scanTask?.cancel()
    scanTask = nil
    lastAttempt = nil
    pendingLimits.removeAll()
  }

  func apply(_ batches: [CatProvider: CatUsageBatch], now: Date) {
    updateLedger { draft, disk in
      guard draft.enabled else { return }
      let calendar = Calendar.current
      let cutoff = calendar.date(from: DateComponents(year: calendar.component(.year, from: now) - 1)) ?? .distantPast
      var daily = Dictionary(uniqueKeysWithValues: draft.daily.filter { $0.date >= cutoff }.map { ($0.id, $0) })
      var growth: Int64 = 0
      for provider in CatProvider.allCases {
        guard draft.providers.contains(provider), let batch = batches[provider],
          let started = draft.providerStart[provider.rawValue]
        else { continue }
        draft.statuses[provider.rawValue] = batch.status
        for sample in batch.samples where sample.date >= started && sample.date <= now {
          guard (1...100_000_000_000).contains(sample.tokens), !sample.id.isEmpty else { continue }
          let hash = SHA256.hash(data: Data(sample.id.utf8)).description
          let credit = try disk.creditUsage(id: provider.rawValue + ":" + hash, sample: sample)
          guard credit.tokens > 0 || credit.recorded != nil || credit.estimated != nil else { continue }
          growth += credit.tokens
          let day = calendar.startOfDay(for: sample.date)
          guard day >= cutoff else { continue }
          let entry = CatUsageDay(date: day, provider: provider, tokens: 0, estimatedTokens: 0)
          var totals = daily[entry.id] ?? entry
          totals.tokens += credit.tokens
          if sample.estimated { totals.estimatedTokens += credit.tokens }
          if let recorded = credit.recorded {
            totals.recordedCostUSD = max(0, (totals.recordedCostUSD ?? 0) + recorded)
          }
          if let estimated = credit.estimated {
            totals.estimatedCostUSD = max(0, (totals.estimatedCostUSD ?? 0) + estimated)
          }
          daily[entry.id] = totals
        }
      }
      draft.daily = daily.values.sorted {
        $0.date == $1.date ? $0.provider.rawValue < $1.provider.rawValue : $0.date < $1.date
      }
      let spend = draft.coinRemainder + growth
      draft.coins += spend / 1_000_000
      draft.coinRemainder = spend % 1_000_000
      var random = SystemRandomNumberGenerator()
      draft.grow(growth, at: now, using: &random)
      draft.lastScan = now
    }
    if error == nil { autoBackupIfNeeded(at: now) }
  }

  @discardableResult
  private func update(_ change: (inout CatCollectionState) throws -> Void) -> Bool {
    updateLedger { draft, _ in try change(&draft) }
  }

  @discardableResult
  private func updateLedger(_ change: (inout CatCollectionState, CatDatabase) throws -> Void) -> Bool {
    do {
      let disk = try prepareDatabase()
      var draft = state
      try disk.transaction {
        draft = try disk.currentState() ?? draft
        try change(&draft, disk)
        try draft.validate()
        try disk.save(draft)
      }
      state = draft
      error = nil
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  private func prepareDatabase() throws -> CatDatabase {
    if let database { return database }
    let location = directory.appending(path: "collection.sqlite")
    guard !FileManager.default.fileExists(atPath: location.path) else { throw CatSaveError.invalidSave }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let disk = try CatDatabase(url: location, create: true)
    database = disk
    return disk
  }

  private var backupDirectory: URL { directory.appending(path: "Backups", directoryHint: .isDirectory) }

  private func autoBackupIfNeeded(at date: Date) {
    let stamp = date.formatted(.iso8601.year().month().day())
    let destination = backupDirectory.appending(path: "daily-\(stamp).sqlite")
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    saveBackup(to: destination)
    let backups = backupFiles().filter { $0.lastPathComponent.hasPrefix("daily-") }
    for old in backups.dropFirst(7) { try? FileManager.default.removeItem(at: old) }
  }

  func backup() {
    saveBackup(to: backupDirectory.appending(path: "manual-\(UUID().uuidString).sqlite"))
  }

  func export(to url: URL) {
    guard url.standardizedFileURL != directory.appending(path: "collection.sqlite").standardizedFileURL else { return }
    saveBackup(to: url)
  }

  private func saveBackup(to url: URL) {
    do {
      guard let database else { return }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try database.export(to: url)
    } catch {
      self.error = error.localizedDescription
    }
  }

  func restore(from url: URL) {
    do {
      let destination = directory.appending(path: "collection.sqlite")
      guard url.standardizedFileURL != destination.standardizedFileURL else { return }
      let files = FileManager.default
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      let staged = directory.appending(path: ".restore-\(UUID().uuidString).sqlite")
      defer { try? files.removeItem(at: staged) }
      let incoming = try CatDatabase(url: url, create: false, readOnly: true)
      try incoming.export(to: staged)
      let restored = try CatDatabase(url: staged, create: false, readOnly: true).load()
      if let database {
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try database.export(to: backupDirectory.appending(path: "before-restore-\(UUID().uuidString).sqlite"))
      }
      if files.fileExists(atPath: destination.path) {
        _ = try files.replaceItemAt(destination, withItemAt: staged)
      } else {
        try files.moveItem(at: staged, to: destination)
      }
      database = try CatDatabase(url: destination, create: false)
      state = restored
      error = nil
      resetScan()
      refresh(force: true)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func backupFiles() -> [URL] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.filter { $0.pathExtension == "sqlite" }.sorted {
      let first =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      let second =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      return first > second
    }
  }

  private func recoverNewestBackup() {
    for file in backupFiles() {
      restore(from: file)
      if database != nil { return }
    }
    error = CatSaveError.invalidSave.localizedDescription
  }
}
