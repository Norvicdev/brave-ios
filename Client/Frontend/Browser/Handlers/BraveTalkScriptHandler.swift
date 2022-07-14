// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import WebKit
import Shared
import BraveShared
import BraveCore
import JitsiMeetSDK

private let log = Logger.browserLogger

class BraveTalkScriptHandler: TabContentScript {
  private weak var tab: Tab?
  private weak var rewards: BraveRewards?
  private var rewardsEnabledReplyHandler: ((Any?, String?) -> Void)?
  private let launchNativeBraveTalk: (JitsiMeetConferenceOptions) -> Void

  required init(
    tab: Tab,
    rewards: BraveRewards,
    launchNativeBraveTalk: @escaping (JitsiMeetConferenceOptions) -> Void
  ) {
    self.tab = tab
    self.rewards = rewards
    self.launchNativeBraveTalk = launchNativeBraveTalk

    tab.rewardsEnabledCallback = { [weak self] success in
      self?.rewardsEnabledReplyHandler?(success, nil)
    }
  }

  static func name() -> String { "BraveTalkHelper" }

  func scriptMessageHandlerName() -> String? { BraveTalkScriptHandler.name() }

  private struct Payload: Decodable {
    enum Kind: Decodable {
      case braveRequestAdsEnabled
      case launchNativeBraveTalk(String)
    }
    var kind: Kind
    var securityToken: String
    
    enum CodingKeys: String, CodingKey {
      case kind
      case url
      case securityToken = "securitytoken"
    }
    
    init(from decoder: Decoder) throws {
      enum RawKindKey: String, Decodable {
        case braveRequestAdsEnabled
        case launchNativeBraveTalk
      }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let kind = try container.decode(RawKindKey.self, forKey: .kind)
      self.securityToken = try container.decode(String.self, forKey: .securityToken)
      switch kind {
      case .launchNativeBraveTalk:
        let url = try container.decode(String.self, forKey: .url)
        self.kind = .launchNativeBraveTalk(url)
      case .braveRequestAdsEnabled:
        self.kind = .braveRequestAdsEnabled
      }
    }
  }
  
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceiveScriptMessage message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    let allowedHosts = DomainUserScript.braveTalkHelper.associatedDomains

    guard let requestHost = message.frameInfo.request.url?.host,
      allowedHosts.contains(requestHost),
      message.frameInfo.isMainFrame
    else {
      log.error("Brave Talk request called from disallowed host")
      return
    }
    
    guard let json = try? JSONSerialization.data(withJSONObject: message.body, options: []),
          let payload = try? JSONDecoder().decode(Payload.self, from: json),
          payload.securityToken == UserScriptManager.securityTokenString else {
      return
    }

    switch payload.kind {
    case .braveRequestAdsEnabled:
      handleBraveRequestAdsEnabled(replyHandler)
    case .launchNativeBraveTalk(let url):
      guard let components = URLComponents(string: url),
            case let room = String(components.path.dropFirst(1)),
            let jwt = components.queryItems?.first(where: { $0.name == "jwt" })?.value
      else {
        return
      }
      launchNativeBraveTalk(.braveTalkOptions(room: room, token: jwt))
      // TODO: Determine if we want to stop the load, close the tab, etc.
      tab?.webView?.stopLoading()
      replyHandler(nil, nil)
    }
  }

  private func handleBraveRequestAdsEnabled(_ replyHandler: @escaping (Any?, String?) -> Void) {
    guard let rewards = rewards, !PrivateBrowsingManager.shared.isPrivateBrowsing else {
      replyHandler(false, nil)
      return
    }

    if rewards.isEnabled {
      replyHandler(true, nil)
      return
    }

    // If rewards are disabled we show a Rewards panel,
    // The `rewardsEnabledReplyHandler` will be called from other place.
    if let tab = tab {
      rewardsEnabledReplyHandler = replyHandler
      tab.tabDelegate?.showRequestRewardsPanel(tab)
    }
  }
}
