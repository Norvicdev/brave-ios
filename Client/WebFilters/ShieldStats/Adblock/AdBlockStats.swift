/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import BraveShared
import Combine
import BraveCore

private let log = Logger.browserLogger

struct CosmeticFilterModel: Codable {
  let hideSelectors: [String]
  let styleSelectors: [String: [String]]
  let exceptions: [String]
  let injectedScript: String
  let genericHide: Bool
  
  enum CodingKeys: String, CodingKey {
    case hideSelectors = "hide_selectors"
    case styleSelectors = "style_selectors"
    case exceptions = "exceptions"
    case injectedScript = "injected_script"
    case genericHide = "generichide"
  }
  
  func makeCSSRules() -> String {
    let hideRules = hideSelectors.reduce("") { partialResult, rule in
      return [partialResult, rule, "{display: none !important}\n"].joined()
    }
    
    let styleRules = styleSelectors.reduce("") { partialResult, entry in
      let subRules = entry.value.reduce("") { partialResult, subRule in
        return [partialResult, subRule, ";"].joined()
      }
      
      return [partialResult, entry.key, "{", subRules, " !important}\n"].joined()
    }
    
    return [hideRules, styleRules].joined()
  }
}

public class AdBlockStats: LocalAdblockResourceProtocol {
  public static let shared = AdBlockStats()

  /// File name of bundled general blocklist.
  private let bundledGeneralBlocklist = "ABPFilterParserData"

  fileprivate var fifoCacheOfUrlsChecked = FifoDict<Bool>()

  // Adblock engine for general adblock lists.
  private(set) var generalAdblockEngine: AdblockEngine
  
  // Adblock engine for general adblock lists.
  private(set) var cosmeticFilteringEngine: AdblockEngine

  /// Adblock engine for regional, non-english locales.
  private(set) var filterListsEngine: AdblockEngine?

  /// The task that downloads all the files. Can be cancelled
  private var downloadTask: AnyCancellable?

  fileprivate var isRegionalAdblockEnabled: Bool { return Preferences.Shields.useRegionAdBlock.value }

  fileprivate init() {
    generalAdblockEngine = AdblockEngine()
    cosmeticFilteringEngine = AdblockEngine()
  }

  static let adblockSerialQueue = DispatchQueue(label: "com.brave.adblock-dispatch-queue")

  public func startLoading() {
    parseBundledGeneralBlocklist()
  }
  
  /// Checks the general and regional engines to see if the request should be blocked.
  ///
  /// - Note: This method is should not be synced on `AdBlockStatus.adblockSerialQueue` and the result is synced on the main thread.
  func shouldBlock(requestURL: URL, sourceURL: URL, resourceType: AdblockEngine.ResourceType, callback: @escaping (Bool) -> Void) {
    Self.adblockSerialQueue.async { [weak self] in
      let shouldBlock = self?.shouldBlock(requestURL: requestURL, sourceURL: sourceURL, resourceType: resourceType) == true
      
      DispatchQueue.main.async {
        callback(shouldBlock)
      }
    }
  }
  
  /// Checks the general and regional engines to see if the request should be blocked
  ///
  /// - Warning: This method needs to be synced on `AdBlockStatus.adblockSerialQueue`
  func shouldBlock(requestURL: URL, sourceURL: URL, resourceType: AdblockEngine.ResourceType) -> Bool {
    let key = [requestURL.absoluteString, sourceURL.absoluteString, resourceType.rawValue].joined(separator: "_")
    
    if let cachedResult = fifoCacheOfUrlsChecked.getElement(key) {
        return cachedResult
    }
    
    let shouldBlock = generalAdblockEngine.shouldBlock(
      requestURL: requestURL,
      sourceURL: sourceURL,
      resourceType: resourceType
    ) || (isRegionalAdblockEnabled && filterListsEngine?.shouldBlock(
      requestURL: requestURL,
      sourceURL: sourceURL,
      resourceType: resourceType
    ) ?? false)
    
    fifoCacheOfUrlsChecked.addElement(shouldBlock, forKey: key)
    return shouldBlock
  }

