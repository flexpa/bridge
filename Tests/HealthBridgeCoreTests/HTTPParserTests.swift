import XCTest
@testable import HealthBridgeCore

final class HTTPParserTests: XCTestCase {
    func testSimplePost() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:4271\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let out = try parser.feed(Data(raw.utf8))
        XCTAssertEqual(out.requests.count, 1)
        let r = out.requests[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.query["x"], "1")
        XCTAssertEqual(r.header("Host"), "127.0.0.1:4271")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{}")
    }

    func testBodySplitAcrossFeeds() throws {
        var parser = HTTPRequestParser()
        let head = "POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n"
        XCTAssertEqual(try parser.feed(Data(head.utf8)).requests.count, 0)
        XCTAssertEqual(try parser.feed(Data("hello".utf8)).requests.count, 0)
        let out = try parser.feed(Data(" world".utf8))
        XCTAssertEqual(out.requests.count, 1)
        XCTAssertEqual(String(decoding: out.requests[0].body, as: UTF8.self), "hello world")
    }

    func testPipelinedRequests() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"
        let out = try parser.feed(Data(raw.utf8))
        XCTAssertEqual(out.requests.map(\.path), ["/a", "/b"])
    }

    func testChunkedBody() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let out = try parser.feed(Data(raw.utf8))
        XCTAssertEqual(out.requests.count, 1)
        XCTAssertEqual(String(decoding: out.requests[0].body, as: UTF8.self), "hello world")
    }

    func testExpectContinue() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /mcp HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n"
        let out = try parser.feed(Data(raw.utf8))
        XCTAssertTrue(out.needsContinue)
        XCTAssertEqual(try parser.feed(Data("abcd".utf8)).requests.count, 1)
    }

    func testPostWithoutLengthIsRejected() {
        var parser = HTTPRequestParser()
        XCTAssertThrowsError(try parser.feed(Data("POST /mcp HTTP/1.1\r\nHost: x\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .lengthRequired)
        }
    }

    func testOversizedBodyIsRejected() {
        var parser = HTTPRequestParser()
        parser.maxBodySize = 10
        XCTAssertThrowsError(try parser.feed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPParseError, .bodyTooLarge)
        }
    }

    func testResponseSerialization() {
        let response = HTTPResponse.json(["ok": true], status: 200, headers: [("Mcp-Session-Id", "abc")])
        let text = String(decoding: response.serialize(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: abc\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}
