import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]  // lower-cased keys
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        var h = headers
        h.append(("Content-Type", "application/json; charset=utf-8"))
        return HTTPResponse(status: status, headers: h, body: JSON.data(value))
    }

    public static func text(_ text: String, status: Int = 200, headers: [(String, String)] = []) -> HTTPResponse {
        var h = headers
        h.append(("Content-Type", "text/plain; charset=utf-8"))
        return HTTPResponse(status: status, headers: h, body: Data(text.utf8))
    }

    public static func empty(_ status: Int, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    public var statusText: String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status \(status)"
        }
    }

    /// Serializes the response for HTTP/1.1.
    public func serialize(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var hasServer = false
        for (k, v) in headers {
            if k.lowercased() == "server" { hasServer = true }
            head += "\(k): \(v)\r\n"
        }
        if !hasServer { head += "Server: HealthBridge\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

public enum HTTPParseError: Error, Equatable {
    case malformedRequestLine
    case malformedHeader
    case headTooLarge
    case bodyTooLarge
    case lengthRequired
    case badChunk
}

/// Incremental HTTP/1.1 request parser. Feed bytes in; take complete requests out.
public struct HTTPRequestParser {
    public var maxHeadSize = 32 * 1024
    public var maxBodySize = 8 * 1024 * 1024

    private var buffer = Data()

    private enum State {
        case head
        case body(head: PartialHead, remaining: Int)
        case chunked(head: PartialHead, body: Data)
    }

    private struct PartialHead {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var expectsContinue: Bool
    }

    private var state: State = .head

    public init() {}

    public struct Output {
        public var requests: [HTTPRequest] = []
        /// True if the parser saw `Expect: 100-continue` on a request whose
        /// body has not fully arrived yet; the caller should send 100 Continue.
        public var needsContinue = false
    }

    public mutating func feed(_ data: Data) throws -> Output {
        buffer.append(data)
        // The decoded-body limit alone is not enough: raw bytes accumulate here while a chunk is
        // still arriving, so a single declared 500 MB chunk, or a chunk-size line with no CRLF,
        // would grow this without bound before any size check ran. Parsing happens before auth,
        // so any process able to open a loopback socket could exhaust memory.
        if buffer.count > maxBodySize + maxHeadSize { throw HTTPParseError.bodyTooLarge }
        var out = Output()
        while true {
            switch state {
            case .head:
                guard let headEnd = findHeadEnd() else {
                    if buffer.count > maxHeadSize { throw HTTPParseError.headTooLarge }
                    return out
                }
                let headData = buffer.subdata(in: 0..<headEnd)
                buffer.removeSubrange(0..<(headEnd + 4))
                let head = try parseHead(headData)
                let te = head.headers["transfer-encoding"]?.lowercased()
                if let te, te.contains("chunked") {
                    state = .chunked(head: head, body: Data())
                } else if let cl = head.headers["content-length"] {
                    guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                        throw HTTPParseError.malformedHeader
                    }
                    if n > maxBodySize { throw HTTPParseError.bodyTooLarge }
                    if n == 0 {
                        out.requests.append(makeRequest(head, body: Data()))
                        state = .head
                    } else {
                        state = .body(head: head, remaining: n)
                        if head.expectsContinue, buffer.count < n { out.needsContinue = true }
                    }
                } else {
                    if head.method == "POST" || head.method == "PUT" || head.method == "PATCH" {
                        throw HTTPParseError.lengthRequired
                    }
                    out.requests.append(makeRequest(head, body: Data()))
                    state = .head
                }
            case .body(let head, let remaining):
                guard buffer.count >= remaining else { return out }
                let body = buffer.subdata(in: 0..<remaining)
                buffer.removeSubrange(0..<remaining)
                out.requests.append(makeRequest(head, body: body))
                state = .head
            case .chunked(let head, var body):
                // Parse as many chunks as are complete.
                var progressed = false
                chunkLoop: while true {
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                        // No terminator yet. A chunk-size line is a handful of bytes; anything
                        // longer is malformed and must not be buffered indefinitely.
                        if buffer.count > 1024 { throw HTTPParseError.badChunk }
                        break
                    }
                    let sizeLine = String(decoding: buffer.subdata(in: 0..<lineEnd.lowerBound), as: UTF8.self)
                    let sizeHex = sizeLine.split(separator: ";").first.map(String.init) ?? ""
                    guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                        throw HTTPParseError.badChunk
                    }
                    if size == 0 {
                        // Trailer terminator: expect "\r\n" after the size line (ignore trailers).
                        guard let trailerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) ??
                            (buffer.count >= lineEnd.upperBound + 2 ? (lineEnd.upperBound..<(lineEnd.upperBound + 2)) : nil)
                        else { break chunkLoop }
                        buffer.removeSubrange(0..<trailerEnd.upperBound)
                        out.requests.append(makeRequest(head, body: body))
                        state = .head
                        progressed = true
                        break chunkLoop
                    }
                    let chunkStart = lineEnd.upperBound
                    let chunkEnd = chunkStart + size
                    guard buffer.count >= chunkEnd + 2 else { break chunkLoop }
                    body.append(buffer.subdata(in: chunkStart..<chunkEnd))
                    if body.count > maxBodySize { throw HTTPParseError.bodyTooLarge }
                    buffer.removeSubrange(0..<(chunkEnd + 2))
                    state = .chunked(head: head, body: body)
                }
                if !progressed {
                    if case .chunked = state { state = .chunked(head: head, body: body) }
                    return out
                }
            }
        }
    }

    private func findHeadEnd() -> Int? {
        guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return r.lowerBound
    }

    private func parseHead(_ data: Data) throws -> PartialHead {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedRequestLine }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformedRequestLine }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let expects = headers["expect"]?.lowercased() == "100-continue"
        return PartialHead(method: method, path: path, query: query, headers: headers, expectsContinue: expects)
    }

    private func makeRequest(_ head: PartialHead, body: Data) -> HTTPRequest {
        HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: body)
    }
}
