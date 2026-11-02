import Foundation

/// The allow-list behind the read-only approval strategy.
///
/// Read-only mode auto-approves a command only when it parses as ONE simple
/// command whose name is in this table and whose options can neither write
/// files nor execute other programs. Everything else — redirections, pipes,
/// command substitution, `;` separators, unknown commands — is never
/// auto-approved (spec §4.6).
public enum ReadOnlyCommandPolicy {
    /// One allowed command plus the options that disqualify it.
    struct Entry: Sendable {
        /// Options that must ALL be present (`wget --spider`).
        let requiredOptions: [String]
        /// Options that make the command write files or run other programs.
        let forbiddenOptions: [String]
        /// When true a bare (non-flag) argument disqualifies the command.
        let rejectsArguments: Bool

        init(
            requiredOptions: [String] = [],
            forbiddenOptions: [String] = [],
            rejectsArguments: Bool = false
        ) {
            self.requiredOptions = requiredOptions
            self.forbiddenOptions = forbiddenOptions
            self.rejectsArguments = rejectsArguments
        }
    }

    /// Allowed commands, keyed by their exact name (case-sensitive).
    ///
    /// Commands that exist only to run something else — `env`, `command`,
    /// `awk` — are deliberately absent: they turn any argument into program
    /// execution.
    static let entries: [String: Entry] = [
        "ls": Entry(),
        "cat": Entry(),
        "head": Entry(),
        "tail": Entry(),
        "df": Entry(),
        "free": Entry(),
        "ps": Entry(),
        "pwd": Entry(),
        "uptime": Entry(),
        "uname": Entry(),
        "whoami": Entry(),
        "id": Entry(),
        "groups": Entry(),
        "echo": Entry(),
        "which": Entry(),
        "type": Entry(),
        "more": Entry(),
        "man": Entry(forbiddenOptions: ["-P", "--pager"]),
        "grep": Entry(),
        "uniq": Entry(),
        "wc": Entry(),
        "du": Entry(),
        "stat": Entry(),
        "file": Entry(),
        "tree": Entry(),
        "dig": Entry(),
        "nslookup": Entry(),
        "ping": Entry(),
        "route": Entry(),
        "arp": Entry(),
        "netstat": Entry(),
        "ss": Entry(),
        "getent": Entry(),
        "vmstat": Entry(),
        "iostat": Entry(),
        "sar": Entry(),
        "date": Entry(forbiddenOptions: ["-s", "--set"]),
        "sort": Entry(forbiddenOptions: ["-o", "--output"]),
        "find": Entry(forbiddenOptions: [
            "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprintf", "-fprint", "-fls",
        ]),
        "hostname": Entry(rejectsArguments: true),
        "sed": Entry(forbiddenOptions: ["-i", "--in-place"]),
        "curl": Entry(forbiddenOptions: [
            "-o", "--output", "-O", "--remote-name", "-T", "--upload-file",
            "-d", "--data", "--data-raw", "--data-binary", "-F", "--form",
        ]),
        "wget": Entry(requiredOptions: ["--spider"]),
        "sysctl": Entry(forbiddenOptions: ["-w", "--write"]),
    ]

    /// Whether `command` may be auto-approved in read-only mode.
    public static func allows(_ command: String) -> Bool {
        let parsed = ShellCommandParser.parse(command)
        guard !parsed.unsafeSyntax, let name = parsed.words.first, let entry = entries[name] else {
            return false
        }

        var flags: [String] = []
        var bareArguments = false
        var afterTerminator = false
        for word in parsed.words.dropFirst() {
            if word == "--" {
                afterTerminator = true
                continue
            }
            if !afterTerminator, word.hasPrefix("-"), word != "-" {
                flags.append(word)
            } else {
                bareArguments = true
            }
        }

        if entry.rejectsArguments, bareArguments {
            return false
        }
        for option in entry.forbiddenOptions where flags.contains(where: { matches(option, $0) }) {
            return false
        }
        for option in entry.requiredOptions where !flags.contains(where: { matches(option, $0) }) {
            return false
        }
        return true
    }

    /// Whether `token` selects `option`.
    ///
    /// Besides the plain form, long options may carry an attached value
    /// (`--output=file`) and short options may carry it too (`sort -oFILE`).
    private static func matches(_ option: String, _ token: String) -> Bool {
        if token == option {
            return true
        }
        if token.hasPrefix(option + "=") {
            return true
        }
        if !option.hasPrefix("--"), option.count == 2, token.hasPrefix(option), token.count > option.count {
            return true
        }
        return false
    }
}

/// A minimal POSIX-aware splitter for the read-only policy.
///
/// It understands single quotes (everything literal), double quotes (still
/// expands `$(…)` and backticks) and backslash escapes. Anything it cannot
/// vouch for is reported as unsafe syntax, and unsafe syntax is never
/// auto-approved.
enum ShellCommandParser {
    /// The words of a command plus whether it uses syntax we refuse.
    struct Parsed: Sendable {
        var words: [String] = []
        var unsafeSyntax = false
    }

    static func parse(_ command: String) -> Parsed {
        var parsed = Parsed()
        var current = ""
        var hasWord = false
        let characters = Array(command)
        var index = 0

        func flush() {
            if hasWord {
                parsed.words.append(current)
                current = ""
                hasWord = false
            }
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case " ", "\t":
                flush()
                index += 1
            case "\n", "\r":
                parsed.unsafeSyntax = true
                flush()
                index += 1
            case "'":
                // Single quotes: literal until the closing quote.
                index += 1
                hasWord = true
                while index < characters.count, characters[index] != "'" {
                    current.append(characters[index])
                    index += 1
                }
                index += 1
                // `'\''` is the POSIX way to embed a quote inside a quoted
                // string: close the quotes, escape the quote, reopen them.
                // It continues the same word, so keep appending.
                while index + 1 < characters.count,
                      characters[index] == "\\",
                      characters[index + 1] == "'"
                {
                    current.append("'")
                    index += 2
                    while index < characters.count, characters[index] != "'" {
                        current.append(characters[index])
                        index += 1
                    }
                    index += 1
                }
            case "\"":
                // Double quotes: literal, but `$(…)` and backticks still run.
                index += 1
                hasWord = true
                while index < characters.count, characters[index] != "\"" {
                    let inner = characters[index]
                    if inner == "\\", index + 1 < characters.count {
                        index += 1
                        current.append(characters[index])
                        index += 1
                        continue
                    }
                    if inner == "`" || (inner == "$" && index + 1 < characters.count, characters[index + 1] == "(") {
                        parsed.unsafeSyntax = true
                    }
                    current.append(inner)
                    index += 1
                }
                index += 1
            case "\\":
                // Backslash escape: the next character is literal.
                index += 1
                if index < characters.count {
                    current.append(characters[index])
                    hasWord = true
                    index += 1
                } else {
                    parsed.unsafeSyntax = true
                }
            case ";", "&", "|", "<", ">", "(", ")":
                parsed.unsafeSyntax = true
                current.append(character)
                hasWord = true
                index += 1
            case "`":
                parsed.unsafeSyntax = true
                current.append(character)
                hasWord = true
                index += 1
            case "$":
                if index + 1 < characters.count, characters[index + 1] == "(" {
                    parsed.unsafeSyntax = true
                }
                current.append(character)
                hasWord = true
                index += 1
            default:
                current.append(character)
                hasWord = true
                index += 1
            }
        }
        flush()
        return parsed
    }
}
