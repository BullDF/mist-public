// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox

/// Read-only system reservations. Symbolic hotkeys expose physical chords but
/// no action names, so all matches share an informational system owner.
enum SystemShortcutBindings {
    static func current(conflictingWith bindings: [ShortcutBinding]) -> [ShortcutBinding] {
        assert(Thread.isMainThread)
        var hotKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&hotKeys)
        let records = hotKeys?.takeRetainedValue() as? [[String: Any]]
        guard status == noErr, let records else {
            AppLogError("[SystemShortcutBindings] Failed to read system shortcuts (OSStatus \(status))")
            return []
        }
        return conflicts(with: bindings, records: records,
                         layout: SystemShortcutChordResolver.KeyboardLayout.current())
    }

    static func conflicts(
        with bindings: [ShortcutBinding],
        records: [[String: Any]],
        layout: SystemShortcutChordResolver.KeyboardLayout?
    ) -> [ShortcutBinding] {
        let enabled = Set(records.compactMap { record -> SystemShortcutChordResolver.Configuration? in
            guard record[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = record[kHISymbolicHotKeyCode as String] as? Int,
                  let rawModifiers = record[kHISymbolicHotKeyModifiers as String] as? Int,
                  let modifiers = UInt32(exactly: rawModifiers),
                  (0...127).contains(code) else { return nil }
            return .init(keyCode: UInt32(code), modifiers: modifiers)
        })
        guard !enabled.isEmpty else { return [] }
        return Set(bindings.filter { $0.owner != .system }.map(\.key)).compactMap { key in
            // Reuse the existing pure Carbon chord resolver, including layout,
            // shifted punctuation and physical aliases. Never register a hotkey.
            let chords = SystemShortcutChordResolver.configurations(for: key, isEnabled: true, layout: layout)
            guard chords.contains(where: enabled.contains) else { return nil }
            return ShortcutBinding(owner: .system, key: key, scope: .all, source: .system)
        }
    }
}

/// Resolves semantic shortcuts to physical Carbon chords without registering them.
enum SystemShortcutChordResolver {
    static let inputSourceDidChangeNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    struct Configuration: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// A snapshot of the current OS layout. Translation is injected in unit
    /// tests; production retains the system's Unicode layout data for the
    /// duration of resolution, including an IME's underlying keyboard layout.
    struct KeyboardLayout {
        let inputSourceIdentifier: String?
        let characters: (UInt16, NSEvent.ModifierFlags) -> String?

        static func current() -> KeyboardLayout? {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let fallback = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
            return load(source, fallback: fallback)
        }

        static func load(_ source: TISInputSource, fallback: TISInputSource? = nil) -> KeyboardLayout? {
            let identifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
                Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
            }
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                ?? fallback.flatMap({ TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let keyboardType = UInt32(LMGetKbdType())
            return KeyboardLayout(inputSourceIdentifier: identifier) { keyCode, flags in
                guard let bytes = CFDataGetBytePtr(data) else { return nil }
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                    carbonModifiers(flags) >> 8, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, characters.count, &length, &characters)
                guard result == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }

    static func configurations(
        for shortcut: ShortcutsKey?,
        isEnabled: Bool,
        layout: KeyboardLayout? = KeyboardLayout.current()
    ) -> [Configuration] {
        guard isEnabled,
              let shortcut,
              !shortcut.modifiers.contains(.function),
              shortcut.modifiers.subtracting(ShortcutsKey.supportedModifierFlags).isEmpty,
              !shortcut.modifiers.isEmpty,
              !(shortcut.modifiers == .shift && shortcut.isPrintableMenuCharacter) else {
            return []
        }

        if let keyCode = shortcut.carbonSpecialKeyCode {
            return [Configuration(keyCode: keyCode, modifiers: carbonModifiers(shortcut.modifiers))]
        }
        guard shortcut.isPrintableMenuCharacter, let layout else { return [] }

        // Shift is encoded in printable menu identities, including legacy '+'
        // bindings without an explicit Shift bit. Resolve both physical forms
        // through the same canonical/legacy matcher used by native dispatch.
        let unshifted = shortcut.modifiers.subtracting(.shift)
        let candidates = [unshifted, unshifted.union(.shift)]
        var matches: [Configuration: Int] = [:]
        for keyCode in UInt16(0)...UInt16(127) {
            for flags in candidates {
                let eventFlags = ShortcutsKey.isPrintableKeypadKeyCode(keyCode)
                    ? flags.union(.numericPad) : flags
                guard let semantic = layout.characters(keyCode, flags.intersection(.shift)),
                      let characters = layout.characters(keyCode, flags),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: eventFlags,
                          timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                          charactersIgnoringModifiers: semantic, isARepeat: false, keyCode: keyCode),
                      let rank = ShortcutsKey.eventKeys(for: event, inputSourceIdentifier: layout.inputSourceIdentifier)?
                        .matchingRank(for: shortcut) else { continue }
                let configuration = Configuration(keyCode: UInt32(keyCode), modifiers: carbonModifiers(flags))
                guard configuration.modifiers != 0 else { continue }
                matches[configuration] = min(matches[configuration] ?? rank, rank)
            }
        }
        // Preserve every physical alias of the canonical semantic identity.
        // Only use legacy layout candidates when no canonical candidate exists.
        guard let identityRank = matches.values.map({ $0 / 2 }).min() else { return [] }
        return matches.filter { $0.value / 2 == identityRank }.map(\.key).sorted {
            $0.keyCode == $1.keyCode ? $0.modifiers < $1.modifiers : $0.keyCode < $1.keyCode
        }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        return modifiers
    }

}
