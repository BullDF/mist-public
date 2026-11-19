import Foundation

enum MistPasswordCSV {
    static func export(_ logins: [MistLogin]) -> String {
        func escape(_ field: String) -> String {
            guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        let rows = logins.sorted { ($0.host, $0.username) < ($1.host, $1.username) }.map { login in
            [login.host, login.site, login.username, login.password, ""].map(escape).joined(separator: ",")
        }
        return (["name,url,username,password,note"] + rows).joined(separator: "\r\n") + "\r\n"
    }

    struct Counts: Equatable {
        var imported = 0
        var updated = 0
        var skipped = 0
    }

    /// RFC 4180 state machine, including embedded CRLF and doubled quotes.
    static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = []
        var field = "", quoted = false, closedQuote = false
        let chars = Array(text.unicodeScalars)
        var i = chars.first == "\u{feff}" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.unicodeScalars.append(c) }
            } else if c == "," {
                row.append(field); field = ""; closedQuote = false
            } else if c == "\r" || c == "\n" {
                row.append(field); rows.append(row); row = []; field = ""; closedQuote = false
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else if c == "\"", field.isEmpty, !closedQuote {
                quoted = true
            } else {
                guard !closedQuote, c != "\"" else { throw MistPasswordError.invalidCSV }
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        guard !quoted else { throw MistPasswordError.invalidCSV }
        if !row.isEmpty || !field.isEmpty || closedQuote { row.append(field); rows.append(row) }
        return rows
    }

    static func logins(_ text: String) throws -> (logins: [MistLogin], skipped: Int) {
        let rows = try parse(text)
        guard let header = rows.first else { throw MistPasswordError.invalidCSV }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let url = names.firstIndex(of: "url"), let username = names.firstIndex(of: "username"),
              let password = names.firstIndex(of: "password") else { throw MistPasswordError.invalidCSV }
        var logins: [MistLogin] = [], skipped = 0
        for row in rows.dropFirst() {
            guard row.count > max(url, username, password),
                  let site = MistPasswordMatching.origin(row[url]), !row[password].isEmpty else {
                skipped += 1
                continue
            }
            logins.append(MistLogin(site: site, username: row[username], password: row[password]))
        }
        return (logins, skipped)
    }

    static func merge(_ incoming: [MistLogin], into existing: inout [MistLogin],
                      domain: (String) -> String, counts: Counts = Counts()) -> Counts {
        var counts = counts
        for login in incoming {
            let site = domain(login.site)
            guard !site.isEmpty else { counts.skipped += 1; continue }
            if let index = existing.firstIndex(where: { domain($0.site) == site && $0.username == login.username }) {
                // An insecure import must never downgrade an existing secure login.
                if existing[index].site.hasPrefix("https:"), login.site.hasPrefix("http:") {
                    counts.skipped += 1
                } else if existing[index].password == login.password {
                    counts.skipped += 1
                } else {
                    existing[index].password = login.password
                    existing[index].site = login.site
                    counts.updated += 1
                }
            } else {
                existing.append(login)
                counts.imported += 1
            }
        }
        return counts
    }
}
