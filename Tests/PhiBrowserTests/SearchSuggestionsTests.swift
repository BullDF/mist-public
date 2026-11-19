import XCTest
#if !SEARCH_SUGGESTIONS_HOSTLESS_TESTS
@testable import Phi
#endif

final class SearchSuggestionsTests: XCTestCase {
    func testEngineKeywords() {
        XCTAssertEqual(SearchSuggestionsEngine(keyword: "GOOGLE.COM"), .google)
        XCTAssertEqual(SearchSuggestionsEngine(keyword: "bing.com"), .bing)
        XCTAssertNil(SearchSuggestionsEngine(keyword: "example.com"))
    }

    func testURLsEncodeQueriesForBothEngines() throws {
        for engine in [SearchSuggestionsEngine.google, .bing] {
            for query in ["weather tor", "a&b", "café 東京", "a+b?#"] {
                let url = try XCTUnwrap(engine.suggestURL(query: query, language: "fr-CA"))
                let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let items = try XCTUnwrap(components.queryItems)
                XCTAssertEqual(items.first { $0.name == (engine == .google ? "q" : "query") }?.value, query)
                XCTAssertEqual(items.first { $0.name == (engine == .google ? "hl" : "language") }?.value, "fr-CA")
                XCTAssertEqual(components.host, engine == .google ? "suggestqueries.google.com" : "www.bing.com")
                XCTAssertEqual(components.path, engine == .google ? "/complete/search" : "/osjson.aspx")
                XCTAssertFalse(try XCTUnwrap(components.percentEncodedQuery).contains("+"), "a raw + reads as a space")
                if engine == .google {
                    XCTAssertEqual(items.first { $0.name == "client" }?.value, "chrome")
                    XCTAssertEqual(items.first { $0.name == "ie" }?.value, "utf-8")
                    XCTAssertEqual(items.first { $0.name == "oe" }?.value, "utf-8")
                }
                let results = try XCTUnwrap(engine.resultsURL(query: query))
                let resultComponents = try XCTUnwrap(URLComponents(url: results, resolvingAgainstBaseURL: false))
                XCTAssertEqual(resultComponents.host, "www.\(engine.rawValue)")
                XCTAssertEqual(resultComponents.path, "/search")
                XCTAssertEqual(resultComponents.queryItems, [URLQueryItem(name: "q", value: query)])
                XCTAssertFalse(try XCTUnwrap(resultComponents.percentEncodedQuery).contains("+"), "a raw + reads as a space")
            }
        }
    }

    func testParserTrimsAndDeduplicatesMixedEntries() {
        let data = Data(#"["q", [" first ", "", "FIRST", 42, null, {}, "second", "  "]]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data), SearchSuggestionsResult(texts: ["first", "second"]))
        XCTAssertEqual(SearchSuggestions.parse(Data(#"["q", ["one", "two"], [], {}]"#.utf8)),
                       SearchSuggestionsResult(texts: ["one", "two"]))
    }

    func testGoogleCalculatorAnswerIsSeparateFromSearchTexts() {
        let data = Data(#"["12*7",["= 84","12*70","12*700"],["Calculator","",""],[],{"google:suggestrelevance":[1250,601,600],"google:suggestsubtypes":[null,[512],[512]],"google:suggesttype":["CALCULATOR","QUERY","QUERY"],"google:verbatimrelevance":1300}]"#.utf8)
        let result = SearchSuggestions.parse(data)
        XCTAssertEqual(result.texts, ["12*70", "12*700"])
        XCTAssertEqual(result.answer?.text, "= 84")
        XCTAssertEqual(result.answer?.value, "84")
        XCTAssertEqual(result.answer?.kind, .calculation)
    }

    func testGoogleUnitConversionCopiesOnlyNumber() {
        let data = Data(#"["5 miles in km",["= 8.04672 kilometers"],["Calculator"],[],{"google:suggesttype":["CALCULATOR"]}]"#.utf8)
        let result = SearchSuggestions.parse(data)
        XCTAssertEqual(result.texts, [])
        XCTAssertEqual(result.answer?.text, "= 8.04672 kilometers")
        XCTAssertEqual(result.answer?.value, "8.04672")
        XCTAssertEqual(result.answer?.kind, .conversion)
    }

    func testGoogleNavigationAndTailEntriesAreDropped() {
        let data = Data(#"["youtu",["https://www.youtube.com/","youtube videos","videos","youtube"],[],{"google:suggesttype":["NAVIGATION","NAVIGATION_PERSONALIZED","TAIL","QUERY"]}]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data), SearchSuggestionsResult(texts: ["youtube"]))
    }

    func testGoogleScientificNotationAnswer() {
        let data = Data(#"["2^100",["= 1.2676506e30"],[],[],{"google:suggesttype":["CALCULATOR"]}]"#.utf8)
        let answer = SearchSuggestions.parse(data).answer
        XCTAssertEqual(answer?.text, "= 1.2676506e30")
        XCTAssertEqual(answer?.value, "1.2676506e30")
        XCTAssertEqual(answer?.kind, .calculation)
    }

    func testGoogleNonNumericAnswers() {
        for value in ["i", "undefined"] {
            let data = Data("[\"q\",[\"= \(value)\"],[],[],{\"google:suggesttype\":[\"CALCULATOR\"]}]".utf8)
            let answer = SearchSuggestions.parse(data).answer
            XCTAssertEqual(answer?.value, value)
            XCTAssertEqual(answer?.kind, .calculation)
        }
    }

    func testBingResponseKeepsAllTextsWithoutAnAnswer() {
        let data = Data(#"["q",["a","b","= 84"]]"#.utf8)
        XCTAssertEqual(SearchSuggestions.parse(data), SearchSuggestionsResult(texts: ["a", "b", "= 84"]))
    }

    func testAnswerParsingTrimsAndPreservesNumericForms() {
        for value in ["-8", "+8", "0.333333333", ".5", "-.5", "1E-10", "1e+10", "1000000000000"] {
            let answer = SearchAnswer(text: "  = \(value) \n")
            XCTAssertEqual(answer?.text, "= \(value)")
            XCTAssertEqual(answer?.value, value)
            XCTAssertEqual(answer?.kind, .calculation)
        }
        for unit in ["degrees Celsius", "ml"] {
            let answer = SearchAnswer(text: "= 37.7777778 \(unit)")
            XCTAssertEqual(answer?.value, "37.7777778")
            XCTAssertEqual(answer?.kind, .conversion)
        }
        for invalid in ["", "84", "=", " = \n"] {
            XCTAssertNil(SearchAnswer(text: invalid))
        }
    }

    func testOnlyFirstValidCalculatorEntryBecomesAnswer() {
        let data = Data(#"["q",["= ","84"," = 84 ","= 85","plain"],[],[],{"google:suggesttype":["CALCULATOR","CALCULATOR","CALCULATOR","CALCULATOR","QUERY"]}]"#.utf8)
        let result = SearchSuggestions.parse(data)
        XCTAssertEqual(result.answer?.value, "84")
        XCTAssertEqual(result.answer?.text, "= 84")
        XCTAssertEqual(result.texts, ["plain"])
    }

    func testMalformedResponses() {
        for json in ["invalid", "{}", "[]", #"["q"]"#, #"["q", {}]"#, #"[1, ["one"]]"#] {
            XCTAssertEqual(SearchSuggestions.parse(Data(json.utf8)), SearchSuggestionsResult(), json)
        }
    }
}
