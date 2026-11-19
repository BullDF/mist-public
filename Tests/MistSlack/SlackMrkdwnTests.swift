import Foundation

enum SlackMrkdwnTests {
    static func run() {
        for (input, expected) in [
            ("Hi <@U123> <@W123> <@U999> <@W999>", "Hi @Manju Rao @Wendy @U999 @W999"),
            ("<@U123|label> <@W123|other>", "@label @other"),
            ("<#C123> <#C999> <#C123|named>", "#general #C999 #named"),
            ("<!here> <!channel> <!everyone>", "@here @channel @everyone"),
            ("<!subteam^S123|@team> <!subteam^S999>", "@team @S999"),
            ("<https://example.com/path?q=1|Read more>", "[Read more](https://example.com/path?q=1)"),
            ("<tag> <@X123> <#D123> <!unknown> <https://example.com>", "<tag> <@X123> <#D123> <!unknown> <https://example.com>"),
            ("👋 **<@U123>** & <#C123>", "👋 **@Manju Rao** & #general")
        ] {
            let resolved = SlackMrkdwn.resolvingMentions(input, user: { ["U123": "Manju Rao", "W123": "Wendy"][$0] }, channel: { $0 == "C123" ? "#general" : nil })
            precondition(resolved == expected, "mention resolution failed: \(input)")
            precondition(!SlackMrkdwn.convert(resolved).contains("<@") && !SlackMrkdwn.convert(resolved).contains("<!"))
        }
        for (input, expected) in [
            ("**bold** __bold__ *italic* _italic_ ***both*** ~~gone~~", "*bold* *bold* _italic_ _italic_ *_both_* ~gone~"),
            ("snake_case_name 2*3*4", "snake_case_name 2*3*4"),
            ("& <tag> >", "&amp; &lt;tag&gt; &gt;"),
            ("[text](https://a) ![alt](https://b) <https://c> https://d", "<https://a|text> <https://b|alt> <https://c> https://d"),
            ("`**x** &`", "`**x** &amp;`"),
            ("~~~swift\n**x** <&>\n~~~", "```\n**x** &lt;&amp;&gt;\n```"),
            ("```js\nx\n```", "```\nx\n```"),
            ("# **Title**\n###### Last", "*Title*\n*Last*"),
            ("- one\n  + two\n* three\n- [ ] task\n- [x] done\n1. same", "• one\n    • two\n• three\n☐ task\n☑ done\n1. same"),
            ("> **quote**\n---\n***\n___", "> *quote*\n──────────\n──────────\n──────────"),
            ("- one\n    - two\n        - three", "• one\n    • two\n        • three"),
            ("| A |\n|---|\n| B |", "```\nA\nB\n```"),
            ("| A | B |\n|---|---|\n| **long** | x |", "```\nA    | B\nlong | x\n```")
        ] { precondition(SlackMrkdwn.convert(input) == expected, "mrkdwn rule failed: \(input)") }
        for input in ["one\n\ntwo\n\nthree", String(repeating: "x", count: 200), "```swift\n" + String(repeating: "line\n", count: 40) + "```"] {
            let chunks = SlackMrkdwn.chunks(input, limit: 32)
            precondition(!chunks.isEmpty && chunks.allSatisfy { !$0.isEmpty && $0.count <= 32 })
            if input.hasPrefix("```") { precondition(chunks.allSatisfy { $0.hasPrefix("```\n") && $0.hasSuffix("\n```") }) }
        }
        precondition(SlackMrkdwn.chunks(" \n ").isEmpty)
        precondition(SlackMrkdwn.chunks("one\n\ntwo", limit: 16) == ["one\n\ntwo"])
        precondition(SlackMrkdwn.chunks(String(repeating: "x", count: 16), limit: 16).count == 1)
        let longCode = SlackMrkdwn.chunks("```\n" + String(repeating: "x", count: 200) + "\n```", limit: 32)
        precondition(longCode.allSatisfy { $0.count <= 32 && $0.hasPrefix("```\n") && $0.hasSuffix("\n```") && $0 != "```\n```" })
    }
}
