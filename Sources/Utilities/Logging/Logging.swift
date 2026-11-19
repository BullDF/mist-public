// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CocoaLumberjack
import CocoaLumberjackSwift

private enum PhiLoggingInstallation {
    static var didInstall = false
}

/// Installs file + OS loggers once. Call `[PhiLoggingRuntime installSharedLogging]` from `main.m` before any Objective-C
/// `AppLog*` / `DDLog*`; `applicationWillFinishLaunching` also calls this as a fallback.
/// Repeat calls are no-ops so `DDFileLogger` is never torn down (which would roll the current file).
public func setupLogging() {
    if PhiLoggingInstallation.didInstall { return }

    let consoleLogger = DDOSLogger.sharedInstance
    consoleLogger.logFormatter = PhiLogFormatter()
    
    let fileManager = DDLogFileManagerDefault(logsDirectory: getLogsDirectory())
    let fileLogger = DDFileLogger(logFileManager: fileManager)
    fileLogger.rollingFrequency = -1 // Rotate by file size only.
    fileLogger.logFileManager.maximumNumberOfLogFiles = 7
    fileLogger.maximumFileSize = 5 * 1024 * 1024
    fileLogger.logFormatter = PhiLogFormatter()
    DDLog.add(fileLogger, with: .all)
    DDLog.add(consoleLogger, with: .all)
    PhiLoggingInstallation.didInstall = true
}

/// Entry point for Objective-C (`main.m`, Chromium launcher) so logging is installed before any `AppLog*`
/// or `DDLog*` calls. Swift global functions are not visible to ObjC; use this instead of calling
/// `setupLogging()` from `.m` files.
@objc(PhiLoggingRuntime)
public final class PhiLoggingRuntime: NSObject {
    @objc public static func installSharedLogging() {
        setupLogging()
    }
}

/// Returns the app log directory.
private func getLogsDirectory() -> String {
    let phiDataDir = FileSystemUtils.phiBrowserDataDirectory()
    return (phiDataDir as NSString)
        .appendingPathComponent("PhiLogs")
}

// MARK: - Public Logging Functions
public func AppLogInfo(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogInfo("\(logText())", file: file, function: function, line: line)
}

public func AppLogError(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogError("\(logText())", file: file, function: function, line: line)
}

public func AppLogWarn(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogWarn("\(logText())", file: file, function: function, line: line)
}

public func AppLogDebug(_ logText: @autoclosure() -> String, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
    DDLogDebug("\(logText())", file: file, function: function, line: line)
}
