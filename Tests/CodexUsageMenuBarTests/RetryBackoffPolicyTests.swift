import Foundation
import Testing

@testable import CodexUsageMenuBar

@Suite("Retry backoff policy")
struct RetryBackoffPolicyTests {
  @Test("Retry intervals grow and remain capped")
  func retryIntervalsGrowAndRemainCapped() {
    var retryBackoffPolicy = RetryBackoffPolicy()

    let intervals = (0..<5).map { _ in retryBackoffPolicy.nextInterval() }

    #expect(intervals == [30, 120, 300, 300, 300])
  }

  @Test("A successful refresh resets the retry interval")
  func successfulRefreshResetsRetryInterval() {
    var retryBackoffPolicy = RetryBackoffPolicy()
    _ = retryBackoffPolicy.nextInterval()
    _ = retryBackoffPolicy.nextInterval()

    retryBackoffPolicy.reset()

    #expect(retryBackoffPolicy.nextInterval() == 30)
  }
}
