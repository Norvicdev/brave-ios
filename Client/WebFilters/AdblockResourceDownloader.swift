// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveCore
import Shared
import BraveShared

private let log = Logger.browserLogger

public class AdblockResourceDownloader {
  public static let shared = AdblockResourceDownloader()
  
  /// A boolean indicating if this is a first time load of this downloader so we only load cached data once
  private var initialLoad = true
  private let resourceDownloader: ResourceDownloader
  private let serialQueue = DispatchQueue(label: "com.brave.FilterListManager-dispatch-queue")

  init(networkManager: NetworkManager = NetworkManager()) {
    self.resourceDownloader = ResourceDownloader(networkManager: networkManager)
  }

  /// Initialized with year 1970 to force adblock fetch at first launch.
  private(set) var lastFetchDate = Date(timeIntervalSince1970: 0)

  public func startLoading() {
    guard initialLoad else { return }
    initialLoad = false
    
    Task {
      await loadStoredDate()
      await startFetching()
    }
  }

  @MainActor private func startFetching() {
    assertIsMainThread("Not on main thread")
    let now = Date()
    let fetchInterval = AppConstants.buildChannel.isPublic ? 6.hours : 10.minutes
    
    if now.timeIntervalSince(lastFetchDate) >= fetchInterval {
      lastFetchDate = now
      downloadFilterRules()
      downloadContentBlockingBehaviours()
      downloadCosmeticFilterData()
    }
  }
  
  private func loadStoredDate() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          try await self.loadEngineFromGeneralFilterRules()
        } catch {
          log.error(error)
        }
      }
      
      group.addTask {
        do {
          try await self.loadEngineFromGeneralCosmeticFilterResources()
        } catch {
          log.error(error)
        }
      }
      
      group.addTask {
        do {
          try await self.loadContentBlockers()
        } catch {
          log.error(error)
        }
      }
    }
  }
  
  private func downloadFilterRules() {
    Task.detached(priority: .background) {
      do {
        let result = try await self.resourceDownloader.download(resource: .genericFilterRules)
        
        switch result {
        case .notModified:
          // No need to reload this
          break
        case .downloaded:
          try await self.loadEngineFromGeneralFilterRules()
        }
      } catch {
        log.error(error)
      }
    }
  }
  
  private func downloadContentBlockingBehaviours() {
    Task.detached(priority: .background) {
      do {
        let result = try await self.resourceDownloader.download(resource: .genericContentBlockingBehaviors)
        
        switch result {
        case .notModified:
          // No need to reload this
          break
        case .downloaded:
          try await self.loadContentBlockers()
        }
      } catch {
        log.error(error)
      }
    }
  }

  private func downloadCosmeticFilterData() {
    Task.detached(priority: .background) {
      do {
        let results = try await self.fetchDownloadCosmeticFilterData()
        
        var isModified = false
        switch results.cosmeticFilters {
        case .notModified: break
        case .downloaded: isModified = true
        }
        
        switch results.scriptletResources {
        case .notModified: break
        case .downloaded: isModified = true
        }
        
        if isModified {
          try await self.loadEngineFromGeneralCosmeticFilterResources()
        }
      } catch {
        log.error(error)
      }
    }
  }
  
  private func loadEngineFromGeneralFilterRules() async throws {
    let engine = AdblockEngine()
    
    if let data = try ResourceDownloader.data(for: .genericFilterRules) {
      try await self.deserialize(data: data, into: engine)
    }
    
    await self.set(genericEngine: engine)
  }
  
  private func loadEngineFromGeneralCosmeticFilterResources() async throws {
    let engine = AdblockEngine()
    
    if let data = try ResourceDownloader.data(for: .generalCosmeticFilters) {
      try await deserialize(data: data, into: engine)
    }
    
    if let data = try ResourceDownloader.data(for: .generalScriptletResources) {
      try await addJSON(data: data, into: engine)
    }
    
    await set(cosmeticFilteringEngine: engine)
  }
  
  private func loadContentBlockers() async throws {
    guard let contentBlockerData = try ResourceDownloader.data(for: .genericContentBlockingBehaviors) else {
      return
    }
    try await compileContentBlocker(data: contentBlockerData)
  }
  
  @MainActor private func set(genericEngine: AdblockEngine) {
    assertIsMainThread("Not on main thread")
    AdBlockStats.shared.set(genericEngine: genericEngine)
  }
  
  @MainActor private func set(cosmeticFilteringEngine: AdblockEngine) {
    assertIsMainThread("Not on main thread")
    AdBlockStats.shared.set(cosmeticFilteringEngine: cosmeticFilteringEngine)
  }
  
  typealias CosmeticFilterResult = (
    cosmeticFilters: ResourceDownloader.DownloadResult<URL>,
    scriptletResources: ResourceDownloader.DownloadResult<URL>
  )
  
  private func fetchDownloadCosmeticFilterData() async throws -> CosmeticFilterResult {
    async let cosmeticFilters = try self.resourceDownloader.download(resource: .generalCosmeticFilters)
    async let scriptletResources = try self.resourceDownloader.download(resource: .generalScriptletResources)
    return try await (cosmeticFilters, scriptletResources)
  }

  private func compileContentBlocker(data: Data) async throws {
    let blockList = BlocklistName.ad
    return try await blockList.compile(data: data)
  }
  
  private func deserialize(data: Data, into engine: AdblockEngine) async throws {
    return try await withCheckedThrowingContinuation({ continuation in
      self.serialQueue.async {
        if engine.deserialize(data: data) {
          continuation.resume()
        } else {
          continuation.resume(throwing: "Failed to deserialize data")
        }
      }
    })
  }
  
  private func addJSON(data: Data, into engine: AdblockEngine) async throws {
    return try await withCheckedThrowingContinuation({ continuation in
      self.serialQueue.async {
        if !self.isValidJSONData(data) {
          continuation.resume(throwing: "Invalid JSON Data")
          return
        }
        
        if let json = String(data: data, encoding: .utf8) {
          engine.addResources(json)
          continuation.resume()
        } else {
          continuation.resume(throwing: "Invalid JSON String - Bad Encoding")
        }
      }
    })
  }
  
  private func isValidJSONData(_ data: Data) -> Bool {
    do {
      let value = try JSONSerialization.jsonObject(with: data, options: [])
      if let value = value as? NSArray {
        return value.count > 0
      }
      
      if let value = value as? NSDictionary {
        return value.count > 0
      }
      
      log.error("JSON Must have a top-level type of Array of Dictionary.")
      return false
    } catch {
      log.error("JSON Deserialization Failed: \(error)")
      return false
    }
  }
}
