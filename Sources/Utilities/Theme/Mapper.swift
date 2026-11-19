// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Resolves a value from the active theme and appearance.
public struct Mapper<V> {
    public let transform: (Theme, Appearance) -> V
    
    /// Returns the value for a specific theme and appearance.
    public subscript(_ theme: Theme, _ appearance: Appearance) -> V {
        transform(theme, appearance)
    }
    
    // MARK: - Initializers
    
    /// Creates a mapper from a custom transform.
    public init(_ transform: @escaping (Theme, Appearance) -> V) {
        self.transform = transform
    }
    
    /// Creates a mapper from a light and dark pair.
    public init(_ lightValue: V, _ darkValue: V) {
        self.init { _, appearance in
            appearance.isDark ? darkValue : lightValue
        }
    }
    
    /// Creates a mapper that always returns the same value.
    public init(_ value: V) {
        self.init { _, _ in value }
    }
    
    // MARK: - Transformations
    
    /// Maps the resolved value into a new type.
    public func map<T>(_ transform: @escaping (V) -> T) -> Mapper<T> {
        Mapper<T> { theme, appearance in
            transform(self.transform(theme, appearance))
        }
    }
    
    /// Wraps the resolved value in an optional.
    public var optional: Mapper<V?> {
        map { .some($0) }
    }
    
}

// MARK: - <> Operator

infix operator <>: AdditionPrecedence

/// Creates a mapper from a light and dark pair.
/// Use `.optional` when an optional mapper is required.
public func <> <V>(light: V, dark: V) -> Mapper<V> {
    Mapper(light, dark)
}

// MARK: - Color Specific Operators

/// Builds color mappers from `ColorConvertible` values.
public extension ColorConvertible {
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<NSColor?> {
        Mapper(lhs.asColor(), rhs.asColor()).optional
    }
    
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<CGColor?> {
        Mapper(lhs.asColor(), rhs.asColor()).map { $0.cgColor }.optional
    }
}

// MARK: - ThemedColor to Mapper Conversion

public extension ThemedColor {
    /// Converts the themed color into an `NSColor` mapper.
    var mapper: Mapper<NSColor> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance)
        }
    }
}
