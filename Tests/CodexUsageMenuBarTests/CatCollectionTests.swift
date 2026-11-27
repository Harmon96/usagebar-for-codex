import Foundation
import Testing

@testable import CodexUsageMenuBar

@MainActor
struct CatCollectionTests {
  @Test func growthCarriesOverflowAndRegistersEachDiscovery() throws {
    var state = CatCollectionState()
    var random = SystemRandomNumberGenerator()
    let now = Date()
    state.nextBox = .rare
    state.grow(500_000, at: now, using: &random)

    let discovered = try #require(state.active)
    let kind = try #require(CatCatalog.kind(discovered.kindID))
    #expect(kind.rarity == .rare || kind.rarity == .special)
    #expect(state.phase == .kitten)
    #expect(state.pets.count == 1)

    state.grow(7_250_000, at: now, using: &random)
    #expect(state.phase == .box)
    #expect(state.progress == 250_000)
    #expect(state.pets.first?.settledAt == now)
    #expect(state.activeID == nil)
    #expect(CatCatalog.all.count == 102)
    #expect(Set(CatCatalog.all.map(\.id)).count == 102)
  }

  @Test func repeatedUsageAndLimitSnapshotsCreditOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    let path = folder.appending(path: "collection.sqlite")
    let store = try seededStore(in: folder, at: now)
    let batch = CatUsageBatch(
      samples: [
        .init(id: "old", date: now.addingTimeInterval(-1), tokens: 5_000_000),
        .init(id: "one", date: now, tokens: 1_000_000, costUSD: 0.25),
        .init(id: "two", date: now, tokens: 250_000, estimated: true, costUSD: 1, costEstimated: true),
      ], status: nil)
    store.apply([.codex: batch], now: now)
    store.apply([.codex: batch], now: now)
    #expect(store.state.coins == 1)
    #expect(store.state.progress == 750_000)
    #expect(store.state.daily.first?.tokens == 1_250_000)
    #expect(store.state.daily.first?.recordedCostUSD == 0.25)
    #expect(store.state.daily.first?.estimatedCostUSD == 1)

    let reset = now.addingTimeInterval(3_600)
    store.observeLimit(.codex, minutes: 300, used: 100, resetsAt: reset, receivedAt: now)
    store.observeLimit(.codex, minutes: 300, used: 100, resetsAt: reset, receivedAt: now)
    store.observeLimit(.codex, minutes: 10080, used: 100, resetsAt: reset, receivedAt: now)
    #expect(store.state.inventory[CatItem.treat.rawValue] == 4)
    let reloaded = CatCollectionStore(directory: folder)
    reloaded.apply([.codex: batch], now: now)
    #expect(reloaded.state.coins == 1)
    #expect(reloaded.state.progress == 750_000)
    let reopened = try CatDatabase(url: path, create: false)
    #expect(try reopened.load().daily.first?.estimatedTokens == 250_000)
  }

  @Test func backupPreservesLedgerAndSaveTransactionRollsBack() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let disk = try CatDatabase(url: folder.appending(path: "collection.sqlite"), create: true)

    do {
      try disk.transaction {
        _ = try disk.credit(id: "event", total: 900)
        throw CatSaveError.invalidSave
      }
    } catch CatSaveError.invalidSave {
      // The usage marker and state must both roll back.
    }

    try disk.transaction {
      #expect(try disk.credit(id: "event", total: 900) == 900)
      try disk.save(CatCollectionState())
    }
    let backupURL = folder.appending(path: "backup.sqlite")
    try disk.export(to: backupURL)
    let backup = try CatDatabase(url: backupURL, create: false)
    #expect(try backup.load().phase == .box)
    #expect(try backup.credit(id: "event", total: 900) == 0)
    #expect(try backup.credit(id: "event", total: 950) == 50)
  }

  @Test func shopFeedsCurrentCatAndRestoreKeepsNameAndPin() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    let store = try seededStore(in: folder, at: now)
    let batches: [CatProvider: CatUsageBatch] = [
      .codex: .init(samples: [.init(id: "large-turn", date: now, tokens: 8_000_000)], status: nil)
    ]
    store.apply(batches, now: now)
    let current = try #require(store.state.active)
    #expect(store.state.pets.count == 2)
    #expect(store.state.coins == 8)

    store.buy(.treat, count: 2)
    #expect(store.state.coins == 4)
    store.use(.treat, count: 2)
    #expect(store.state.inventory[CatItem.treat.rawValue] == 0)
    #expect(store.state.progress == 1_000_000)
    store.setDifficulty(50)
    #expect(store.state.progress == 500_000)
    store.rename(current.id, to: "우유")
    store.pin(current.id)
    store.setEnabled(false)

    let backup = folder.appending(path: "named.sqlite")
    store.export(to: backup)
    store.rename(current.id, to: "이름 변경")
    store.pin(nil)
    store.restore(from: backup)
    #expect(store.error == nil)
    #expect(store.displayedCat?.name == "우유")
    #expect(store.state.pinnedID == current.id)
    #expect(store.state.coins == 4)
  }

  @Test func staleStoreCannotSpendTheSameTreatTwice() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    let store = try seededStore(in: folder, at: now)
    store.apply([.codex: .init(samples: [.init(id: "turn", date: now, tokens: 2_000_000)], status: nil)], now: now)
    store.buy(.treat, count: 1)
    let second = CatCollectionStore(directory: folder)
    store.use(.treat, count: 1)
    second.use(.treat, count: 1)
    #expect(second.state.phase == .adult)
    #expect(second.state.progress == 0)
    #expect(second.state.inventory[CatItem.treat.rawValue] == 0)
  }

  @Test func retiredAdultRemainsAdultAfterReopeningTheCollection() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    let store = try seededStore(in: folder, at: now)
    store.apply([.codex: .init(samples: [.init(id: "turn", date: now, tokens: 5_000_000)], status: nil)], now: now)
    let cat = try #require(store.state.active)
    #expect(store.state.phase == .adult)
    store.pin(cat.id)
    store.buy(.normalBox, count: 1)
    store.use(.normalBox, count: 1)
    let reopened = CatCollectionStore(directory: folder)
    #expect(reopened.state.phase == .box)
    #expect(reopened.displayedCat?.id == cat.id)
    #expect(reopened.displayedCat?.settledAt == nil)
    #expect(reopened.displayedCatIsAdult)
  }

  @Test func cumulativeCostsUseTheLatestAmountAndProvenance() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date()
    let store = try seededStore(in: folder, at: now)
    for (tokens, cost, estimated) in [(100, 0.1, true), (200, 0.25, true), (200, 0.3, false)] {
      let sample = CatUsageSample(
        id: "session", date: now, tokens: Int64(tokens), costUSD: cost, costEstimated: estimated)
      store.apply([.codex: .init(samples: [sample], status: nil)], now: now)
    }
    let day = try #require(store.state.daily.first)
    #expect(day.tokens == 200)
    #expect(day.recordedCostUSD == 0.3)
    #expect(abs(day.estimatedCostUSD ?? 0) < 0.00001)
  }

  private func seededStore(in folder: URL, at date: Date) throws -> CatCollectionStore {
    let disk = try CatDatabase(url: folder.appending(path: "collection.sqlite"), create: true)
    var state = CatCollectionState()
    state.enabled = true
    state.startedAt = date
    state.providerStart[CatProvider.codex.rawValue] = date
    try disk.save(state)
    return CatCollectionStore(directory: folder)
  }
}
