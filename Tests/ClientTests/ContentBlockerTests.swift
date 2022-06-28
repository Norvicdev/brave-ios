// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import XCTest
import WebKit
import Combine
@testable import Brave

class ContentBlockerTests: XCTestCase {

  var store: WKContentRuleListStore!
  var contentBlocker: BlocklistName!
  let contentBlockerName = "test-content-blocker"

  override func setUp() {
    super.setUp()

    let testBundle = Bundle.module
    let bundleURL = testBundle.bundleURL
    store = WKContentRuleListStore(url: bundleURL)!

    let cleanStoreExpectation = expectation(description: "rule list setup")
    cleanStoreExpectation.isInverted = true

    contentBlocker = BlocklistName(filename: contentBlockerName)

    store.getAvailableContentRuleListIdentifiers { ids in
      if ids?.isEmpty == false {
        cleanStoreExpectation.fulfill()
      }
    }

    wait(for: [cleanStoreExpectation], timeout: 1)
  }

  override func tearDown() {
    let ruleListsRemoved = XCTestExpectation(description: "rule lists removed")

    var removedRuleLists: [XCTestExpectation] = []

    store.getAvailableContentRuleListIdentifiers { ids in
      guard let ids = ids else { return }

      ids.forEach { id in
        let idExpectation = self.expectation(description: "id: \(id)")

        removedRuleLists.append(idExpectation)

        self.store.removeContentRuleList(forIdentifier: id) { error in
          if error != nil { return }
          idExpectation.fulfill()

        }
      }

      ruleListsRemoved.fulfill()
    }

    wait(for: [ruleListsRemoved] + removedRuleLists, timeout: 2)

    super.tearDown()
  }

  func testCompilation() {
    let validJSON = """
      [{"trigger":{"url-filter":"-pubblicita300x275\\\\."},"action":{"type":"block"}}]
      """
    let data = validJSON.data(using: .utf8)!
    compile(data: data, expectSuccess: true)
  }

  func testCompilationFailure() {
    let invalidJSON = "badJson content rule"
    let data = invalidJSON.data(using: .utf8)!
    compile(data: data, expectSuccess: false)
  }

  private func compile(data: Data, expectSuccess: Bool) {
    let exp = XCTestExpectation(description: "compile")
    
    Task {
      do {
        try await contentBlocker.compile(data: data, ruleStore: self.store)
        
        if !expectSuccess {
          XCTFail("Expected error compiling content blocker rules")
        }
      } catch {
        if expectSuccess {
          XCTFail("Error compiling content blocker rules \(error)")
        }
      }
      exp.fulfill()
    }
    
    wait(for: [exp], timeout: 1)
    XCTAssert(true)
  }
}
