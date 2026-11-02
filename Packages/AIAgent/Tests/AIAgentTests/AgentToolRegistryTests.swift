@testable import AIAgent
import XCTest

private final class EchoExecutor: AgentToolExecutor, @unchecked Sendable {
    func execute(
        _ invocation: AgentToolInvocation,
        cancelToken: AgentCancellationToken?
    ) async throws -> ToolResult {
        _ = cancelToken
        return ToolResult(
            toolCallID: invocation.toolCallID,
            text: "echo \(invocation.name)",
            status: .success,
            truncated: false
        )
    }
}

final class AgentToolRegistryTests: XCTestCase {
    func testDefaultToolSetHasAtLeastSevenTools() {
        XCTAssertGreaterThanOrEqual(AgentToolRegistry.defaultToolDefinitions.count, 7)
        let names = Set(AgentToolRegistry.defaultToolDefinitions.map(\.name))
        XCTAssertTrue(names.contains("run_command"))
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        XCTAssertTrue(names.contains("list_dir"))
        XCTAssertTrue(names.contains("get_system_info"))
        XCTAssertTrue(names.contains("create_snippet"))
        XCTAssertTrue(names.contains("run_snippet"))
    }

    func testRegisterAndQueryExecutor() {
        var registry = AgentToolRegistry(definitions: AgentToolRegistry.defaultToolDefinitions)
        let echo = EchoExecutor()
        let tool = AgentToolRegistry.defaultToolDefinitions[0]
        registry.register(tool, executor: echo)
        let queried = registry.executor(for: tool.name)
        XCTAssertNotNil(queried)
        XCTAssertTrue(queried is EchoExecutor)
    }

    func testExecutorMissingReturnsNil() {
        let registry = AgentToolRegistry(definitions: [])
        XCTAssertNil(registry.executor(for: "nope"))
    }

    func testToolResultClampOutput() {
        let clamped = ToolResult.clampOutput("hello world", limitBytes: 5)
        XCTAssertEqual(clamped.text, "hello")
        XCTAssertTrue(clamped.truncated)
    }

    func testToolResultClampNoTruncation() {
        let clamped = ToolResult.clampOutput("hi", limitBytes: 16)
        XCTAssertEqual(clamped.text, "hi")
        XCTAssertFalse(clamped.truncated)
    }

    func testToolResultStatusEquatable() {
        XCTAssertEqual(ToolResultStatus.success, .success)
        XCTAssertEqual(ToolResultStatus.failure("boom"), .failure("boom"))
        XCTAssertEqual(ToolResultStatus.cancelled, .cancelled)
        XCTAssertNotEqual(ToolResultStatus.failure("a"), .failure("b"))
    }

    func testAllDefaultDefinitionsCarrySafeToRunSchema() {
        for tool in AgentToolRegistry.defaultToolDefinitions {
            let properties = extractObject(tool.parameters)?["properties"] ?? .object([:])
            let safe = extractObject(properties)?["safe_to_run"]
            XCTAssertNotNil(safe, "\(tool.name) should declare safe_to_run")
        }
    }

    private func extractObject(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(dict)? = value {
            return dict
        }
        return nil
    }

    func testInvocationArgumentsRoundTrip() {
        let invocation = AgentToolInvocation(
            toolCallID: "call_1",
            name: "run_command",
            arguments: ["command": .string("ls /home")]
        )
        XCTAssertEqual(invocation.toolCallID, "call_1")
        XCTAssertEqual(invocation.name, "run_command")
        XCTAssertEqual(invocation.arguments["command"], .string("ls /home"))
    }

    // MARK: - Shell rendering (abstract tool → real command)

    func testShellCommandRendersEveryHostTool() {
        let path: [String: JSONValue] = ["path": .string("/etc/hosts")]
        XCTAssertEqual(AgentToolRegistry.shellCommand(for: "run_command", arguments: ["command": .string("df -h")]), "df -h")
        XCTAssertEqual(AgentToolRegistry.shellCommand(for: "read_file", arguments: path), "cat -- '/etc/hosts'")
        XCTAssertEqual(AgentToolRegistry.shellCommand(for: "list_dir", arguments: ["path": .string("/var/log")]), "ls -la -- '/var/log'")
        XCTAssertEqual(
            AgentToolRegistry.shellCommand(for: "get_system_info", arguments: [:]),
            "uname -a; uptime; free -h; df -h /"
        )
    }

    func testShellCommandWriteFilePreservesContent() {
        let rendered = AgentToolRegistry.shellCommand(
            for: "write_file",
            arguments: ["path": .string("/tmp/a.txt"), "content": .string("line1\nline2")]
        )
        XCTAssertEqual(rendered, "printf '%s' 'line1\nline2' > '/tmp/a.txt'")
        XCTAssertNil(
            AgentToolRegistry.shellCommand(for: "write_file", arguments: ["path": .string("/tmp/a.txt")]),
            "no content means nothing to write"
        )
    }

    #if os(macOS) || os(Linux)
        func testWriteFileTreatsContentAsLiteralData() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("it's a file")
            let marker = directory.appendingPathComponent("unexpected")
            let payloads = ["", "no trailing newline", "trailing newline\n", "single ' quote",
                            "GLAZEVERRE_EOF\ntouch '\(marker.path)'\nGLAZEVERRE_EOF",
                            "$(touch '\(marker.path)') `touch '\(marker.path)'`", "中文\n百分号 %s"]
            for content in payloads {
                let command = try XCTUnwrap(AgentToolRegistry.shellCommand(
                    for: "write_file", arguments: ["path": .string(target.path), "content": .string(content)]
                ))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(try Data(contentsOf: target), Data(content.utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            }
        }
    #endif

    func testShellCommandQuotesHostilePaths() {
        let rendered = AgentToolRegistry.shellCommand(for: "read_file", arguments: ["path": .string("/tmp/it's; rm -rf /")])
        XCTAssertEqual(rendered, #"cat -- '/tmp/it'\''s; rm -rf /'"#)
    }

    func testShellCommandIsNilForAppManagedTools() {
        XCTAssertNil(AgentToolRegistry.shellCommand(for: "run_snippet", arguments: ["name": .string("backup")]))
        XCTAssertNil(AgentToolRegistry.shellCommand(for: "create_snippet", arguments: [:]))
        XCTAssertNil(AgentToolRegistry.shellCommand(for: "run_command", arguments: [:]))
    }

    func testHostToolsExposeAHostArgument() {
        let hostAware = ["run_command", "read_file", "write_file", "list_dir", "get_system_info"]
        for name in hostAware {
            let tool = AgentToolRegistry.defaultToolDefinitions.first { $0.name == name }
            let properties = extractObject(tool?.parameters)?["properties"]
            XCTAssertNotNil(extractObject(properties)?["host"], "\(name) should let the model name a target server")
        }
    }

    func testSystemPromptListsConfiguredServers() {
        let prompt = AgentContextBuilder.systemPrompt(
            tools: AgentToolRegistry.defaultToolDefinitions,
            context: AgentContext(
                userPrompt: "status",
                host: HostSummary(alias: "web-1", workingPaths: []),
                availableHosts: ["web-1", "db-1"]
            ),
            approvedWorkingDir: nil
        )
        XCTAssertTrue(prompt.contains("- web-1"))
        XCTAssertTrue(prompt.contains("- db-1"), "the assistant must see the whole server list")
        XCTAssertTrue(prompt.contains("do NOT call a tool"), "plain questions should not force a tool call")
    }
}
