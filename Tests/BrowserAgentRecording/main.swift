import CoreGraphics
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

typealias Geometry = BrowserAgentRecordingGeometry
typealias Timeline = BrowserAgentRecordingTimeline

check(Geometry.captureSize(viewport: CGSize(width: 1440, height: 900), scale: 2) == CGSize(width: 2880, height: 1800), "Keeps Retina viewport pixels")
check(Geometry.captureSize(viewport: CGSize(width: 2400, height: 1350), scale: 2) == CGSize(width: 3840, height: 2160), "Caps at 4K")
check(Geometry.captureSize(viewport: CGSize(width: 1400, height: 1200), scale: 2) == CGSize(width: 2520, height: 2160), "Fits tall viewports to the height limit")
check(Geometry.evenSize(CGSize(width: 1441, height: 901)) == CGSize(width: 1440, height: 900), "Rounds odd dimensions down")
let output = CGSize(width: 800, height: 600)
check(Geometry.aspectFit(CGSize(width: 200, height: 400), in: output) == CGRect(x: 250, y: 0, width: 300, height: 600), "Centers a tall frame")
check(Geometry.aspectFit(CGSize(width: 1600, height: 800), in: output) == CGRect(x: 0, y: 100, width: 800, height: 400), "Centers a wide frame")
check(Geometry.framePoint(CGPoint(x: 30, y: 40), frame: output, device: CGSize(width: 400, height: 200))
    == CGPoint(x: 60, y: 120), "Maps widget CSS points into frame pixels")

var timeline = Timeline()
check(timeline.pointer == nil && timeline.presentation(at: 10) == nil, "No initial pointer or frame")
timeline.pageFrame(at: 10)
check(timeline.presentation(at: 10.25) == 0, "The first compose starts at zero")
timeline.didAppend(at: 0)
check(timeline.presentation(at: 10.5) == nil, "Static page needs no frames")
timeline.pageFrame(at: 10.5)
check(timeline.presentation(at: 10.5) == 30_000, "Page changes compose at the next tick")
timeline.didAppend(at: 30_000)
timeline.pointer(.move, at: CGPoint(x: 12, y: 15), time: 10.5)
check(timeline.presentation(at: 10.5) == nil, "Presentation time must increase")
check(timeline.presentation(at: 10.75) == 45_000, "A rejected tick keeps the pointer change pending")
timeline.didAppend(at: 45_000)
timeline.pointer(.move, at: CGPoint(x: 12, y: 15), time: 10.75)
check(timeline.presentation(at: 11) == nil, "Repeated coordinates need no frame")

timeline.pointer(.click, at: CGPoint(x: 30, y: 40), time: 11)
check(timeline.pointer == CGPoint(x: 30, y: 40), "A click places the pointer")
let ripple = timeline.ripples[0]
check(ripple.appearance(at: 11)?.radius == 6 && ripple.appearance(at: 11)?.opacity == 0.9, "Initial ring")
if let half = ripple.appearance(at: 11.225) {
    check(abs(half.radius - 15) < 0.0001 && abs(half.opacity - 0.45) < 0.0001, "Halfway ring")
} else { fatalError("Missing halfway ring") }
check(ripple.appearance(at: 11.451) == nil, "Ring expires after 450 ms")
timeline.pointer(.click, at: CGPoint(x: 35, y: 45), time: 11.25)
check(timeline.ripples.count == 2, "Click rings can overlap")
check(timeline.presentation(at: 11.5) == 90_000 && timeline.ripples.count == 1, "Active ring animates")
timeline.didAppend(at: 90_000)
check(timeline.presentation(at: 11.75) == 105_000 && timeline.ripples.isEmpty, "The last ring leaves one clearing frame")
timeline.didAppend(at: 105_000)
check(timeline.presentation(at: 12) == nil, "Composition idles after the clearing frame")
check(timeline.finishPresentation(at: 13) == 180_000, "A static ending still lasts until stop")
check(timeline.finishPresentation(at: 11.75) == 105_001, "The tail never reuses a presentation time")

let frameTick = 1 / Double(Timeline.timeScale)
check(Timeline.stillTimes(duration: 9, frameCount: 10) == [0, 3, 6, 9 - frameTick], "Four evenly spaced stills, ending inside the track")
check(Timeline.stillTimes(duration: 9, frameCount: 3) == [0, 4.5, 9 - frameTick], "Three source frames yield at most three stills")
check(Timeline.stillTimes(duration: 9, frameCount: 1) == [0], "One source frame yields one still")
check(Timeline.stillTimes(duration: 9, frameCount: 0).isEmpty, "No stills without frames")
check(Timeline.stillTimes(duration: 0, frameCount: 4).isEmpty, "No stills in an empty track")

print("Browser agent recording timeline passed")
