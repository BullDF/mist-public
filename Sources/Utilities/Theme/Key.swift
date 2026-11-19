// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Abstracts how a resolved value gets assigned to a target.
public protocol Key: Hashable {
    associatedtype Base
    associatedtype Value
    
    func set(_ base: Base, with value: Value)
}

// MARK: - ReferenceWritableKeyPath Extension

extension ReferenceWritableKeyPath: Key {
    public typealias Base = Root
    
    public func set(_ base: Base, with value: Value) {
        base[keyPath: self] = value
    }
}

// MARK: - VoidKey

/// Placeholder key used for pure subscriptions with no property assignment.
public final class VoidKey<Base: AnyObject>: NSObject, Key {
    public typealias Value = Void
    
    public func set(_ base: Base, with value: Void) {
        // Intentionally left blank.
    }
    
    override init() {
        super.init()
    }
}
