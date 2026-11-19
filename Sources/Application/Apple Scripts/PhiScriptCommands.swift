// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

enum PhiScriptCommandExecution {
    static func run(
        operation: @escaping @MainActor () -> [String: Any]
    ) -> String {
        let response: [String: Any]
        if Thread.isMainThread {
            response = MainActor.assumeIsolated(operation)
        } else {
            response = DispatchQueue.main.sync {
                MainActor.assumeIsolated(operation)
            }
        }
        return PhiScriptingJSON.string(from: response)
    }
}

private extension NSScriptCommand {
    func stringArgument(_ key: String) -> String? {
        evaluatedArguments?[key] as? String
    }

    func runPhiCommand(
        operation: @escaping @MainActor () -> [String: Any]
    ) -> String {
        PhiScriptCommandExecution.run(
            operation: operation
        )
    }
}

@objc(PhiListSpacesScriptCommand)
final class PhiListSpacesScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.listSpaces()
        }
    }
}

@objc(PhiListTabsScriptCommand)
final class PhiListTabsScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let scopeValue = stringArgument("scope")
        let spaceId = stringArgument("spaceId")
        return runPhiCommand {
            do {
                let scope = try PhiScriptingTabScope(scope: scopeValue, spaceId: spaceId)
                return PhiScriptingService.shared.listTabs(scope: scope)
            } catch {
                return [
                    "schemaVersion": PhiScriptingService.schemaVersion,
                    "ok": false,
                    "error": [
                        "code": PhiScriptingError.invalidArgument.code,
                        "message": PhiScriptingError.invalidArgument.message,
                    ],
                ]
            }
        }
    }
}

@objc(PhiGetActiveSpaceScriptCommand)
final class PhiGetActiveSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.getActiveSpace()
        }
    }
}

@objc(PhiActivateSpaceScriptCommand)
final class PhiActivateSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        return runPhiCommand {
            PhiScriptingService.shared.activateSpace(spaceId: spaceId)
        }
    }
}

@objc(PhiActivateTabScriptCommand)
final class PhiActivateTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand {
            PhiScriptingService.shared.activateTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiCloseTabScriptCommand)
final class PhiCloseTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand {
            PhiScriptingService.shared.closeTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiReloadTabScriptCommand)
final class PhiReloadTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand {
            PhiScriptingService.shared.reloadTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiForceReloadTabScriptCommand)
final class PhiForceReloadTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand {
            PhiScriptingService.shared.forceReloadTab(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiAddSplitViewScriptCommand)
final class PhiAddSplitViewScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let windowId = stringArgument("windowId")
        let tabId = stringArgument("tabId")
        return runPhiCommand {
            PhiScriptingService.shared.addSplitView(windowId: windowId, tabId: tabId)
        }
    }
}

@objc(PhiOpenPinnedTabScriptCommand)
final class PhiOpenPinnedTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        let pinnedTabId = stringArgument("pinnedTabId")
        return runPhiCommand {
            PhiScriptingService.shared.openPinnedTab(
                spaceId: spaceId,
                pinnedTabId: pinnedTabId
            )
        }
    }
}

@objc(PhiOpenBookmarkScriptCommand)
final class PhiOpenBookmarkScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let spaceId = stringArgument("spaceId")
        let bookmarkId = stringArgument("bookmarkId")
        return runPhiCommand {
            PhiScriptingService.shared.openBookmark(
                spaceId: spaceId,
                bookmarkId: bookmarkId
            )
        }
    }
}

@objc(PhiOpenTabScriptCommand)
final class PhiOpenTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let address = stringArgument("address")
        let spaceId = stringArgument("spaceId")
        return runPhiCommand {
            PhiScriptingService.shared.openTab(address: address, spaceId: spaceId)
        }
    }
}

@objc(PhiNewWindowScriptCommand)
final class PhiNewWindowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.newWindow()
        }
    }
}

@objc(PhiNewIncognitoWindowScriptCommand)
final class PhiNewIncognitoWindowScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.newIncognitoWindow()
        }
    }
}

@objc(PhiNewIncognitoSpaceScriptCommand)
final class PhiNewIncognitoSpaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.newIncognitoSpace()
        }
    }
}

@objc(PhiGetVersionScriptCommand)
final class PhiGetVersionScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.getVersion()
        }
    }
}

@objc(PhiGetChromiumDataDirectoryScriptCommand)
final class PhiGetChromiumDataDirectoryScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runPhiCommand {
            PhiScriptingService.shared.getChromiumDataDirectory()
        }
    }
}
