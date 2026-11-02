@testable import AIAgent
import XCTest

/// Guards the read-only allow-list directly: the classifier only consumes it,
/// so a regression here would otherwise surface as a silently auto-approved
/// write (spec §4.6).
final class ReadOnlyCommandPolicyTests: XCTestCase {
    func testAllowsSimpleReadOnlyCommands() {
        let allowed = [
            "ls -la /var/log",
            "cat /etc/passwd",
            "grep -rn needle .",
            "df -h",
            "free -m",
            "ps aux",
            "pwd",
            "uptime",
            "uname -a",
            "echo hello",
            "curl https://example.com/health",
            "wget --spider https://example.com",
            "sed -n 1,10p file",
            "sort file",
        ]
        for command in allowed {
            XCTAssertTrue(ReadOnlyCommandPolicy.allows(command), command)
        }
    }

    func testRejectsPrefixImpostorsAndCaseVariants() {
        for command in ["lsanything", "catfoo", "LS", "Cat /etc/passwd"] {
            XCTAssertFalse(ReadOnlyCommandPolicy.allows(command), command)
        }
    }

    func testRejectsShellMetacharacters() {
        let rejected = [
            "ls; touch /tmp/x",
            "ls && touch /tmp/x",
            "ls || touch /tmp/x",
            "ls | sh",
            "cat < /etc/shadow",
            "echo hi > /tmp/x",
            "echo hi >> /tmp/x",
            "ls\n touch /tmp/x",
            "echo hi &",
            "echo (touch /tmp/x)",
            "echo `touch /tmp/x`",
            "echo $(touch /tmp/x)",
            "echo \"$(touch /tmp/x)\"",
            "echo \"`touch /tmp/x`\"",
            "echo \"pre$(touch /tmp/x)post\"",
        ]
        for command in rejected {
            XCTAssertFalse(ReadOnlyCommandPolicy.allows(command), command)
        }
    }

    func testDoubleQuotedSubstitutionIsUnsafeButSingleQuotedIsLiteral() {
        // Double quotes still expand command substitution; single quotes do not.
        XCTAssertFalse(ReadOnlyCommandPolicy.allows("echo \"$(id)\""))
        XCTAssertFalse(ReadOnlyCommandPolicy.allows("echo \"`id`\""))
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("echo '$(id)'"))
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("echo '`id`'"))
        // A lone `$` or a quoted path handed to the tool router stays allowed.
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("echo $HOME"))
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("cat '/tmp/a b'"))
    }

    func testRejectsProgramLaunchers() {
        for command in ["env sh", "command ls", "awk 'BEGIN {system(\"id\")}'", "xargs rm"] {
            XCTAssertFalse(ReadOnlyCommandPolicy.allows(command), command)
        }
    }

    func testRejectsWriteCapableOptions() {
        let rejected = [
            "find . -exec touch /tmp/x \\;",
            "find . -delete",
            "sort -o /tmp/out /tmp/in",
            "sort -o/tmp/out /tmp/in",
            "date -s tomorrow",
            "date --set=tomorrow",
            "hostname new-name",
            "curl -o /tmp/x https://example.com",
            "curl --output=/tmp/x https://example.com",
            "curl -d key=value https://example.com",
            "sed -i s/a/b/ file",
            "sed --in-place s/a/b/ file",
            "sysctl -w net.ipv4.ip_forward=0",
            "man -P cat ls",
        ]
        for command in rejected {
            XCTAssertFalse(ReadOnlyCommandPolicy.allows(command), command)
        }
    }

    func testRequiredOptions() {
        XCTAssertFalse(ReadOnlyCommandPolicy.allows("wget https://example.com"))
        XCTAssertFalse(ReadOnlyCommandPolicy.allows("wget -O /tmp/x https://example.com"))
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("wget --spider https://example.com"))
    }

    func testDoubleDashStopsOptionParsing() {
        // After `--`, `-o` is an operand, not the output flag.
        XCTAssertTrue(ReadOnlyCommandPolicy.allows("sort -- -o"))
        // `hostname` accepts no bare operands at all, even after `--`.
        XCTAssertFalse(ReadOnlyCommandPolicy.allows("hostname -- new-name"))
    }

    func testEmptyAndWhitespaceOnlyCommandsAreRejected() {
        for command in ["", "   ", "\n", "\t"] {
            XCTAssertFalse(ReadOnlyCommandPolicy.allows(command), command.debugDescription)
        }
    }

    func testParserKeepsQuotedContentInOneWord() {
        let parsed = ShellCommandParser.parse("echo 'a b' \"c d\"")
        XCTAssertFalse(parsed.unsafeSyntax)
        XCTAssertEqual(parsed.words, ["echo", "a b", "c d"])
    }
}
