// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import WebKit
import Shared
import Data
import BraveShared
import Combine

private let log = Logger.browserLogger

class BlocklistName: CustomStringConvertible, ContentBlocker {

  static let ad = BlocklistName(filename: "block-ads")
  static let tracker = BlocklistName(filename: "block-trackers")
  static let https = BlocklistName(filename: "upgrade-http")
  static let image = BlocklistName(filename: "block-images")
  static let cookie = BlocklistName(filename: "block-cookies")

  /// List of all bundled content blockers.
  /// Regional lists are downloaded on fly and not included here.
  static var allLists: Set<BlocklistName> {
    // TODO: Downgrade to 14.5 once api becomes available.
    if #available(iOS 15, *) {
      return [.ad, .tracker, .image]
    } else {
      return [.ad, .tracker, .https, .image]
    }
  }

  let filename: String
  var rule: WKContentRuleList?

  init(filename: String) {
    self.filename = filename
  }

  var description: String {
    return "<\(type(of: self)): \(self.filename)>"
  }

  private static let blocklistFileVersionMap: [BlocklistName: Preferences.Option<String?>] = [
    BlocklistName.ad: Preferences.BlockFileVersion.adblock,
    BlocklistName.https: Preferences.BlockFileVersion.httpse,
  ]

  lazy var fileVersionPref: Preferences.Option<String?>? = {
    return BlocklistName.blocklistFileVersionMap[self]
  }()

  lazy var fileVersion: String? = {
    guard let _ = BlocklistName.blocklistFileVersionMap[self] else { return nil }
    return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }()

  static func blocklists(forDomain domain: Domain) -> (on: Set<BlocklistName>, off: Set<BlocklistName>) {
    let filterListWrappers = FilterListResourceSubscriber.shared.filterListWrappers
    
    let allFilterListBlockLists = Set(filterListWrappers.map { filterListWrapper -> BlocklistName in
      return filterListWrapper.makeBlocklistName()
    })
    
    if domain.shield_allOff == 1 {
      var offList = allLists
      
      // Make sure to consider the filter list which needs to be disabled as well
      offList = offList.intersection(allFilterListBlockLists)
      return ([], offList)
    }

    var onList = Set<BlocklistName>()

    if domain.isShieldExpected(.AdblockAndTp, considerAllShieldsOption: true) {
      onList.formUnion([.ad, .tracker])
    }
    
    let enabledFilterLists = Set(filterListWrappers.compactMap { filterListWrapper -> BlocklistName? in
      guard filterListWrapper.isEnabled else { return nil }
      let filterListState = FilterListResourceSubscriber.shared.state(
        for: filterListWrapper.filterList, resourceType: .contentBlockingBehaviors
      )
      switch filterListState?.loadState {
      case .loaded: return filterListWrapper.makeBlocklistName()
      case .notLoaded, .error, .none: return nil
      }
    })
    
    onList = onList.intersection(enabledFilterLists)

    // For lists not implemented, always return exclude from `onList` to prevent accidental execution
    // TODO #159: Setup image shield
    let disabledFilterLists = allFilterListBlockLists.subtracting(enabledFilterLists)
    let offList = allLists.subtracting(onList).intersection(disabledFilterLists)
    return (onList, offList)
  }

  static func compileBundledRules(ruleStore: WKContentRuleListStore) -> AnyPublisher<Void, Error> {
    var allRules = BlocklistName.allLists.map({ $0.buildRule(ruleStore: ruleStore) })
    
    // Compile block-cookie additionally
    allRules.append(BlocklistName.cookie.buildRule(ruleStore: ruleStore))
    return Publishers.MergeMany(allRules)
      .collect()
      .map({ _ in () })
      .eraseToAnyPublisher()
  }

  func compile(
    data: Data,
    ruleStore: WKContentRuleListStore = ContentBlockerHelper.ruleStore
  ) async throws {
    return try await withCheckedThrowingContinuation { continuation in
      guard let dataString = String(data: data, encoding: .utf8) else {
        continuation.resume(returning: ())
        return
      }

      ruleStore.compileContentRuleList(forIdentifier: self.filename, encodedContentRuleList: dataString) { rule, error in
        if let error = error {
          continuation.resume(throwing: error)
          return
        }
        
        assert(rule != nil)
        self.rule = rule
        continuation.resume()
      }
    }
  }
}
