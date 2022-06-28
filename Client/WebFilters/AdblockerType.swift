// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Shared

private let log = Logger.browserLogger

enum AdBlockResourceType {
  case generalFilterRules
  case generalContentBlockingBehaviors
  
  /// The bucket path to the external resource
  var externalPath: String? {
    switch self {
    case .generalFilterRules:
      return "/4/rs-ABPFilterParserData.dat"
    case .generalContentBlockingBehaviors:
      return "/ios/latest.json"
    }
  }
  
  /// A name under which given resource is stored locally in the app.
  var identifier: String {
    switch self {
    case .generalFilterRules, .generalContentBlockingBehaviors:
      return BlocklistName.ad.filename
    }
  }
}
