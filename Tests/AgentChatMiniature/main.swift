import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let plan = AgentChatMiniaturePlan.self

// A redraw waits for the interval since the last one and for input to go quiet, whichever is later.
check(plan.delay(sinceRender: .infinity, sinceInput: .infinity) == 0, "a first picture draws at once")
check(plan.delay(sinceRender: 0.5, sinceInput: 10) == 1.5, "a running child waits out the interval")
check(abs(plan.delay(sinceRender: 10, sinceInput: 0.1) - 0.3) < 1e-9, "scrolling or typing puts it off")
check(plan.delay(sinceRender: 1.9, sinceInput: 0) == 0.4, "the later of both")
check(abs(plan.delay(sinceRender: 10, sinceInput: 10, sinceAnyRender: 0.05) - 0.2) < 1e-9, "another card just drew")

// The covered height follows the body's shape, rounded up to steps that small size changes keep.
check(plan.sourceHeight(body: CGSize(width: 398, height: 249)) == 600, "a default card")
check(plan.sourceHeight(body: CGSize(width: 398, height: 250)) == 600, "a slightly taller card keeps its picture")
check(plan.sourceHeight(body: CGSize(width: 398, height: 500)) == 1100, "the tallest card")
check(plan.sourceHeight(body: .zero) == 0, "no body")

// A transcript that fits starts at the top; a longer one shows its end at the bottom.
let body = CGSize(width: 404, height: 300)
let short = plan.pictureFrame(rendered: 300, body: body)
check(short == CGRect(x: 0, y: 0, width: 404, height: 150), "a short transcript at the top")
let long = plan.pictureFrame(rendered: 700, body: body)
check(long == CGRect(x: 0, y: -50, width: 404, height: 350), "a long transcript's end at the bottom")
// A whole transcript within the rounded-up source height but taller than the body still shows its end.
let snugBody = CGSize(width: 404, height: 240)
check(plan.sourceHeight(body: snugBody) == 500, "the source height rounds 480 up")
check(plan.pictureFrame(rendered: 490, body: snugBody) == CGRect(x: 0, y: -5, width: 404, height: 245),
      "a whole transcript taller than the body ends at the bottom")

// Long messages keep their end from a line start; an open code fence above the cut opens again.
check(plan.tail("short", limit: 10, step: 5, markdown: true) == "short", "a short message stays whole")
let lines = (1...50).map { "line \($0)" }.joined(separator: "\n")
let kept = plan.tail(lines, limit: 45, step: 10, markdown: true)
check(kept.utf8.count <= 45 && kept.hasPrefix("line ") && kept.hasSuffix("line 50"), "cut at a line start: \(kept)")
// Streaming more text keeps the same start until the cut moves a whole step.
let grown = plan.tail(lines + "\nmore", limit: 45, step: 10, markdown: true)
check(grown.hasPrefix(String(kept.prefix(7))), "a streamed reply keeps its start within a step: \(grown)")
let fenced = "intro\n```swift\n" + (1...50).map { "let x\($0) = \($0)" }.joined(separator: "\n") + "\n```\nafter"
check(plan.tail(fenced, limit: 60, step: 10, markdown: true).hasPrefix("```\nlet x"), "an open fence reopens")
check(!plan.tail(fenced, limit: 60, step: 10, markdown: false).hasPrefix("```"), "plain text never gets a fence")
let closed = "```\ncode\n```\n" + (1...50).map { "text \($0)" }.joined(separator: "\n")
check(plan.tail(closed, limit: 40, step: 10, markdown: true).hasPrefix("text "), "a closed fence stays closed")
let line = plan.tail(String(repeating: "x", count: 100), limit: 40, step: 10, markdown: true)
check(line.count > 30 && line.count <= 40, "a single long line cuts mid-line")
check(plan.tail(String(repeating: "é", count: 100), limit: 41, step: 1, markdown: false).count == 20, "never inside a character")
print("Agent chat miniature tests passed")
