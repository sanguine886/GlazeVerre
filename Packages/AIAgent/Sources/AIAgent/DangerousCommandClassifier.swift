import Foundation

/// DangerRule — a single dangerous-command detection rule.
///
/// `pattern` is a case-insensitive regular expression (`NSRegularExpression`,
/// `.caseInsensitive`). Rules are evaluated in declaration order and the first
/// match wins, so `critical` rules that are more specific should be listed
/// before their `dangerous` siblings.
public struct DangerRule: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case dangerous
        case critical
    }

    public let id: String
    public let pattern: String
    public let severity: Severity
    public let summary: String

    public init(id: String, pattern: String, severity: Severity, summary: String) {
        self.id = id
        self.pattern = pattern
        self.severity = severity
        self.summary = summary
    }
}

/// CommandClassification — the verdict for a single command string.
///
/// A matched rule, when present, is the most severe rule whose pattern
/// matched: when several rules fire, the highest risk level wins, so a broad
/// `dangerous` rule can never mask a `critical` one that also matched.
public struct CommandClassification: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case safe
        case dangerous
        case critical
    }

    public let verdict: CommandClassification.Verdict
    public let matchedRule: DangerRule?

    public init(verdict: CommandClassification.Verdict, matchedRule: DangerRule?) {
        self.verdict = verdict
        self.matchedRule = matchedRule
    }
}

/// DangerousCommandClassifier — pure, stateless classifier over the curated
/// rule set.
///
/// Every rule is evaluated and the most severe match wins, so a `critical`
/// rule is never masked by a broader `dangerous` rule that also fired.
/// Patterns are compiled once per rule on first use and cached, since
/// `NSRegularExpression` is thread-safe after the pattern has been compiled.
public struct DangerousCommandClassifier: Sendable {
    /// Empty initializer so other modules can spin up a default instance
    /// (e.g. from a public default-argument value in ApprovalPolicy).
    public init() {}

