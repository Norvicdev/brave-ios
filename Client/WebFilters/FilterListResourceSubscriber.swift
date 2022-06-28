//
//  FilterListResourceSubscriber.swift
//  
//
//  Created by Jacob on 2022-07-21.
//

import Foundation
import Combine
import Data
import BraveCore
import Shared

private let log = Logger.browserLogger

public class FilterListResourceSubscriber: ObservableObject {
  /// An object representing the state of a single filter list
  struct FilterListWrapper: Identifiable {
    /// The associated filter list
    let filterList: FilterList
    /// Wether or not the filter list is enabled
    var isEnabled: Bool
    /// The identifier of the filter list. The same as `filterList.uuid`
    var id: String { filterList.uuid }
    
    func makeBlocklistName() -> BlocklistName {
      return BlocklistName(filename: filterList.componentId)
    }
  }
  
  /// Represents the state of the downloads
  enum DownloadState {
    /// Not all files are yet downloaded
    case notDownloaded
    /// Data is downloaded successfully
    case downloaded(Date)
    /// An error occured during download
    case error(Error)
  }
  
  enum LoadState {
    case loaded
    case notLoaded
    case error(Error)
  }
  
  struct FilterListState {
    var loadState: LoadState
    var downloadState: DownloadState
    
    /// Return if we need to reload data for this state if
    /// 1. is loaded but not enabled
    /// 2. is not loaded but enabled and downloaded
    ///
    /// - Note: If we encounter errors during loading previosly they will always return false
    func needsReload(isEnabled: Bool) -> Bool {
      guard isEnabled else {
        // If it's not enabled we just check if its loaded and shouldn't be
        switch loadState {
        case .loaded: return true
        case .notLoaded, .error: return false
        }
      }
      
      switch loadState {
      case .loaded:
        // Enabled and loaded means we don't need to do anything
        return false
      case .notLoaded:
        // Enabled but not loaded means we need to check the download state
        switch downloadState {
        case .downloaded:
          return true
        case .notDownloaded, .error:
          return false
        }
      case .error:
        // When there is a load error let's not keep trying to reload it
        return false
      }
    }
    
    /// Return if we need to load data for this state if its enabled and downloaded
    func needsLoad(isEnabled: Bool) -> Bool {
      guard isEnabled else { return false }
      
      switch downloadState {
      case .downloaded:
        return true
      case .notDownloaded, .error:
        return false
      }
    }
  }
  
  /// A shared instance of this class
  ///
  /// - Warning: You need to wait for `DataController.shared.initializeOnce()` to be called before using this instance
  public static let shared = FilterListResourceSubscriber()
  
  /// The publisher that syncs downloading/fetching filter lists
  private let publisher: FilterListResourcePublisher
  /// The download subscription to the publisher
  private var downloadSubscription: AnyCancellable?
  /// The filter list subscription
  private var filterListSubscription: AnyCancellable?
  /// Settings for the filter lists
  private var filterListSettings: [FilterListSetting]
  /// A serial queue used to sync adblock engine loads
  private let engineSerialQueue = DispatchQueue(label: "com.brave.FilterListResourceSubscriber.engineSerialQueue")
  /// A timer that that processes downloaded and enabled resources
  private var timer: Timer?
  /// The current load data tasks per resource type
  private var loadDataTasks: [FilterListResourcePublisher.ResourceType: Task<(), Never>] = [:]
  /// The state per resource type and filter list
  private var filterListStates: [String: [FilterListResourcePublisher.ResourceType: FilterListState]]
  
  /// The filter lists wrapped up so we can contain
  @Published var filterListWrappers: [FilterListWrapper]
  
  init(networkManager: NetworkManager = NetworkManager()) {
    self.publisher = FilterListResourcePublisher(networkManager: networkManager)
    self.filterListSettings = []
    self.filterListWrappers = []
    self.filterListStates = [:]
  }
  
