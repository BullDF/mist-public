// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// The sidebar surface a vertical Space switch animates on. Two surfaces
/// exist per window — the docked sidebar (`SidebarViewController`) and the
/// hover floating panel (`FloatingSidebarViewController`) — and
/// `SpaceWindowSlot` drives whichever one is presenting when the switch
/// fires (see `SpaceWindowSlot.spaceSwitchSurface(of:)`): the band slide
/// and the swipe edge bounce address the surface, not a concrete
/// controller.
///
/// Deliberately NOT annotated `@MainActor`: the nonisolated `SpaceWindowSlot`
/// drives these members synchronously (always on the main thread in
/// practice), exactly as it called the docked sidebar directly before this
/// protocol existed — an explicit annotation would make those calls hard
/// errors, while the NSViewController-inherited isolation of the conforming
/// controllers keeps the same checking the direct calls had.
protocol SpaceSwitchBandSurface: NSViewController {
    /// The views forming the contiguous per-Space content band — the
    /// pinned-tab strip and the tab list (which also hosts bookmarks).
    /// `SpaceManager` slides the entering surface's band in over the leaving
    /// surface's matching region during a vertical Space switch. The header (address bar) above and the bottom
    /// toolbar below are deliberately excluded so they stay put through the
    /// push. Views not currently mounted (incognito never mounts the pinned
    /// band) are skipped by the band-frame union.
    var spaceSwitchBandViews: [NSView] { get }

    /// The pinned-tab strip among `spaceSwitchBandViews`. It stays put
    /// through a switch between two Spaces that show the same pinned
    /// collection (`SpaceWindowSlot.HostedBandSlide`).
    var spaceSwitchPinnedStrip: NSView { get }

    /// The stack hosting the band. The slide and the edge bounce clip to it;
    /// the themed backdrop painted behind it shows through the slide.
    var spaceSwitchBandContainer: NSView { get }

    /// Forms the available native rows before a cold Space starts moving.
    func prepareSpaceSwitchBand(timing: SpaceSwitchTiming?)

    /// Ramps the surface's per-Space tint in lockstep with the push-in
    /// slide. The floating panel has no dedicated tint layer (its themed
    /// background follows the window theme ramp `performSwap` drives) and
    /// no-ops.
    func rampSpaceTint(fromHex: String?, toHex: String?, duration: TimeInterval)

    /// Hides everything this surface paints behind its band — the vibrancy
    /// material, the themed fill, the per-Space tint — leaving only the
    /// content. The live band slide (`SpaceWindowSlot.HostedBandSlide`)
    /// sets this on the ENTERING surface while its tree slides in over the
    /// leaving sidebar, so the leaving backdrop (ramping to the entering
    /// Space's colors) shows through it; a vibrancy view sliding in with its own
    /// material would instead blur whatever lies behind the window. Cleared
    /// again when the slide lands.
    func setSpaceSwitchBackdropHidden(_ hidden: Bool)

    /// The Spaces strip row's AppKit view — a `SpacesStripHostingView` when
    /// the strip is mounted, nil otherwise (incognito never mounts it). Both
    /// surfaces already expose it for the slot's pointer-vs-row test; the
    /// chip flight below rides the same reference.
    var spacesStripRowView: NSView? { get }
}

extension SpaceSwitchBandSurface {
    /// The band region in this surface's root view coordinate space.
    var spaceSwitchBandFrame: NSRect {
        let rects = spaceSwitchBandViews.compactMap { bandView -> NSRect? in
            guard bandView.superview != nil else { return nil }
            return view.convert(bandView.bounds, from: bandView)
        }
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Flies the strip's glass chip from the source pip to the target pip as
    /// an explicit CA layer animation, started with the switch's
    /// `activeSpaceId` flip — the one animation kind that keeps playing
    /// while the switch's synchronous session build blocks the main thread.
    /// The stand-in sweeps itself when it lands. False (zero side effects)
    /// when the strip isn't mounted or can't fly (see
    /// `SpacesStripHostingView.beginSpacesChipFlight`); the SwiftUI chip
    /// then keeps today's behavior.
    func beginSpacesChipFlight(fromSpaceId: String, toSpaceId: String,
                               pipCount: Int, duration: TimeInterval) -> Bool {
        guard let strip = spacesStripRowView as? SpacesStripHostingView else { return false }
        return strip.beginSpacesChipFlight(fromSpaceId: fromSpaceId,
                                           toSpaceId: toSpaceId,
                                           pipCount: pipCount,
                                           duration: duration)
    }

    /// Sweeps the chip flight while it is still heading for `toSpaceId` —
    /// run when that switch fails or is forced to settle, so the stand-in
    /// never keeps flying to a Space the slot has backed out of.
    func cancelSpacesChipFlight(toSpaceId: String) {
        (spacesStripRowView as? SpacesStripHostingView)?.cancelSpacesChipFlight(toSpaceId: toSpaceId)
    }

    /// Hides/reveals the live band content (the create-Space overlay hides
    /// it while the form is up; the band slide restores it when it ends).
    /// Uses alpha rather than `isHidden` so the stack layout — and the
    /// backdrop painted behind it — is unaffected.
    func setSwitchBandContentHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        for bandView in spaceSwitchBandViews {
            bandView.alphaValue = alpha
        }
    }

}
