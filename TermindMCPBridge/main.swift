import Darwin
import Foundation

@main
struct TermindMCPBridge {
    static func main() async {
        let configuration = Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
        guard let url = URL(string: configuration.url), !configuration.token.isEmpty else {
            fail("Usage: termind-mcp [--url URL] [--token TOKEN]")
            exit(2)
        }

        let session = URLSession(configuration: .ephemeral)
        var sessionID: String?
        var protocolVersion: String?

        while let line = readLine(strippingNewline: true) {
            guard let input = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
            else {
                fail("Ignoring a stdin line that is not a JSON-RPC object.")
                continue
            }
            let id = object["id"]
            let method = object["method"] as? String
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = input
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
            let params = object["params"] as? [String: Any]
            let meta = params?["_meta"] as? [String: Any]
            let modernVersion = meta?["io.modelcontextprotocol/protocolVersion"] as? String
            if let modernVersion {
                request.setValue(modernVersion, forHTTPHeaderField: "MCP-Protocol-Version")
                request.setValue(method, forHTTPHeaderField: "Mcp-Method")
                if let name = (params?["name"] ?? params?["uri"]) as? String {
                    request.setValue(headerValue(name), forHTTPHeaderField: "Mcp-Name")
                }
            } else if let sessionID {
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }
            if modernVersion == nil, let protocolVersion {
                request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            }

            do {
                let (data, rawResponse) = try await session.data(for: request)
                guard let response = rawResponse as? HTTPURLResponse else {
                    throw BridgeError.notHTTP
                }
                if modernVersion == nil, let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"),
                    !assigned.isEmpty
                {
                    sessionID = assigned
                }
                guard (200..<300).contains(response.statusCode) else {
                    if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        envelope["jsonrpc"] as? String == "2.0", envelope["error"] is [String: Any]
                    {
                        write(data)
                        continue
                    }
                    if id != nil {
                        write(errorResponse(id: id, message: "Termind HTTP server returned \(response.statusCode)."))
                    } else {
                        fail("Termind HTTP server returned \(response.statusCode) for \(method ?? "notification").")
                    }
                    continue
                }
                guard response.statusCode != 202, !data.isEmpty else { continue }
                guard let responseObject = try? JSONSerialization.jsonObject(with: data),
                    JSONSerialization.isValidJSONObject(responseObject)
                else {
                    if id != nil { write(errorResponse(id: id, message: "Termind returned invalid JSON.")) }
                    continue
                }
                if method == "initialize",
                    let envelope = responseObject as? [String: Any],
                    let result = envelope["result"] as? [String: Any],
                    let negotiated = result["protocolVersion"] as? String
                {
                    protocolVersion = negotiated
                }
                write(try JSONSerialization.data(withJSONObject: responseObject))
            } catch {
                if id != nil {
                    write(errorResponse(id: id, message: "Cannot reach Termind: \(error.localizedDescription)"))
                } else {
                    fail("Cannot deliver \(method ?? "notification"): \(error.localizedDescription)")
                }
            }
        }

        if let sessionID {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            if let protocolVersion {
                request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            }
            _ = try? await session.data(for: request)
        }
    }

    private static func headerValue(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        {
            return value
        }
        return "=?base64?" + Data(value.utf8).base64EncodedString() + "?="
    }

    private static func errorResponse(id: Any?, message: String) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": -32000, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func fail(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

private struct Configuration {
    var url: String
    var token: String

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        url = environment["TERMIND_MCP_URL"] ?? "http://127.0.0.1:7391/mcp"
        token = environment["TERMIND_MCP_TOKEN"] ?? ""
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--url" where index + 1 < arguments.count:
                index += 1
                url = arguments[index]
            case "--token" where index + 1 < arguments.count:
                index += 1
                token = arguments[index]
            default:
                break
            }
            index += 1
        }
    }
}

private enum BridgeError: LocalizedError {
    case notHTTP
    var errorDescription: String? { "Termind returned a non-HTTP response." }
}
