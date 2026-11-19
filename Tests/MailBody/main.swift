import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { guard condition() else { fatalError(message) } }
let id = UUID()
let prepared = MailBodyPreparation.prepare(html: "<img src=\"cid:photo%40example\"><img src=\"https://example.com/pixel\">", text: nil, messageID: id)
check(prepared.html.contains("mist-mail-cid://" + id.uuidString.lowercased() + "/photo@example"), "cid rewrite")
check(prepared.isHTML && prepared.html.contains("<img src=\"https://example.com/pixel\">"), "html mode keeps remote images")
let plain = MailBodyPreparation.prepare(html: nil, text: "<script>& \"quoted\"\nhttps://example.com/a?x=1&y=2\nmailto:me@example.com", messageID: id)
check(!plain.isHTML, "plain mode")
check(plain.html.contains("&lt;script&gt;&amp; &quot;quoted&quot;"), "plain escaping")
check(plain.html.contains("href=\"https://example.com/a?x=1&amp;y=2\""), "escaped link")
check(!plain.html.contains("href=\"mailto:"), "no mailto action")
check(plain.html.contains("white-space:pre-wrap"), "plain wrapping")
// The reader insets the web view's left side to the header's text edge; the page pads its right side, where the
// overlay scroll bar draws, and a framed (dark-mode) page pads both.
check(prepared.html.contains("body{margin:20px 0;") && plain.html.contains("body{margin:20px 0}"), "body keeps only vertical margins")
check(prepared.html.contains("html{background:white;color:black;--mist-gutter:20px;padding:0 var(--mist-gutter) 0 0!important}"), "html pads its right side")
check(plain.html.contains("--mist-gutter:20px;padding:0 var(--mist-gutter) 0 0!important}"), "plain text pads its right side")
check(MailBodyPreparation.prepare(html: "<p>x</p>", text: nil, messageID: id, framed: true).html.contains("html{background:white;color:black;--mist-gutter:20px;padding:0 var(--mist-gutter) 0 var(--mist-gutter)!important}"), "framed page pads its sides")
check(MailBodyPreparation.prepare(html: "<p>x</p>", text: nil, messageID: id, gutter: 20 / 0.75).html.contains("--mist-gutter:26.667px;"), "zoomed gutter in CSS pixels")
check(MailBodyPreparation.cssPixels(40) == "40px" && MailBodyPreparation.cssPixels(12.5) == "12.5px", "CSS pixel formatting")
print("Mail body checks passed")
