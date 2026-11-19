// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa

extension BrowserState {
    /// Disable Phi's built-in extensions in every window. Deferred one runloop
    /// turn because Browser::Create has not yet registered its window controller;
    /// extension registry callbacks must wait until the window is addressable.
    func disablePhiExtensions() {
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?.disablePhiExtensions(false)
        }
    }
}
