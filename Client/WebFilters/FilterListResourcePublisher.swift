//
//  FilterListResourcePublisher.swift
//  
//
//  Created by Jacob on 2022-07-21.
//

import Foundation
import Shared
import BraveCore

private let log = Logger.browserLogger

class FilterListResourcePublisher {
  /// Enum representing the type of filter list resource
  enum ResourceType: CaseIterable {
    /// Ad-block engine rules
    case filterRules
    /// iOS only content blocking behaviours used for the iOS content blocker
    case contentBlockingBehaviors
    
    func downloadResource(for filterList: FilterList) -> ResourceDownloader.Resource {
      switch self {
      case .contentBlockingBehaviors:
        return .contentBlockingBehaviors(uuid: filterList.uuid, componentId: filterList.componentId)
      case .filterRules:
        return .filterRules(uuid: filterList.uuid, componentId: filterList.componentId)
      }
    }
  }
  
  private struct FilterListResource: Hashable, Equatable {
    let filterList: FilterList
    
    func hash(into hasher: inout Hasher) {
      hasher.combine(filterList.uuid)
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
      return lhs.filterList.uuid == rhs.filterList.uuid
    }
  }
  
  typealias DownloadResult = (date: Date, result: Result<URL, Error>)
  typealias DownloadResultPerFilterList = [String: DownloadResult]
  
  /// A disctionary of resource results per filter list
  @Published private(set) var resourceDownloadResults: [
    ResourceType: DownloadResultPerFilterList
  ] = [:]
  
  /// How frequently to re-fetch downloaded data
  private lazy var fetchInterval = AppConstants.buildChannel.isPublic ? 6.hours : 10.minutes
  /// Object responsible for doing the downloads
  private let resourceDownloader: ResourceDownloader
  /// A list of all filter lists that will be used as a source to download/sync files
  private var enabledFilterLists: Set<FilterListResource>
  /// A timer that that processes filter lists that need to be downloaded
  private var timer: Timer?
  /// The current download tasks per resource type
  private var downloadTasks: [ResourceType: Task<(), Error>] = [:]
  
  /// Initialize
  init(networkManager: NetworkManager) {
    enabledFilterLists = []
    resourceDownloader = ResourceDownloader(networkManager: networkManager)
    resourceDownloadResults = [:]
    
    // Pre-pouplate the data per resource
    ResourceType.allCases.forEach { resourceType in
      resourceDownloadResults[resourceType] = [:]
    }
  }
  
  static func loadFilterLists() -> [FilterList] {
    let filterListsURL = Bundle.module.url(forResource: "filter_lists", withExtension: "json")!
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    
    // Setup the initial data
    do {
      let data = try Data(contentsOf: filterListsURL)
      return try jsonDecoder.decode([FilterList].self, from: data)
        .sorted(by: { $0.title < $1.title })
    } catch {
      log.error(error)
      return []
    }
  }
  
  func start(enabledFilterLists: [FilterList]) {
    self.enabledFilterLists = Set(enabledFilterLists.map({ FilterListResource(filterList: $0) }))
    self.timer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(invokeTimer), userInfo: nil, repeats: true)
    invokeTimer()
  }
  
  func enable(filterList: FilterList, isEnabled: Bool) {
    let filterListResource = FilterListResource(filterList: filterList)
    
    // Enable/disable this filter item
    if isEnabled {
      enabledFilterLists.insert(filterListResource)
    } else {
      enabledFilterLists.remove(filterListResource)
    }
  }
  
  /// Invoked when the timer triggers
  @objc private func invokeTimer() {
    ResourceType.allCases.forEach { resourceType in
      attemptToLoadData(for: resourceType)
    }
  }
  
  private func attemptToLoadData(for resourceType: ResourceType) {
    guard downloadTasks[resourceType] == nil else { return }
    let now = Date()
    
    // Get the filter lists to be downloaded
    let filterListsToDownload = self.enabledFilterLists.compactMap({ filterListResource -> FilterList? in
      guard let previousResult = resourceDownloadResults[resourceType]?[filterListResource.filterList.uuid] else {
        // If we don't have this file, download it
        return filterListResource.filterList
      }
      
      if now.timeIntervalSince(previousResult.date) >= fetchInterval ||
          Self.downloadedURL(for: filterListResource.filterList, resourceType: resourceType) == nil {
        // Previous result is outdated or (for some reason) the file doesn't actually exist (which should't happen)
        return filterListResource.filterList
      } else {
        return nil
      }
    })
    
    // Check if there is anything to do (download something or reload something)
    guard !filterListsToDownload.isEmpty else { return }
    
    downloadTasks[resourceType] = Task.detached(priority: .background) {
      let downloadResults = await self.downloadResources(of: resourceType, for: filterListsToDownload)
      await self.recieve(downloadResults: downloadResults, for: resourceType)
    }
  }
  
  /// Invoked on download results. Sets the results and clears the download task
  @MainActor private func recieve(downloadResults: [String: DownloadResult], for resourceType: ResourceType) {
    assertIsMainThread("Not main thread")
    downloadResults.forEach { uuid, downloadResult in
      self.resourceDownloadResults[resourceType]?[uuid] = downloadResult
    }
    
    downloadTasks.removeValue(forKey: resourceType)
  }
  
  /// Download all the required data for the provided filter lists
  private func downloadResources(of resourceType: ResourceType, for filterLists: [FilterList]) async -> [String: DownloadResult] {
    return await withTaskGroup(of: (filterList: FilterList, downloadResult: DownloadResult).self) { group in
      for filterList in filterLists {
        group.addTask {
          do {
            let downloadResult = try await self.resourceDownloader.download(
              resource: resourceType.downloadResource(for: filterList)
            )
            
            switch downloadResult {
            case .downloaded(let url, let date):
              return (filterList, (date, .success(url)))
            case .notModified(let url, let date):
              return (filterList, (date, .success(url)))
            }
          } catch {
            return (filterList, (Date(), .failure(error)))
          }
        }
      }
      
      var results: [String: DownloadResult] = [:]
      
      for await item in group {
        results[item.filterList.uuid] = item.downloadResult
      }

      return results
    }
  }
  
  /// Load the data for the given filter list and resource type
  ///
  /// - Note: Return nil if the data does not exist
  static func dataForResource(for filterList: FilterList, resourceType: ResourceType) throws -> Data? {
    return try ResourceDownloader.data(for: resourceType.downloadResource(for: filterList))
  }
  
  /// Get the downloaded file URL for the filter list and resource type
  ///
  /// - Note: Returns nil if the file does not exist
  static func downloadedURL(for filterList: FilterList, resourceType: ResourceType) -> URL? {
    return ResourceDownloader.downloadedFileURL(
      for: resourceType.downloadResource(for: filterList)
    )
  }
}
