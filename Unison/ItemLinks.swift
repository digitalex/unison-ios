import Foundation

/// Message text: inline markdown, with `#N` backlog item references as
/// links that open the item (#98 on the web, #102 here).
func richText(_ s: String, workspace: String?) -> AttributedString {
    var text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
    linkItems(in: &text, workspace: workspace)
    return text
}

/// Turns `#N` into `unison://open?item_id=N` links, by the web's rules: not
/// after a letter, digit, `_`, `&` or `/`, not followed by one, and not a
/// pull request ("PR #82", "pull request #82"). Code and links are left alone.
func linkItems(in text: inout AttributedString, workspace: String?) {
    let plain = String(text.characters)
    var links: [(Range<String.Index>, URL)] = []
    for match in plain.matches(of: #/#(\d{1,9})/#) {
        let hash = match.range.lowerBound
        if hash > plain.startIndex, isRefChar(plain[plain.index(before: hash)], extra: "&/") { continue }
        if match.range.upperBound < plain.endIndex, isRefChar(plain[match.range.upperBound], extra: "") { continue }
        let start = plain.index(hash, offsetBy: -16, limitedBy: plain.startIndex) ?? plain.startIndex
        let before = plain[start..<hash]
        if refersToPR(String(before)) { continue }
        var url = URLComponents()
        url.scheme = "unison"
        url.host = "open"
        url.queryItems = [URLQueryItem(name: "item_id", value: String(match.1))]
        if let workspace { url.queryItems?.append(URLQueryItem(name: "workspace_id", value: workspace)) }
        if let u = url.url { links.append((match.range, u)) }
    }
    for (range, url) in links {
        let offset = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let lower = text.index(text.startIndex, offsetByCharacters: offset)
        let upper = text.index(lower, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
        let run = text[lower..<upper]
        if run.runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
        text[lower..<upper].link = url
    }
}

/// Whether the text before a `#N` makes it a pull request, not a backlog item.
func refersToPR(_ before: String) -> Bool {
    before.firstMatch(of: #/(?i)\b(?:PRs?|pull(?: request)?s?)\s*$/#) != nil
}

private func isRefChar(_ c: Character, extra: String) -> Bool {
    c.isLetter || c.isNumber || c == "_" || extra.contains(c)
}
