import Foundation
import os

/// Google Gemini API adapter (spec §2.5). Speaks `POST
/// /v1beta/models/{model}:streamGenerateContent`. The stream is newline-delimited
/// JSON (occasionally `data:`-prefixed); each JSON chunk is decoded and
/// normalized into `ChatStreamEvent`s. `functionCall` parts arrive whole (Gemini
/// does not fragment arguments), so they become `.toolCall` + `.toolCallComplete`.
public struct GeminiAdapter: AIChatStreaming {
    private static let logger = Logger(subsystem: "com.glazeterm.AIAgent", category: "Gemini")

    private let config: AIProviderConfig
    private let apiKey: String
    private let http: any HTTPStreamingTransport
    private let retryPolicy: StreamRetryPolicy

    public init(
        config: AIProviderConfig,
        apiKey: String,
        http: any HTTPStreamingTransport,
        retryPolicy: StreamRetryPolicy = .default
    ) {
        self.config = config
        self.apiKey = apiKey
        self.http = http
        self.retryPolicy = retryPolicy
    }

    // MARK: - AIChatStreaming

    public func streamCompletion(
        _ request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let url = try Self.streamGenerateContentURL(model: request.model, baseURL: config.baseURL)
        return AsyncThrowingStream<ChatStreamEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await run(request: request, url: url, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func run(
        request: ChatCompletionRequest,
        url: URL,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async {
        var attempts = 0
        while true {
            if Task.isCancelled {
                continuation.finish()
                return
            }
            do {
                let outcome = try await streamOnce(request: request, url: url, continuation: continuation)
                switch outcome {
                case .completed:
                    continuation.yield(.done)
                    continuation.finish()
                    return
                case let .unfinished(hasProgress):
                    if !hasProgress, attempts < retryPolicy.maxZeroDeltaRetries {
                        Self.logger.info("Retrying stalled Gemini stream (attempt \(attempts + 1))")
                        try? await Task.sleep(for: .seconds(retryPolicy.delaySeconds(zeroDeltas: attempts + 1)))
                        attempts += 1
                        continue
                    }
                    continuation.finish(throwing: AIProviderError.streamEndedUnexpectedly)
                    return
                }
            } catch is CancellationError {
                continuation.finish()
                return
            } catch let error as AIProviderError {
                if case .network = error,
                   error != AIProviderError.network("cancelled"),
                   attempts < retryPolicy.maxZeroDeltaRetries
                {
                    Self.logger.info("Retrying Gemini stream after network error (attempt \(attempts + 1))")
                    try? await Task.sleep(for: .seconds(retryPolicy.delaySeconds(zeroDeltas: attempts + 1)))
                    attempts += 1
                    continue
                }
                continuation.finish(throwing: error)
                return
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }
    }

    private func streamOnce(
        request: ChatCompletionRequest,
        url: URL,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws -> StreamOutcome {
        let body = try Self.encodeRequestBody(request)
        let urlRequest = Self.makeRequest(url: url, apiKey: apiKey, body: body)
        let (status, stream): (Int, AsyncThrowingStream<Data, Error>)
        do {
            (status, stream) = try await http.streamData(request: urlRequest)
        } catch {
            throw Self.mapStreamError(error)
        }

        guard (200 ..< 300).contains(status) else {
            let bodyText = try await Self.collectBoundedBody(from: stream)
            throw AIProviderError.httpStatus(status, Self.sanitizeBody(bodyText))
        }

        var lineParser = GeminiLineParser()
        var hasProgress = false
        var terminalReached = false
        var usage: TokenUsage?

        do {
            for try await chunk in stream {
                if Task.isCancelled {
                    throw CancellationError()
                }
                for line in lineParser.consume(chunk) {
                    if line.isEmpty {
                        continue
                    }
                    if Self.isStreamEnd(line) {
                        terminalReached = true
                        break
                    }
                    let events = try Self.decodeChunk(from: line)
                    for event in events {
                        switch event {
                        case let .contentText(text):
                            if !text.isEmpty {
                                hasProgress = true
                                continuation.yield(.content(text))
                            }
                        case let .functionCall(call):
                            hasProgress = true
                            continuation.yield(.toolCall(call))
                            continuation.yield(.toolCallComplete(call))
                        case let .usage(tokenUsage):
                            usage = tokenUsage
                            continuation.yield(.usage(tokenUsage))
                        }
                    }
                    if try Self.chunkIsTerminal(line) {
                        terminalReached = true
                        break
                    }
                }
                if terminalReached {
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapStreamError(error)
        }

        if terminalReached {
            return .completed
        }
        if hasProgress || usage != nil {
            return .completed
        }
        return .unfinished(hasProgress: false)
    }

    // MARK: - Request building

    /// Gemini models are addressed in the path: `/v1beta/models/{model}:streamGenerateContent`.
    static func streamGenerateContentURL(model: String, baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = trimmed.hasSuffix("/v1beta") ? trimmed : trimmed + "/v1beta"
        guard let url = URL(string: "\(base)/models/\(model):streamGenerateContent") else {
            throw AIProviderError.invalidBaseURL(baseURL)
        }
        return url
    }

    static func makeRequest(url: URL, apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body
        return request
    }

    static func encodeRequestBody(_ request: ChatCompletionRequest) throws -> Data {
        var contents: [JSONValue] = []
        var systemPreamble: String?

        for message in request.messages {
            switch message.role {
            case .system:
                systemPreamble = (systemPreamble ?? "") + message.content
            case .user:
                contents.append(Self.geminiContent(role: "user", parts: [.object(["text": .string(message.content)])]))
            case .assistant:
                var parts: [JSONValue] = []
                if !message.content.isEmpty {
                    parts.append(.object(["text": .string(message.content)]))
                }
                for call in message.toolCalls {
                    let args: JSONValue = Self.parseArgumentsJSON(call.argumentsJSON) ?? .object([:])
                    parts.append(.object([
                        "functionCall": .object([
                            "name": .string(call.name),
                            "args": args,
                        ]),
                    ]))
                }
                contents.append(Self.geminiContent(role: "model", parts: parts))
            case .tool:
                let args: JSONValue = Self.parseArgumentsJSON(message.content) ?? .string(message.content)
                contents.append(Self.geminiContent(role: "user", parts: [
                    .object([
                        "functionResponse": .object([
                            "name": .string(message.toolCallID ?? ""),
                            "response": .object([
                                "result": args,
                            ]),
                        ]),
                    ]),
                ]))
            }
        }

        var payload: [String: JSONValue] = [
            "contents": .array(contents),
            "generationConfig": .object([
                "temperature": .number(request.temperature),
            ]),
        ]
        if let systemPreamble, !systemPreamble.isEmpty {
            payload["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(systemPreamble)])]),
            ])
        }
        if !request.tools.isEmpty {
            payload["tools"] = .array([
                .object([
                    "functionDeclarations": .array(request.tools.map(Self.encodeTool)),
                ]),
            ])
        }
        return try JSONEncoder().encode(payload)
    }

    static func geminiContent(role: String, parts: [JSONValue]) -> JSONValue {
        .object([
            "role": .string(role),
            "parts": .array(parts),
        ])
    }

    static func encodeTool(_ tool: ToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters,
        ])
    }

    // MARK: - Chunk decoding

    enum GeminiChunkEvent: Sendable {
        case contentText(String)
        case functionCall(ChatToolCallDelta)
        case usage(TokenUsage)
    }

    static func decodeChunk(from line: Data) throws -> [GeminiChunkEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw AIProviderError.invalidJSON(String(data: line, encoding: .utf8) ?? "<binary>")
        }
        var events: [GeminiChunkEvent] = []

        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            let prompt = usageMetadata["promptTokenCount"] as? Int ?? 0
            let completion = usageMetadata["candidatesTokenCount"] as? Int ?? 0
            let total = usageMetadata["totalTokenCount"] as? Int ?? (prompt + completion)
            events.append(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)))
        }

        if let candidates = json["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]]
                else {
                    continue
                }
                for part in parts {
                    if let text = part["text"] as? String {
                        events.append(.contentText(text))
                    }
                    if let functionCall = part["functionCall"] as? [String: Any],
                       let name = functionCall["name"] as? String
                    {
                        let id = "gemini-\(name)-\(UUID().uuidString.prefix(8))"
                        let args = functionCall["args"].flatMap { Self.serializeJSON($0) } ?? "{}"
                        events.append(.functionCall(ChatToolCallDelta(id: id, name: name, argumentsJSON: args)))
                    }
                }
            }
        }
        return events
    }

    /// A chunk carrying a non-empty `finishReason` in its first candidate closes
    /// the stream (e.g. `STOP`, `MAX_TOKENS`).
    static func chunkIsTerminal(_ line: Data) throws -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first,
              let finishReason = candidate["finishReason"] as? String
        else {
            return false
        }
        return !finishReason.isEmpty
    }

    /// Gemini terminates the stream with an empty `{}` JSON object.
    static func isStreamEnd(_ line: Data) -> Bool {
        guard let text = String(data: line, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "{}"
    }

    static func parseArgumentsJSON(_ text: String?) -> JSONValue? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func serializeJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Shared helpers

    static func collectBoundedBody(from stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var body = Data()
        for try await chunk in stream {
            body.append(chunk)
            if body.count > 4096 {
                break
            }
        }
        return body
    }

    static func sanitizeBody(_ raw: Data) -> String? {
        let text = String(data: raw, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 256 ? String(trimmed.prefix(256)) : trimmed
    }

    static func mapStreamError(_ error: Error) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }
        if error is CancellationError {
            return .network("cancelled")
        }
        return .network(error.localizedDescription)
    }
}

/// Buffers raw Gemini chunks into complete JSON lines. Accepts newline-delimited
/// JSON and `data:`-prefixed SSE lines alike (some gateways frame Gemini as SSE).
private struct GeminiLineParser: Sendable {
    private var carry = ""

    /// Consumes a raw chunk and returns the lines completed by it.
    mutating func consume(_ chunk: Data) -> [Data] {
        guard let text = String(data: chunk, encoding: .utf8) else { return [] }
        carry.append(text)
        var lines: [Data] = []
        while let newline = carry.firstIndex(of: "\n") {
            var line = String(carry[..<newline])
            carry.removeSubrange(...newline)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("data:") {
                line = String(line.dropFirst(5))
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let data = line.data(using: .utf8) {
                lines.append(data)
            }
        }
        return lines
    }
}

/// Outcome of one adapter stream attempt.
private enum StreamOutcome: Sendable {
    case completed
    case unfinished(hasProgress: Bool)
}
