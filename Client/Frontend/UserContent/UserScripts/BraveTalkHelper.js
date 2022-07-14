// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

'use strict';

Object.defineProperty(window.__firefox__, '$<brave-talk-helper>', {
    enumerable: false,
    configurable: true,
    writable: false,
    value: {
        id: 1,
        resolution_handlers: {},
        resolve(id, data, error) {
            if (error && window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].reject) {
                window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].reject(error);
            } else if (window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].resolve) {
                window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].resolve(data);
            } else if (window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].reject) {
                window.__firefox__.$<brave-talk-helper>.resolution_handlers[id].reject(new Error("Invalid Data!"));
            } else {
                console.log("Invalid Promise ID: ", id);
            }
            
            delete window.__firefox__.$<brave-talk-helper>.resolution_handlers[id];
        },
        sendMessage() {
            return new Promise((resolve, reject) => {
               window.__firefox__.$<brave-talk-helper>.resolution_handlers[1] = { resolve, reject };
               webkit.messageHandlers.BraveTalkHelper.postMessage({ 'securitytoken': '$<security_token>' });
           });
        }
    }
});

Object.defineProperty(window, 'chrome', {
  enumerable: false,
  configurable: true,
  writable: false,
  value: {
    braveRequestAdsEnabled() {
      return webkit.messageHandlers.BraveTalkHelper.postMessage({
        'kind': 'braveRequestAdsEnabled',
        'securitytoken': '$<security_token>'
      });
    }
  }
});

const launchNativeBraveTalk = (url) => {
  webkit.messageHandlers.BraveTalkHelper.postMessage({
    'kind': 'launchNativeBraveTalk',
    'url': url,
    'securitytoken': '$<security_token>'
  });
};

if (document.location.host === "talk.brave.com") {
  const postRoom = (event) => {
    if (event.target.tagName !== undefined && event.target.tagName.toLowerCase() == "iframe") {
      launchNativeBraveTalk(event.target.src);
      window.removeEventListener("DOMNodeInserted", postRoom)
    }
  };
  window.addEventListener("DOMNodeInserted", postRoom);
}
