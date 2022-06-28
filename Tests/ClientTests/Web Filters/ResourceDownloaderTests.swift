//
//  ResourceDownloaderTests.swift
//  
//
//  Created by Jacob on 2022-07-22.
//

import XCTest
@testable import Brave

class ResourceDownloaderTests: XCTestCase {
  func testSuccessfulResourceDownload() throws {
    // Given
    let expectation = XCTestExpectation(description: "Test downloading resources")
    let firstDownloader = makeDownloader(statusCode: 200, etag: "123")
    let secondDownloader = makeDownloader(statusCode: 304, etag: "123")
    
    Task {
      do {
        // When
        let result = try await firstDownloader.download(resource: .debounceRules)
        
        // Then
        // We get a download result
        switch result {
        case .downloaded:
          XCTAssertNotNil(try ResourceDownloader.data(for: .debounceRules))
          XCTAssertNotNil(try ResourceDownloader.etag(for: .debounceRules))
        case .notModified:
          XCTFail("Not modified recieved")
        }
      } catch {
        XCTFail(error.localizedDescription)
      }
      
      do {
        // When
        let result = try await secondDownloader.download(resource: .debounceRules)
        
        // Then
        // We get a not modified result
        switch result {
        case .downloaded:
          XCTFail("Not modified recieved")
        case .notModified:
          XCTAssertNotNil(try ResourceDownloader.data(for: .debounceRules))
          XCTAssertNotNil(try ResourceDownloader.etag(for: .debounceRules))
        }
      } catch {
        XCTFail(error.localizedDescription)
      }
      
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5)
  }
  
  func testFailedResourceDownload() throws {
    // Given
    let expectation = XCTestExpectation(description: "Test downloading resource")
    let downloader = makeDownloader(statusCode: 404)
    
    Task {
      do {
        // When
        _ = try await downloader.download(resource: .debounceRules)
        XCTFail("Should not succeed")
      } catch {
        // Then
        // We get an error
      }
      
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 5)
  }
  
  private func makeDownloader(for resources: [ResourceDownloader.Resource] = [.debounceRules], statusCode: Int = 200, etag: String? = nil) -> ResourceDownloader {
    let session = BaseMockNetworkSession { url in
      guard let resource = resources.first(where: { resource in
        url.absoluteURL == ResourceDownloader.externalURL(for: resource).absoluteURL
      }) else {
        throw "Resource not found"
      }
      
      let data = try await self.data(for: resource)
      
      let response = ResourceDownloader.getMockResponse(
        for: resource,
        statusCode: statusCode,
        headerFields: etag != nil ? ["Etag": etag!] : nil
      )
      
      return (data, response)
    }
    
    return ResourceDownloader(networkManager: NetworkManager(session: session))
  }
  
  private func data(for resource: ResourceDownloader.Resource) async throws -> Data {
    try await Task<Data, Error>.detached(priority: .background) {
      switch resource {
      case .debounceRules:
        let bundle = Bundle.module
        let resourceURL = bundle.url(forResource: "debouncing", withExtension: "json")
        let data = try Data(contentsOf: resourceURL!)
        return data
      default:
        // Because of the retry timeout we don't throw any errors but return some empty data
        return Data()
      }
    }.value
  }
}
