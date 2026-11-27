import Foundation

struct CatProviderFileSignature: Equatable {
  private struct File: Equatable {
    let modified: Date
    let bytes: UInt64
    let inode: UInt64
    let permissions: UInt16

    init?(_ url: URL) {
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let date = attrs[.modificationDate] as? Date,
        let bytes = (attrs[.size] as? NSNumber)?.uint64Value,
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
      else { return nil }
      self.modified = date
      self.bytes = bytes
      self.inode = inode
      self.permissions = permissions
    }
  }

  private let primary: File?
  private let companion: File?
  var lastModified: Date? { [primary?.modified, companion?.modified].compactMap { $0 }.max() }

  init(_ url: URL, provider: CatProvider, database: Bool) {
    self.primary = File(url)
    let companionURL: URL? =
      if database {
        URL(fileURLWithPath: url.path + "-wal")
      } else {
        switch provider {
        case .grok: url.deletingLastPathComponent().appendingPathComponent("summary.json")
        case .kiro:
          url.lastPathComponent == "messages.jsonl"
            ? url.deletingLastPathComponent().appendingPathComponent("session.json")
            : url.deletingPathExtension().appendingPathExtension("json")
        default: nil
        }
      }
    self.companion = companionURL.flatMap(File.init)
  }
}

// The cache holds normalized metadata from complete reads, never file contents.
final class CatProviderFileCache: @unchecked Sendable {
  final class Value {
    let signature: CatProviderFileSignature
    let samples: [CatUsageSample]

    init(signature: CatProviderFileSignature, samples: [CatUsageSample]) {
      self.signature = signature
      self.samples = samples
    }
  }

  static let shared = CatProviderFileCache()
  private let cache = NSCache<NSString, Value>()

  private init() {
    cache.countLimit = 4_096
    cache.totalCostLimit = 64 * 1_024 * 1_024
  }

  func value(for key: String) -> Value? { cache.object(forKey: key as NSString) }

  func store(_ samples: [CatUsageSample], signature: CatProviderFileSignature, for key: String) {
    let estimatedBytes = samples.reduce(128) { $0 + 128 + $1.id.utf8.count }
    cache.setObject(Value(signature: signature, samples: samples), forKey: key as NSString, cost: estimatedBytes)
  }
}