  /// Start this resource subscriber
  public func start() {
    guard downloadSubscription == nil else { return }
    filterListSettings = FilterListSetting.allSettings()
    let filterLists = FilterListResourcePublisher.loadFilterLists()
    let date = Date(timeIntervalSince1970: 0)
    
    self.filterListWrappers = filterLists.map { filterList in
      let filterListSetting = filterListSettings.first(where: { $0.uuid == filterList.uuid })
      let filterListURL = FilterListResourcePublisher.downloadedURL(for: filterList, resourceType: .filterRules)
      let contentBlockingBehaviorsURL = FilterListResourcePublisher.downloadedURL(for: filterList, resourceType: .contentBlockingBehaviors)
      
      filterListStates[filterList.uuid] = [
        .filterRules: FilterListState(
          loadState: .notLoaded,
          downloadState: filterListURL != nil ? .downloaded(date) : .notDownloaded
        ),
        .contentBlockingBehaviors: FilterListState(
          loadState: .notLoaded,
          downloadState: contentBlockingBehaviorsURL != nil ? .downloaded(date) : .notDownloaded
        )
      ]
      
      return FilterListWrapper(
        filterList: filterList,
        isEnabled: filterListSetting?.isEnabled == true
      )
    }
    
    // Subscribe to changes to download results
    downloadSubscription = publisher.$resourceDownloadResults
      .receive(on: DispatchQueue.main)
      .sink { results in
        assertIsMainThread("Not main thread")
        for filterListWrapper in self.filterListWrappers {
          var filterListStates = self.filterListStates[filterListWrapper.filterList.uuid] ?? [:]
          
          for (resourceType, filterListResults) in results {
            var state = filterListStates[resourceType] ?? FilterListState(loadState: .notLoaded, downloadState: .notDownloaded)
            
            if let downloadResult = filterListResults[filterListWrapper.filterList.uuid] {
              // We have a result that means it's downloaded, let's set it
              switch downloadResult.result {
              case .success:
                state.downloadState = .downloaded(downloadResult.date)
              case .failure(let error):
                state.downloadState = .error(error)
              }
            } else {
              // We have a result that means it's not downloaded
              state.downloadState = .notDownloaded
            }
            
            filterListStates[resourceType] = state
          }
          
          self.filterListStates[filterListWrapper.filterList.uuid] = filterListStates
        }
      }
    
    // Subscribe to changes on the filter list states
    filterListSubscription = $filterListWrappers
      .receive(on: DispatchQueue.main)
      .sink { filterListWrappers in
        for filterListWrapper in filterListWrappers {
          self.handleUpdate(to: filterListWrapper)
        }
      }
    
    // Start the publisher so it starts downloading files
    publisher.start(enabledFilterLists: filterListWrappers.compactMap({ filterListWrapper in
      guard filterListWrapper.isEnabled else { return nil }
      return filterListWrapper.filterList
    }))
    
    // Start the timer that listens to changes to filter list states
    self.timer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(invokeTimer), userInfo: nil, repeats: true)
    invokeTimer()
  }
  
  func state(for filterList: FilterList, resourceType: FilterListResourcePublisher.ResourceType) -> FilterListState? {
    return filterListStates[filterList.uuid]?[resourceType]
  }
  
  /// Ensures settings are saved for the given filter list and that our publisher is aware of the changes
  private func handleUpdate(to filterListWrapper: FilterListWrapper) {
    assertIsMainThread("Not main thread")
    
    if let index = filterListSettings.firstIndex(where: { $0.uuid == filterListWrapper.filterList.uuid }) {
      guard filterListSettings[index].isEnabled != filterListWrapper.isEnabled else {
        // Ensure we stop if this is already in sync in order to avoid an event loop
        // And things hangning for too long.
        // This happens because we care about UI changes but not when our downloads finish
        return
      }
      
      filterListSettings[index].isEnabled = filterListWrapper.isEnabled
      filterListSettings[index].save()
    } else {
      let filterListSetting = FilterListSetting.create(
        forUUID: filterListWrapper.filterList.uuid,
        isEnabled: filterListWrapper.isEnabled
      )
      filterListSettings.append(filterListSetting)
    }
    
    publisher.enable(filterList: filterListWrapper.filterList, isEnabled: filterListWrapper.isEnabled)
  }

  @objc private func invokeTimer() {
    assertIsMainThread("Not main thread")
    FilterListResourcePublisher.ResourceType.allCases.forEach { resourceType in
      reloadAdBlockers(for: resourceType)
    }
  }
  
  private func reloadAdBlockers(for resourceType: FilterListResourcePublisher.ResourceType) {
    assertIsMainThread("Not main thread")
    guard loadDataTasks[resourceType] == nil else { return }
    
    // First check if anything needs a reload
    guard filterListWrappers.contains(where: { filterListWrapper in
      guard let state = filterListStates[filterListWrapper.filterList.uuid]?[resourceType] else {
        assertionFailure("States for all filter lists should have been created at `start()`")
        return false
      }
      
      return state.needsReload(isEnabled: filterListWrapper.isEnabled)
    }) else {
      return
    }
    
    // Get the filter states that need to be loaded
    let filterListWrappers = self.filterListWrappers.filter({ filterListWrapper in
      guard let state = filterListStates[filterListWrapper.filterList.uuid]?[resourceType] else {
        assertionFailure("States for all filter lists should have been created at `start()`")
        return false
      }
      
      return state.needsLoad(isEnabled: filterListWrapper.isEnabled)
    })
  
    loadDataTasks[resourceType] = Task.detached(priority: .background) {
      let reloadResults = await self.reloadData(for: resourceType, with: filterListWrappers)
      await self.updateLoadStates(for: resourceType, loadResults: reloadResults)
      await self.removeLoadDataTask(for: resourceType)
    }
  }
  
  @MainActor private func removeLoadDataTask(for resourceType: FilterListResourcePublisher.ResourceType) {
    assertIsMainThread("Not main thread")
    loadDataTasks.removeValue(forKey: resourceType)
  }
  
  /// Set the `filterListEngine` to `AdBlockStats` on the `MainActor`
  @MainActor private func set(filterListsEngine: AdblockEngine) {
    assertIsMainThread("Not on main thread")
    AdBlockStats.shared.set(filterListsEngine: filterListsEngine)
  }
  
  /// Process download and load results for the resource and mark syncronizing as false on the `MainActor`
  @MainActor private func updateLoadStates(
    for resourceType: FilterListResourcePublisher.ResourceType,
    loadResults: [String: Result<Bool, Error>]
  ) {
    assertIsMainThread("Not main thread")
    
    for filterListWrapper in filterListWrappers {
      var filterListStates = self.filterListStates[filterListWrapper.filterList.uuid] ?? [:]
      var state = filterListStates[resourceType] ?? FilterListState(loadState: .notLoaded, downloadState: .notDownloaded)
          
      if let loadResult = loadResults[filterListWrapper.filterList.uuid] {
        switch loadResult {
        case .success(let isLoaded):
          state.loadState = isLoaded ? .loaded : .notLoaded
        case .failure(let error):
          state.loadState = .error(error)
        }
      } else {
        state.loadState = .notLoaded
      }
      
      filterListStates[resourceType] = state
      self.filterListStates[filterListWrapper.filterList.uuid] = filterListStates
    }
  }
  
  /// Reload the data for the given resource type and filter list states.
  /// This does things like loads the engine, or
  private func reloadData(
    for resourceType: FilterListResourcePublisher.ResourceType,
    with filterListWrappers: [FilterListWrapper]
  ) async -> [String: Result<Bool, Error>] {
    switch resourceType {
    case .contentBlockingBehaviors:
      return await loadContentBlockingData(for: filterListWrappers)
    case .filterRules:
      let enabledFilterLists = filterListWrappers.map({ $0.filterList })
      let engineResults = await self.loadFilterListEngineData(for: enabledFilterLists)
      await set(filterListsEngine: engineResults.engine)
      return engineResults.loadResults
    }
  }
  
  /// Create and engine and load the filter list data into the engine
  private func loadFilterListEngineData(for filterLists: [FilterList]) async -> (engine: AdblockEngine, loadResults: [String: Result<Bool, Error>]) {
    let engine = AdblockEngine()
    
    return await withCheckedContinuation({ continuation in
      self.engineSerialQueue.async {
        var loadResults: [String: Result<Bool, Error>] = [:]
        
        for filterList in filterLists {
          do {
            guard let data = try FilterListResourcePublisher.dataForResource(for: filterList, resourceType: .filterRules) else {
              loadResults[filterList.uuid] = .success(false)
              continue
            }
            
            guard engine.deserialize(data: data) else {
              log.error("Failed to process engine data for filter list `\(filterList.uuid)`")
              // TODO: @JS This should be a failure
              loadResults[filterList.uuid] = .success(false)
              continue
            }
            
            loadResults[filterList.uuid] = .success(true)
          } catch {
            log.error(error)
            loadResults[filterList.uuid] = .failure(error)
          }
        }
        
        continuation.resume(returning: (engine, loadResults))
      }
    })
  }
  
  /// Load content blocking behaviors into the block-lists
  private func loadContentBlockingData(for filterListWrappers: [FilterListWrapper]) async -> [String: Result<Bool, Error>] {
    return await withTaskGroup(of: (filterList: FilterList, result: Result<Bool, Error>).self) { group in
      for filterListWrapper in filterListWrappers {
        group.addTask {
          do {
            guard let data = try FilterListResourcePublisher.dataForResource(for: filterListWrapper.filterList, resourceType: .contentBlockingBehaviors) else {
              return (filterListWrapper.filterList, .success(false))
            }
            
            try await filterListWrapper.makeBlocklistName().compile(data: data)
            return (filterListWrapper.filterList, .success(true))
          } catch {
            log.error(error)
            return (filterListWrapper.filterList, .failure(error))
          }
        }
      }
      
      var results: [String: Result<Bool, Error>] = [:]
      
      for await result in group {
        results[result.filterList.uuid] = result.result
      }
      
      return results
    }
  }
}
