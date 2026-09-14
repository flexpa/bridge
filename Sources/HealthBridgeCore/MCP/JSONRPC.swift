import Foundation

public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
}

public struct JSONRPCError: Error, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var json: JSONValue {
        var obj: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { obj["data"] = data }
        return .object(obj)
    }
}

/// One incoming JSON-RPC message (request or notification).
public struct JSONRPCMessage: Sendable {
    public var id: JSONValue?  // nil for notifications
    public var method: String
    public var params: JSONValue

    public var isNotification: Bool { id == nil }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue, let method = obj["method"]?.stringValue else { return nil }
        if let v = obj["jsonrpc"]?.stringValue, v != "2.0" { return nil }
        self.method = method
        self.params = obj["params"] ?? .object([:])
        if let id = obj["id"], !id.isNull { self.id = id } else { self.id = nil }
    }

    public static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    public static func failure(id: JSONValue?, error: JSONRPCError) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id ?? .null, "error": error.json])
    }
}