    public static let ruleSet: [DangerRule] = [
        DangerRule(id: "rm-recursive-force", pattern: #"rm\s+(-{1,2}[a-z]*)?r[a-z]*f\b"#, severity: .dangerous, summary: "Any rm -rf recursive force delete"),
        DangerRule(id: "rm-no-preserve-root", pattern: #"rm\s+.*--no-preserve-root"#, severity: .critical, summary: "Delete bypassing root protection"),
        DangerRule(
            id: "rm-rf-home-cwd",
            pattern: #"rm\s+(-{1,2}[a-z]*)?r[a-z]*f\s+(~|\$HOME|\.\s|\s\.\b)"#,
            severity: .dangerous,
            summary: "rm -rf home directory or current directory"
        ),
        DangerRule(id: "rm-auth-files", pattern: #"\brm\s+/etc/(passwd|shadow|sudoers)"#, severity: .critical, summary: "Delete system authentication files"),
        DangerRule(id: "mkfs", pattern: #"(\bmkfs|mkfs\.\w+)\s"#, severity: .dangerous, summary: "Format a filesystem"),
        DangerRule(id: "mkswap", pattern: #"\bmkswap"#, severity: .dangerous, summary: "Create swap space"),
        DangerRule(id: "dd-write-device", pattern: #"\bdd\b.*\bof\s*=\s*/dev/"#, severity: .critical, summary: "dd writing to a block device"),
        DangerRule(id: "dd-read-device", pattern: #"\bdd\b.*\bif\s*=\s*/dev/"#, severity: .dangerous, summary: "dd reading from a block device"),
        DangerRule(id: "read-raw-block-device", pattern: #"(cat|head|tail)\s+/dev/sd"#, severity: .dangerous, summary: "Read raw block device data"),
        DangerRule(id: "shutdown", pattern: #"\bshutdown\b"#, severity: .critical, summary: "Shut the system down"),
        DangerRule(id: "reboot", pattern: #"\breboot\b"#, severity: .critical, summary: "Reboot"),
        DangerRule(id: "poweroff", pattern: #"\bpoweroff\b"#, severity: .critical, summary: "Power off"),
        DangerRule(id: "halt", pattern: #"\bhalt\b"#, severity: .dangerous, summary: "Halt the system"),
        DangerRule(id: "init-single-user", pattern: #"\binit\s+0\b"#, severity: .critical, summary: "Enter single-user mode"),
        DangerRule(id: "init-reboot", pattern: #"\binit\s+6\b"#, severity: .dangerous, summary: "Reboot via init"),
        DangerRule(
            id: "systemctl-stop-critical",
            pattern: #"\bsystemctl\s+(stop|disable)\s+(ssh|network|firewalld|NetworkManager)"#,
            severity: .dangerous,
            summary: "Stop critical system service"
        ),
        DangerRule(id: "systemctl-kill", pattern: #"\bsystemctl\s+.*\bkill\b"#, severity: .dangerous, summary: "systemctl kill"),
        DangerRule(id: "chmod-recursive-777-root", pattern: #"\bchmod\s+-R\s*777\s*/\s*$"#, severity: .critical, summary: "World-writable recursively from /"),
        DangerRule(id: "chmod-recursive-000-root", pattern: #"\bchmod\s+-R\s*000\s*/\s*$"#, severity: .critical, summary: "Lock all of /"),
        DangerRule(
            id: "chmod-recursive-cwd",
            pattern: #"\bchmod\s+-R\s*(777|000|666)\s+\."#,
            severity: .dangerous,
            summary: "Permission catastrophe in current directory"
        ),
        DangerRule(id: "chattr-lock-etc", pattern: #"\bchattr\s+.*\+i\s+/etc"#, severity: .dangerous, summary: "Lock system configuration"),
        DangerRule(id: "fork-bomb", pattern: #":\(\)\{\s*.*\|"#, severity: .critical, summary: "Fork bomb"),
        DangerRule(id: "sql-drop", pattern: #"\bDROP\s+(TABLE|DATABASE)\b"#, severity: .critical, summary: "SQL drop table or database"),
        DangerRule(id: "mongo-drop-database", pattern: #"\bdb\.dropDatabase\b"#, severity: .critical, summary: "MongoDB drop database"),
        DangerRule(id: "redis-flush", pattern: #"\bFLUSHALL\b|\bFLUSHDB\b"#, severity: .critical, summary: "Redis flush all keys"),
        DangerRule(id: "redirect-write-block-device", pattern: #">\s*/dev/sd[a-z]"#, severity: .critical, summary: "Redirect write to block device"),
        DangerRule(id: "redirect-write-nvme", pattern: #">\s*/dev/nvme"#, severity: .critical, summary: "Write to NVMe device"),
        DangerRule(id: "redirect-write-disk-pool", pattern: #">\s*/dev/disk/"#, severity: .dangerous, summary: "Write to disk device pool"),
        DangerRule(id: "history-clear", pattern: #"\bhistory\s+-c"#, severity: .dangerous, summary: "Clear command history (erase audit trail)"),
        DangerRule(id: "curl-pipe-shell", pattern: #"\bcurl\b.*\|\s*(ba)?sh"#, severity: .dangerous, summary: "curl piped to shell"),
        DangerRule(id: "wget-pipe-shell", pattern: #"\bwget\b.*\|\s*(ba)?sh"#, severity: .dangerous, summary: "wget piped to shell"),
        DangerRule(id: "nc-backdoor", pattern: #"\bnc\b.*\s+-e\s"#, severity: .critical, summary: "netcat backdoor"),
        DangerRule(id: "ncat-backdoor", pattern: #"\bncat\b.*\s+-e\s"#, severity: .critical, summary: "ncat backdoor"),
        DangerRule(id: "reverse-shell", pattern: #"\bbash\s+-i\s+>&\s*/dev/tcp/"#, severity: .critical, summary: "Reverse shell"),
        DangerRule(id: "mkfifo-shell-backdoor", pattern: #"\bmkfifo\b.*\|\s*sh"#, severity: .dangerous, summary: "FIFO shell backdoor"),
        DangerRule(id: "chown-recursive", pattern: #"\bchown\s+-R"#, severity: .dangerous, summary: "Recursive ownership change"),
        DangerRule(id: "usermod-lock", pattern: #"\busermod\s+-L\b"#, severity: .dangerous, summary: "Lock a user account"),
        DangerRule(id: "passwd", pattern: #"\bpasswd\b"#, severity: .dangerous, summary: "Change password"),
        DangerRule(id: "overwrite-passwd", pattern: #"\becho\s+.*>\s*/etc/passwd"#, severity: .critical, summary: "Overwrite password file"),
        DangerRule(id: "overwrite-shadow", pattern: #"\becho\s+.*>\s*/etc/shadow"#, severity: .critical, summary: "Overwrite shadow file"),
        DangerRule(id: "iptables-flush", pattern: #"\biptables\s+-F\b"#, severity: .dangerous, summary: "Flush firewall rules"),
        DangerRule(
            id: "iptables-default-drop",
            pattern: #"\biptables\s+-P\s+(INPUT|OUTPUT|FORWARD)\s+DROP"#,
            severity: .critical,
            summary: "Set default DROP policy"
        ),
        DangerRule(id: "ufw-disable-reset", pattern: #"\bufw\s+(disable|reset)"#, severity: .dangerous, summary: "Disable firewall"),
        DangerRule(id: "umount-root", pattern: #"\bumount\s+(-l|-f)?\s*/"#, severity: .dangerous, summary: "Unmount root filesystem"),
        DangerRule(id: "mount-remount-rw-root", pattern: #"\bmount\s+-o\s+remount,rw\s*/"#, severity: .dangerous, summary: "Remount root as read-write"),
        DangerRule(id: "mv-root", pattern: #"\bmv\s+/\s"#, severity: .dangerous, summary: "Move the root directory"),
        DangerRule(id: "cp-root", pattern: #"\bcp\s+-r\s+/\s"#, severity: .dangerous, summary: "Copy the root directory"),
        DangerRule(id: "ln-root", pattern: #"\bln\s+-s\s+/\s"#, severity: .dangerous, summary: "Symlink the root directory"),
        DangerRule(id: "tar-to-device", pattern: #"\btar\s+czf\s+/dev/"#, severity: .critical, summary: "Archive directly to a device"),
        DangerRule(id: "find-delete", pattern: #"\bfind\s+/\s.*-delete"#, severity: .critical, summary: "Recursive find delete"),
        DangerRule(id: "find-exec-rm-sh", pattern: #"\bfind\s+/\s.*-exec\s+(rm|sh)"#, severity: .critical, summary: "find traversal delete via exec"),
        DangerRule(id: "rsync-delete", pattern: #"\brsync\s+.*--delete\s+.*/$"#, severity: .dangerous, summary: "Synchronization with delete"),
        DangerRule(id: "shred-root", pattern: #"\bshred\b\s+/"#, severity: .critical, summary: "Shred the root filesystem"),
        DangerRule(id: "wipefs", pattern: #"\bwipefs\b"#, severity: .dangerous, summary: "Wipe filesystem signatures"),
        DangerRule(id: "fdisk-write", pattern: #"\bfdisk\b.*(write|w)"#, severity: .dangerous, summary: "Write partition table"),
        DangerRule(id: "parted-rm", pattern: #"\bparted\b.*\brm\b"#, severity: .dangerous, summary: "Delete a partition"),
        DangerRule(id: "cryptsetup-luksformat", pattern: #"\bcryptsetup\s+luksFormat"#, severity: .critical, summary: "Format an encrypted volume"),
        DangerRule(id: "lvremove", pattern: #"\blvremove\b\s"#, severity: .dangerous, summary: "Remove an LVM logical volume"),
        DangerRule(id: "killall-9", pattern: #"\bkillall\s+-9\b"#, severity: .dangerous, summary: "Force kill all matching processes"),
        DangerRule(id: "pkill-9", pattern: #"\bpkill\s+-9\b"#, severity: .dangerous, summary: "Force kill by name"),
        DangerRule(id: "kill-pid1", pattern: #"\bkill\s+-9\s+1\b"#, severity: .critical, summary: "Kill PID 1"),
        DangerRule(id: "kill-all-processes", pattern: #"\bkill\s+-9\s+-1\b"#, severity: .critical, summary: "Kill all processes"),
        DangerRule(id: "overwrite-var-log", pattern: #"\becho\s+.*>\s*/var/log"#, severity: .dangerous, summary: "Overwrite log files"),
    ]

    /// Classify a command by the most severe matching rule.
    ///
    /// The command is trimmed of surrounding whitespace before matching. Every
    /// rule is evaluated; the rule with the highest severity wins, and among
    /// rules of equal severity the earliest one in `ruleSet` is reported.
    public func classify(_ command: String) -> CommandClassification {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CommandClassification(verdict: .safe, matchedRule: nil)
        }
        var best: (rule: DangerRule, severity: DangerRule.Severity)?
        for rule in Self.ruleSet {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            guard Self.regex(for: rule.id, pattern: rule.pattern)?.firstMatch(in: trimmed, options: [], range: range) != nil else {
                continue
            }
            if best == nil || (rule.severity == .critical && best?.severity == .dangerous) {
                best = (rule, rule.severity)
            }
        }
        guard let best else {
            return CommandClassification(verdict: .safe, matchedRule: nil)
        }
        let verdict: CommandClassification.Verdict = best.severity == .critical ? .critical : .dangerous
        return CommandClassification(verdict: verdict, matchedRule: best.rule)
    }

    /// Leading command token (first whitespace-separated run), capped at four
    /// characters.
    ///
    /// Used to display the gist of a command on typed-confirmation prompts.
    /// Returning the command word rather than characters stripped of
    /// whitespace means `rm -rf /tmp` surfaces as `rm`, not `rm-r`, so the
    /// dangerous flags and arguments stay hidden.
    public func typeAhead(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isWhitespace).first else { return "" }
        return String(first.prefix(min(4, first.count)))
    }

    /// Returns true when the command is a single, provably read-only command.
    ///
    /// The command is parsed like a shell would: redirections, pipes,
    /// command substitution and separators disqualify it, and the command name
    /// must appear in the read-only allow-list with options that can neither
    /// write files nor execute other programs.
    public func isReadOnlyWhitelisted(_ command: String) -> Bool {
        ReadOnlyCommandPolicy.allows(command)
    }

    // MARK: - Pattern cache

    // Compiled-regular-expression cache. `nonisolated(unsafe)` is deliberate:
    // the cache is guarded by `lock` at every access, and `NSRegularExpression`
    // is thread-safe, so the static storage can be shared across the
    // value-type `Sendable` classifier.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSRegularExpression] = [:]

    private static func regex(for id: String, pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        cache[id] = compiled
        return compiled
    }
}
