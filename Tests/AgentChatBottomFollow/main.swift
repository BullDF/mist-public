import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let follow = AgentChatBottomFollow.self

// Any scroll up counts, however small; down, sideways and still don't.
check(follow.scrollsUp(deltaX: 0, deltaY: 0.5), "a tiny scroll up")
check(follow.scrollsUp(deltaX: 1, deltaY: 30), "a scroll up")
check(!follow.scrollsUp(deltaX: 0, deltaY: -3), "a scroll down")
check(!follow.scrollsUp(deltaX: 0, deltaY: 0), "no movement")
check(!follow.scrollsUp(deltaX: 12, deltaY: 2), "a sideways swipe")

// A live scroll above the bottom is the reader's, however small, unless it's a bounce or a settle at an earlier bottom.
check(follow.scrollsAway(y: 99, bottom: 100, overscrolled: false, earlierBottoms: [100]), "a tiny live scroll up")
check(!follow.scrollsAway(y: 100, bottom: 100, overscrolled: false, earlierBottoms: [100]), "at the bottom")
check(!follow.scrollsAway(y: 130, bottom: 100, overscrolled: false, earlierBottoms: [100]), "past the bottom")
check(!follow.scrollsAway(y: 80, bottom: 100, overscrolled: true, earlierBottoms: [60, 100]), "a bounce back from past the bottom")
check(!follow.scrollsAway(y: 60.5, bottom: 100, overscrolled: false, earlierBottoms: [60, 100]), "settling at the bottom before growth")
check(follow.scrollsAway(y: 57, bottom: 100, overscrolled: false, earlierBottoms: [60, 100]), "above an earlier bottom")

// Following tolerates its own drift near the bottom, and the slack of a live scroll settling during growth.
check(follow.follows(distance: 0, following: true), "at the bottom")
check(follow.follows(distance: 20, following: true), "drift within the tolerance")
check(!follow.follows(distance: 30, following: true), "past the tolerance")
check(follow.follows(distance: 300, following: true, slack: 290), "a live scroll settling at the bottom before the latest growth")

// Once the reader has scrolled away, only the bottom itself resumes following.
check(!follow.follows(distance: 10, following: false), "a short scroll up stays put")
check(!follow.follows(distance: 20, following: false, slack: 500), "slack is for following only")
check(follow.follows(distance: 0.5, following: false), "back at the bottom")
check(follow.follows(distance: -40, following: false), "overscrolled past the bottom")
print("Transcript follow tests passed")
