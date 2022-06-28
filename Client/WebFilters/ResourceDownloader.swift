//
//  ResourceDownloader.swift
//  
//
//  Created by Jacob on 2022-07-18.
//

import Foundation
import Shared
import Combine

/// A ganeric resource downloader class that is responsible for fetching resources
class ResourceDownloader {
  enum Resource {
    /// Rules for debouncing links
    case debounceRules
    /// Generic filter rules for any locale
    case genericFilterRules
    /// Generic iOS only content blocking behaviours used for the iOS content blocker
    case genericContentBlockingBehaviors
    /// Cosmetic filter rules
    case generalCosmeticFilters
    /// Resources for cosmetic filters
    case generalScriptletResources
    /// Ad-block engine rules for a given filter list
    case filterRules(uuid: String, componentId: String)
    /// iOS only content blocking behaviours used for the iOS content blocker for a given filter list
    case contentBlockingBehaviors(uuid: String, componentId: String)
    
    /// The folder name under which this data should be saved under
    var cacheFolderName: String {
      switch self {
      case .debounceRules:
        return "debounce-data"
      case .contentBlockingBehaviors(_, let componentId), .filterRules(_, let componentId):
        return ["filter-lists", componentId].joined(separator: "/")
      case .genericFilterRules, .genericContentBlockingBehaviors:
        return "abp-data"
      case .generalCosmeticFilters, .generalScriptletResources:
        return "cmf-data"
      }
    }
    
    /// The name of the etag save into the cache folder
    fileprivate var etagFileName: String {
      return [cacheFileName, "etag"].joined(separator: ".")
    }
    
    /// Get the file name that is stored on the device
    var cacheFileName: String {
      switch self {
      case .debounceRules:
        return "ios-debouce.json"
      case .filterRules(let uuid, _):
        return "rs-\(uuid).dat"
      case .contentBlockingBehaviors(let uuid, _):
        return "\(uuid)-latest.json"
      case .genericFilterRules:
        return "rs-ABPFilterParserData.dat"
      case .genericContentBlockingBehaviors:
        return "latest.json"
      case .generalCosmeticFilters:
        return "ios-cosmetic-filters.dat"
      case .generalScriptletResources:
        return "scriptlet-resources.json"
        
      }
    }
    
    /// Get the external path for the given filter list and this resource type
    fileprivate var resourcePath: String {
      switch self {
      case .debounceRules:
        return "/ios/debounce.json"
      case .filterRules(let uuid, _):
        return "/4/rs-\(uuid).dat"
      case .contentBlockingBehaviors(let uuid, _):
        return "/ios/\(uuid)-latest.json"
      case .genericFilterRules:
        return "/4/rs-ABPFilterParserData.dat"
      case .genericContentBlockingBehaviors:
        return "/ios/latest.json"
      case .generalCosmeticFilters:
        return "/ios/ios-cosmetic-filters.dat"
      case .generalScriptletResources:
        return "/ios/scriptlet-resources.json"
      }
    }
  }
  
  /// An object representing errors with the resource downloader
  enum ResourceDownloaderError: Error {
    case failedToCreateCacheFolder
  }
  
  /// An object representing errors during a resource download
  enum DownloadResultError: Error {
    case noData
  }
  
  /// An object represening the download result
  enum DownloadResult<Result> {
    case notModified(URL, Date)
    case downloaded(Result, Date)
  }
  
  /// The base s3 environment url that hosts the debouncing (and other) files.
  /// Cannot be used as-is and must be combined with a path
  private static var baseResourceURL: URL = {
    if AppConstants.buildChannel.isPublic {
      return URL(string: "https://adblock-data.s3.brave.com")!
    } else {
      return URL(string: "https://adblock-data-staging.s3.bravesoftware.com")!
    }
  }()
  
  /// The directory to which we should store all the dowloaded files into
  private static var cacheFolderDirectory: FileManager.SearchPathDirectory {
    return FileManager.SearchPathDirectory.applicationSupportDirectory
  }
  
  /// The name of the info plist key that contains the service key
  private static let servicesKeyName = "SERVICES_KEY"
  /// The name of the header value that contains the service key
  private static let servicesKeyHeaderValue = "BraveServiceKey"
  /// The netowrk manager performing the requests
  private let networkManager: NetworkManager
  
  /// Initialize this class with the given network manager
  init(networkManager: NetworkManager = NetworkManager()) {
    self.networkManager = networkManager
  }
  
  /// Download the give resource type for the filter list and store it into the cache folder url
  @discardableResult
  func download(resource: Resource) async throws -> DownloadResult<URL> {
    let result = try await downloadInternal(resource: resource)
    
    switch result {
    case .downloaded(let networkResource, let date):
      // Clear any old data
      try Self.removeFile(for: resource)
      // Make a cache folder if needed
      let cacheFolderURL = try Self.getOrCreateCacheFolder(for: resource)
      // Save the data to file
      let fileURL = cacheFolderURL.appendingPathComponent(resource.cacheFileName)
      try Self.writeDataToDisk(data: networkResource.data, toFileURL: fileURL)
      // Save the etag to file
      if let data = networkResource.etag?.data(using: .utf8) {
        try Self.writeDataToDisk(
          data: data,
          toFileURL: cacheFolderURL.appendingPathComponent(resource.etagFileName)
        )
      }
      // Return the file URL
      return .downloaded(fileURL, date)
    case .notModified(let url, let date):
      return .notModified(url, date)
    }
  }
  
