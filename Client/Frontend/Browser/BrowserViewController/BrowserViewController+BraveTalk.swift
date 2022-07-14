// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import JitsiMeetSDK

extension BrowserViewController {
  func launchNativeBraveTalk(with options: JitsiMeetConferenceOptions) {
    jitsiMeetView = JitsiMeetView()
    jitsiMeetView?.delegate = self
    
    pipViewCoordinator = PiPViewCoordinator(withView: jitsiMeetView!)
    pipViewCoordinator?.configureAsStickyView()
    pipViewCoordinator?.delegate = self
    
    jitsiMeetView?.join(options)
    jitsiMeetView?.alpha = 0
    
    pipViewCoordinator?.show()
  }
}

extension BrowserViewController: JitsiMeetViewDelegate {
  func conferenceTerminated(_ data: [AnyHashable: Any]!) {
    dismiss(animated: true) { [self] in
      jitsiMeetView = nil
      pipViewCoordinator = nil
    }
  }
  
  func ready(toClose data: [AnyHashable: Any]!) {
    DispatchQueue.main.async { [self] in
      pipViewCoordinator?.hide() { [self] _ in
        jitsiMeetView?.removeFromSuperview()
      }
    }
  }
  
  func enterPicture(inPicture data: [AnyHashable: Any]!) {
    DispatchQueue.main.async { [self] in
      jitsiMeetView?.frame = view.window?.bounds ?? view.bounds
      isBraveTalkInPiPMode = true
      pipViewCoordinator?.enterPictureInPicture()
    }
  }
}

extension BrowserViewController: PiPViewCoordinatorDelegate {
  func exitPictureInPicture() {
    isBraveTalkInPiPMode = false
    jitsiMeetView?.frame = view.window?.bounds ?? view.bounds
  }
}
