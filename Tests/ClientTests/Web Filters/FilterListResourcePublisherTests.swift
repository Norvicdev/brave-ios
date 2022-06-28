//
//  FilterListResourcePublisherTests.swift
//  
//
//  Created by Jacob on 2022-07-23.
//

import XCTest
import Combine
@testable import Brave

class FilterListResourcePublisherTests: XCTestCase {
  /// The download subscription to the publisher
  private var downloadSubscription: AnyCancellable?
  
  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.
  }
  
  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }
  
  func testStart() throws {
    // Given
    let filterLists = Array(FilterListResourcePublisher.loadFilterLists()[...1])
    let manager = makeNetworkManager(filterLists: filterLists)
    let publisher = FilterListResourcePublisher(networkManager: manager)
    
    let expectation = XCTestExpectation(description: "Test downloading resources")
    
    Task {
      // Then
      downloadSubscription = publisher.$resourceDownloadResults
        .receive(on: DispatchQueue.main)
        .sink { results in
          guard results[.filterRules]?.count == filterLists.count && results[.contentBlockingBehaviors]?.count == filterLists.count else {
            // Wait till all the resuls are received
            return
          }
          
          for filterList in filterLists {
            switch results[.filterRules]?[filterList.uuid]?.result {
            case .failure(let error):
              // This is a success because or data for `.filterRules` is empty
              guard let error = error as? ResourceDownloader.DownloadResultError else {
                XCTFail("Error should be of type `ResourceDownloader.DownloadResultError`")
                return
              }
              
              XCTAssertEqual(error, .noData)
            case .success:
              XCTFail("Should be a failure because our data for `.filterRules` is empty")
            case .none:
              XCTFail("Our count check above should guarantee this doesn't trigger")
            }
            
            switch results[.contentBlockingBehaviors]?[filterList.uuid]?.result {
            case .success(let url):
              // This is a success because or data for `.contentBlockingBehaviors` is not empty
              let resource = FilterListResourcePublisher.ResourceType.contentBlockingBehaviors.downloadResource(for: filterList)
              // Our file should have been saved and the resulting url should be the saved file url
              XCTAssertEqual(url, ResourceDownloader.downloadedFileURL(for: resource))
            case .failure:
              XCTFail("Should be a success because our data for `.contentBlockingBehaviors` is not empty")
            case .none:
              XCTFail("Our count check above should guarantee this doesn't trigger")
            }
          }
          
          expectation.fulfill()
        }
      
      
      // When
      publisher.start(enabledFilterLists: filterLists)
    }
    
    wait(for: [expectation], timeout: 5)
    self.downloadSubscription?.cancel()
    self.downloadSubscription = nil
  }
  
  private func makeNetworkManager(filterLists: [FilterList], statusCode: Int = 200, etag: String? = nil) -> NetworkManager {
    let session = BaseMockNetworkSession { url in
      var foundFilterList: FilterList?
      var foundResourceType: FilterListResourcePublisher.ResourceType?
      
      for filterList in filterLists {
        guard let resourceType = FilterListResourcePublisher.ResourceType.allCases.first(where: { resourceType in
          let resource = resourceType.downloadResource(for: filterList)
          return url.absoluteURL == ResourceDownloader.externalURL(for: resource).absoluteURL
        }) else { continue }
        
        foundFilterList = filterList
        foundResourceType = resourceType
        break
      }
      
      guard let filterList = foundFilterList, let resourceType = foundResourceType else {
        throw "Resource type or filter list not found"
      }
      
      let resource = resourceType.downloadResource(for: filterList)
      let data = try await self.data(for: resourceType)
      
      let response = ResourceDownloader.getMockResponse(
        for: resource,
        statusCode: statusCode,
        headerFields: etag != nil ? ["Etag": etag!] : nil
      )
      
      return (data, response)
    }
    
    return NetworkManager(session: session)
  }
  
  private func data(for resourceType: FilterListResourcePublisher.ResourceType) async throws -> Data {
    try await Task<Data, Error>.detached(priority: .background) {
      switch resourceType {
      case .contentBlockingBehaviors:
        let bundle = Bundle.module
        let resourceURL = bundle.url(forResource: "content-blocking", withExtension: "json")
        let data = try Data(contentsOf: resourceURL!)
        return data
        
      case .filterRules:
        // Because of the retry timeout we don't throw any errors but return some empty data
        return Data()
      }
    }.value
  }
}