  private func downloadInternal(resource: Resource) async throws -> DownloadResult<CachedNetworkResource> {
    let url = Self.externalURL(for: resource)
    var headers = [String: String]()
    
    if let servicesKeyValue = Bundle.main.getPlistString(for: Self.servicesKeyName) {
      headers[Self.servicesKeyHeaderValue] = servicesKeyValue
    }
    
    let etag = try? Self.etag(for: resource)
    
    do {
      let networkResource = try await self.networkManager.downloadResource(
        with: url,
        resourceType: .cached(etag: etag),
        checkLastServerSideModification: !AppConstants.buildChannel.isPublic,
        customHeaders: headers)
      
      guard !networkResource.data.isEmpty else {
        throw DownloadResultError.noData
      }
      
      return .downloaded(networkResource, Date())
    } catch let error as String {
      if error == "File not modified", let fileURL = Self.downloadedFileURL(for: resource) {
        return .notModified(fileURL, Date())
      } else {
        throw error
      }
    }
  }
  
  /// Get or create a cache folder for the given `Resource`
  ///
  /// - Note: This technically can't really return nil as the location and folder are hard coded
  private static func getOrCreateCacheFolder(for resource: Resource) throws -> URL {
    guard let folderURL = FileManager.default.getOrCreateFolder(
      name: resource.cacheFolderName,
      location: Self.cacheFolderDirectory
    ) else {
      throw ResourceDownloaderError.failedToCreateCacheFolder
    }
    
    return folderURL
  }
  
  /// Load the data for the given `Resource` if it exists.
  ///
  /// - Note: Return nil if the data does not exist
  static func data(for resource: Resource) throws -> Data? {
    guard let fileUrl = downloadedFileURL(for: resource) else { return nil }
    return FileManager.default.contents(atPath: fileUrl.path)
  }
  
  /// Get the downloaded file URL for the filter list and resource type
  ///
  /// - Note: Returns nil if the file does not exist
  static func downloadedFileURL(for resource: Resource) -> URL? {
    guard let cacheFolderURL = createdCacheFolderURL(for: resource) else {
      return nil
    }
    
    let fileURL = cacheFolderURL.appendingPathComponent(resource.cacheFileName)
    
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return fileURL
    } else {
      return nil
    }
  }
  
  /// Get the external file url for the resource
  static func externalURL(for resource: Resource) -> URL {
    return URL(string: resource.resourcePath, relativeTo: Self.baseResourceURL)!
  }
  
  /// Get the file url for the downloaded file's etag
  ///
  /// - Note: Returns nil if the etag does not exist
  static func etagURL(for resource: Resource) -> URL? {
    guard let cacheFolderURL = createdCacheFolderURL(for: resource) else { return nil }
    let fileURL = cacheFolderURL.appendingPathComponent(resource.etagFileName)
    
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return fileURL
    } else {
      return nil
    }
  }
  
  /// Get an existing etag for the given `Resource`
  static func creationDate(for resource: Resource) throws -> Date? {
    guard let fileURL = downloadedFileURL(for: resource) else { return nil }
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return fileAttributes[.creationDate] as? Date
  }
  
  /// Get an existing etag for the given `Resource`
  static func etag(for resource: Resource) throws -> String? {
    guard let fileURL = etagURL(for: resource) else { return nil }
    guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
    return String(data: data, encoding: .utf8)
  }
  
  /// Get the cache folder for the given `Resource`
  ///
  /// - Note: Returns nil if the cache folder does not exist
  static func createdCacheFolderURL(for resource: Resource) -> URL? {
    guard let folderURL = cacheFolderDirectory.url else { return nil }
    let cacheFolderURL = folderURL.appendingPathComponent(resource.cacheFolderName)
    
    if FileManager.default.fileExists(atPath: cacheFolderURL.path) {
      return cacheFolderURL
    } else {
      return nil
    }
  }
  
  /// Removes all the data for the given `Resource`
  static func removeFile(for resource: Resource) throws {
    guard
      let fileURL = self.downloadedFileURL(for: resource)
    else {
      return
    }
    
    try FileManager.default.removeItem(atPath: fileURL.path)
  }

  /// Write the given `Data` to disk into to the specified file `URL`
  /// into the `applicationSupportDirectory` `SearchPathDirectory`.
  ///
  /// - Note: `fileName` must contain the full file name including the extension.
  private static func writeDataToDisk(data: Data, toFileURL fileURL: URL) throws {
    try data.write(to: fileURL, options: [.atomic])
  }
  
  /// Removes all the data for the given `Resource`
  private static func removeCacheFolder(for resource: Resource) throws {
    guard
      let folderURL = self.createdCacheFolderURL(for: resource)
    else {
      return
    }
    
    try FileManager.default.removeItem(atPath: folderURL.path)
  }
  
  #if DEBUG
  /// Convenience method for tests
  public static func getMockResponse(
    for resource: ResourceDownloader.Resource,
    statusCode code: Int = 200,
    headerFields: [String: String]? = nil
  ) -> HTTPURLResponse {
    let url = URL(string: resource.resourcePath, relativeTo: self.baseResourceURL)!
    
    return HTTPURLResponse(
      url: url, statusCode: code,
      httpVersion: "HTTP/1.1", headerFields: headerFields)!
  }
  #endif
}
