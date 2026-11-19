// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

class Account {
    let userID: String
    // FileSystemUtils isolates the whole account directory for test launches,
    // keeping the database and account defaults (including restore IDs) together.
    lazy var localStorage: LocalStore = LocalStore(account: self)
    private(set) lazy var userDefaults: AccountUserDefaults = {
        AccountUserDefaults(account: self)
    }()

    init(userID: String) {
        self.userID = userID
    }

    var userDataStorage: URL {
        let phiDataSupportURL = URL(filePath:  FileSystemUtils.phiBrowserDataDirectory())
        return phiDataSupportURL
            .appendingPathComponent("users")
            .appendingPathComponent(userID)
    }
}

final class AccountController {
    static let shared = AccountController()
    private static let defaultAccount = Account(userID: "default-account-id")
    let localDataAccount = AccountController.defaultAccount

    private init() {}
}