  private func parseBundledGeneralBlocklist() {
    guard let path = Bundle.current.path(forResource: bundledGeneralBlocklist, ofType: "dat") else {
      log.error("Can't find path for bundled general blocklist")
      return
    }
    let fileUrl = URL(fileURLWithPath: path)

    do {
      let data = try Data(contentsOf: fileUrl)
      AdBlockStats.adblockSerialQueue.async {
        self.generalAdblockEngine.deserialize(data: data)
      }
    } catch {
      log.error("Failed to parse bundled general blocklist: \(error)")
    }
  }

  // Firefox has uses urls of the form
  // http://localhost:6571/errors/error.html?url=http%3A//news.google.ca/
  // to populate the browser history, and load+redirect using GCDWebServer
  private func stripLocalhostWebServer(_ url: String?) -> String {
    guard let url = url else { return "" }

    // I think the ones prefixed with the following are the only ones of concern. There is also about/sessionrestore urls, not sure if we need to look at those
    let token = "?url="

    if let range = url.range(of: token) {
      return url[range.upperBound..<url.endIndex].removingPercentEncoding ?? ""
    } else {
      return url
    }
  }
  
  func set(filterListsEngine: AdblockEngine) {
    self.filterListsEngine = filterListsEngine
    self.fifoCacheOfUrlsChecked = FifoDict<Bool>()
  }
  
  func set(genericEngine: AdblockEngine) {
    self.generalAdblockEngine = genericEngine
    self.fifoCacheOfUrlsChecked = FifoDict<Bool>()
  }
  
  func set(cosmeticFilteringEngine: AdblockEngine) {
    self.cosmeticFilteringEngine = cosmeticFilteringEngine
    self.fifoCacheOfUrlsChecked = FifoDict<Bool>()
  }
}

extension AdBlockStats {
  func cosmeticFiltersScript(for url: URL) throws -> String? {
    var cssRules: [String] = []
    var injectedScripts: [String] = []
    
    var rulesList = [
      cosmeticFilteringEngine.cosmeticResourcesForURL(url.absoluteString),
      generalAdblockEngine.cosmeticResourcesForURL(url.absoluteString)
    ]
    
    if isRegionalAdblockEnabled, let rules = filterListsEngine?.cosmeticResourcesForURL(url.absoluteString) {
      rulesList.append(rules)
    }
    
    for rules in rulesList {
      guard let data = rules.data(using: .utf8) else { continue }
      let model = try JSONDecoder().decode(CosmeticFilterModel.self, from: data)
      cssRules.append(model.makeCSSRules())
      
      if !model.injectedScript.isEmpty {
        injectedScripts.append([
          "(function(){",
          model.injectedScript,
          "})();"
        ].joined(separator: "\n"))
      }
    }
    
    var injectedScript = injectedScripts.joined(separator: "\n")

    if !injectedScript.isEmpty, Preferences.Shields.autoRedirectAMPPages.value {
      injectedScript = [
        "(function(){",
        /// This boolean is used by a script injected by cosmetic filters and enables that script via this boolean
        /// The script is found here: https://github.com/brave/adblock-resources/blob/master/resources/de-amp.js
        /// - Note: This script is only a smaller part (1 of 3) of de-amping:
        /// The second part is handled by an inected script that redirects amp pages to their canonical links
        /// The third part is handled by debouncing amp links and handled by debouncing rules
        "const deAmpEnabled = true;",
        injectedScript,
        "})();"
      ].joined(separator: "\n")
    }
    
    return """
    (function() {
      var head = document.head || document.getElementsByTagName('head')[0];
      if (head == null) {
          return;
      }
      
      var style = document.createElement('style');
      style.type = 'text/css';
    
      var styles = atob("\(cssRules.joined().toBase64())");
      
      if (style.styleSheet) {
        style.styleSheet.cssText = styles;
      } else {
        style.appendChild(document.createTextNode(styles));
      }

      head.appendChild(style);
      \(injectedScript)
    })();
    """
  }
}
