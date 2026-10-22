import Foundation
import Testing

@testable import CodexUsageMenuBar

@Suite("Usage window presentation")
struct UsageWindowPresentationTests {
  @Test("Titles identify the actual selected window")
  func titlesReflectDuration() {
    let weekly = UsageWindowPresentation(durationMinutes: 10_080)
    #expect(weekly.period == "주간")
    #expect(weekly.remainingTitle == "WEEKLY REMAINING")
    #expect(weekly.resetTitle == "Weekly Reset")

    let short = UsageWindowPresentation(durationMinutes: 300)
    #expect(short.period == "5시간")
    #expect(short.remainingTitle == "5시간 잔여 사용량")
    #expect(short.resetTitle == "5시간 리셋")

    let custom = UsageWindowPresentation(durationMinutes: 90)
    #expect(custom.period == "90분")
    #expect(custom.remainingTitle == "90분 잔여 사용량")
    #expect(custom.resetTitle == "90분 리셋")

    let unknown = UsageWindowPresentation(durationMinutes: nil)
    #expect(unknown.period == "기간 미상")
    #expect(unknown.remainingTitle == "사용량 확인 중")
  }
}

@Suite("Usage loading and cache state")
@MainActor
struct UsageStoreTests {
  @Test("First launch stays loading until its first successful response")
  func firstLaunchTransitionsFromLoadingToLive() async throws {
    let (defaults, suite) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = usageSnapshot()
    let store = UsageStore(
      userDefaults: defaults, fetchUsage: { .success(snapshot) }, automaticallyRefresh: false
    )

    #expect(store.dataStatus == .loading)
    #expect(store.remainingPercentage == nil)
    let refresh = try #require(store.refreshUsage())
    #expect(store.isRefreshing)
    #expect(store.dataStatus == .loading)
    #expect(store.refreshUsage() == nil)
    await refresh.value

    #expect(store.dataStatus == .live)
    #expect(!store.isRefreshing)
    #expect(store.remainingPercentage == 28)
    #expect(store.windowDurationMins == 300)
    #expect(store.windowPresentation.remainingTitle == "5시간 잔여 사용량")
    #expect(store.lastErrorMessage == nil)
  }

  @Test("Failure without a successful snapshot is unavailable")
  func firstFailureIsUnavailable() async throws {
    let (defaults, suite) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UsageStore(
      userDefaults: defaults, fetchUsage: { .failure(.usageWindowNotFound) }, automaticallyRefresh: false
    )

    await store.refreshUsage()?.value

    #expect(store.dataStatus == .unavailable)
    #expect(store.remainingPercentage == nil)
    #expect(store.lastRefreshedAt == nil)
    #expect(store.lastErrorMessage != nil)
    #expect(defaults.data(forKey: "persistedUsageSnapshot") == nil)
  }

  @Test("A later failure preserves the last successful value as stale")
  func failurePreservesLastSuccessfulSnapshot() async throws {
    let (defaults, suite) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let responses = ScriptedUsageResponses([.success(usageSnapshot()), .failure(.appServerFailed)])
    let store = UsageStore(
      userDefaults: defaults, fetchUsage: { await responses.next() }, automaticallyRefresh: false
    )
    await store.refreshUsage()?.value
    let successfulRefreshDate = try #require(store.lastRefreshedAt)
    let successfulCache = try #require(defaults.data(forKey: "persistedUsageSnapshot"))

    await store.refreshUsage()?.value

    #expect(store.dataStatus == .stale)
    #expect(store.remainingPercentage == 28)
    #expect(store.windowDurationMins == 300)
    #expect(store.lastRefreshedAt == successfulRefreshDate)
    #expect(store.lastErrorMessage != nil)
    #expect(defaults.data(forKey: "persistedUsageSnapshot") == successfulCache)
  }

  @Test("A restarted app restores the actual window and model limits as stale")
  func restoresWindowDurationAfterRestart() async throws {
    let (defaults, suite) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = usageSnapshot()
    let firstStore = UsageStore(
      userDefaults: defaults, fetchUsage: { .success(snapshot) }, automaticallyRefresh: false
    )
    await firstStore.refreshUsage()?.value

    let restored = UsageStore(
      userDefaults: defaults, fetchUsage: { .failure(.appServerFailed) }, automaticallyRefresh: false
    )

    #expect(restored.dataStatus == .stale)
    #expect(restored.remainingPercentage == 28)
    #expect(restored.windowDurationMins == 300)
    #expect(restored.windowPresentation.resetTitle == "5시간 리셋")
    #expect(restored.resetAt == firstStore.resetAt)
    #expect(restored.lastRefreshedAt == firstStore.lastRefreshedAt)
    #expect(restored.modelSpecificLimits.first?.windowDurationMins == 300)
    #expect(restored.modelSpecificLimits.first?.remainingPercentage == 0)

    await restored.refreshUsage()?.value
    #expect(restored.dataStatus == .stale)
    #expect(restored.remainingPercentage == 28)
  }

  @Test("Legacy and invalid-duration caches cannot masquerade as weekly data")
  func rejectsLegacyAndInvalidDurationCaches() async throws {
    let (defaults, suite) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = usageSnapshot()
    let source = UsageStore(
      userDefaults: defaults, fetchUsage: { .success(snapshot) }, automaticallyRefresh: false
    )
    await source.refreshUsage()?.value
    let cache = try #require(defaults.data(forKey: "persistedUsageSnapshot"))
    let validObject = try #require(JSONSerialization.jsonObject(with: cache) as? [String: Any])

    for duration: Int? in [nil, 0, -300] {
      var object = validObject
      object["windowDurationMins"] = duration
      defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "persistedUsageSnapshot")
      let restored = UsageStore(
        userDefaults: defaults, fetchUsage: { .failure(.appServerFailed) }, automaticallyRefresh: false
      )

      #expect(restored.dataStatus == .loading)
      #expect(restored.remainingPercentage == nil)
      #expect(restored.windowDurationMins == nil)
    }
  }

  private func isolatedDefaults() throws -> (UserDefaults, String) {
    let suite = "CodexUsageMenuBarTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  private func usageSnapshot() -> CodexUsageSnapshot {
    CodexUsageSnapshot(
      usageWindow: RateLimitWindow(usedPercent: 72, windowDurationMins: 300, resetsAt: 1_800_018_000),
      planType: "pro",
      cliVersion: "0.146.1",
      availableResetCredits: 1,
      nearestResetCreditExpiry: nil,
      modelSpecificLimits: [
        ModelSpecificLimit(
          id: "model", windowDurationMins: 300, name: "Model", remainingPercentage: 0,
          resetAt: Date(timeIntervalSince1970: 1_800_018_000)
        )
      ]
    )
  }
}

private actor ScriptedUsageResponses {
  private var responses: [Result<CodexUsageSnapshot, RateLimitFetchError>]

  init(_ responses: [Result<CodexUsageSnapshot, RateLimitFetchError>]) {
    self.responses = responses
  }

  func next() -> Result<CodexUsageSnapshot, RateLimitFetchError> {
    responses.removeFirst()
  }
}
