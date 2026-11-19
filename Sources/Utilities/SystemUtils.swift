// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SystemUtils {

    private static let osVersion = ProcessInfo.processInfo.operatingSystemVersion

    static func isRunningOnOrLater(major: Int, minor: Int = 0, patch: Int = 0) -> Bool {
        let current = osVersion
        if current.majorVersion != major { return current.majorVersion > major }
        if current.minorVersion != minor { return current.minorVersion > minor }
        return current.patchVersion >= patch
    }

    static var isMacOS26OrLater: Bool { isRunningOnOrLater(major: 26) }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

}
