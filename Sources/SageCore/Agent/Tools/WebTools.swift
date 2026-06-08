import Foundation

// MARK: - HTML → text

enum HTMLText {
    /// Crude but dependency-free HTML-to-text: drop script/style, strip tags,
    /// decode common entities, collapse whitespace. Good enough to feed a model.
    static func strip(_ html: String) -> String {
        var s = html
        for block in ["script", "style", "head", "noscript"] {
            s = s.replacingOccurrences(
                of: "<\(block)[^>]*>.*?</\(block)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - fetch_url

public struct FetchURLTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(
            name: "fetch_url",
            description: "Fetch a web page and return its readable text content (HTML stripped). Use after web_search to read a result.",
            parameters: [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "The full http(s) URL to fetch."]],
                "required": ["url"],
            ]
        )
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let raw = arguments["url"] as? String, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            throw ToolError.message("Provide a valid http(s) url.")
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh) Sage/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ToolError.message("HTTP \(http.statusCode) fetching \(raw).")
        }
        let html = String(decoding: data, as: UTF8.self)
        let text = HTMLText.strip(html)
        let header = "Source: \(raw)\n\n"
        let limit = 80_000
        return header + (text.count > limit ? String(text.prefix(limit)) + "\n… [truncated]" : text)
    }
}

// MARK: - Search provider seam

public struct SearchResult: Sendable {
    public let title: String
    public let url: String
    public let snippet: String
}

/// Pluggable search backend. The keyless DuckDuckGo scraper is the default; keyed
/// providers (Brave, Serp, …) conform and drop in without touching WebSearchTool.
public protocol SearchProvider: Sendable {
    func search(_ query: String) async throws -> [SearchResult]
}

/// Keyless default: scrapes the DuckDuckGo HTML endpoint. Lower quality than a keyed
/// API and may rate-limit, but needs no configuration.
public struct DuckDuckGoSearch: SearchProvider {
    public init() {}

    public func search(_ query: String) async throws -> [SearchResult] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Mozilla/5.0 (Macintosh) Sage/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        return Self.parse(html)
    }

    static func parse(_ html: String) -> [SearchResult] {
        var results: [SearchResult] = []
        // Each result anchor: <a ... class="result__a" href="HREF">TITLE</a>
        let pattern = #"result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let href = ns.substring(with: match.range(at: 1))
            let title = HTMLText.strip(ns.substring(with: match.range(at: 2)))
            results.append(SearchResult(title: title, url: cleanURL(href), snippet: ""))
            if results.count >= 8 { break }
        }
        return results
    }

    /// DuckDuckGo wraps results in a redirect: //duckduckgo.com/l/?uddg=<encoded>.
    static func cleanURL(_ href: String) -> String {
        guard href.contains("uddg="),
              let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return href.hasPrefix("//") ? "https:" + href : href }
        return target
    }
}

// MARK: - web_search

public struct WebSearchTool: Tool {
    let provider: any SearchProvider

    public init(provider: any SearchProvider = DuckDuckGoSearch()) {
        self.provider = provider
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: "Search the web and return a list of results (title + url). Follow up with fetch_url to read a page. Cite sources you use.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "The search query."]],
                "required": ["query"],
            ]
        )
    }

    public func run(arguments: [String: Any], context: ToolContext) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            throw ToolError.missingArgument("query")
        }
        let results = try await provider.search(query)
        if results.isEmpty { return "No results for \"\(query)\"." }
        return results.enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   \(r.url)"
        }.joined(separator: "\n")
    }
}
