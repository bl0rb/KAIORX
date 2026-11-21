import Foundation

/// The real command behind a Codex command approval, checked against an allowlist of reading
/// programs and their options (ADR 0008, second live run). `commandActions` in the request is
/// only Codex's display summary; with KAIORX's OS confinement as the only sandbox, the command
/// itself must be a read. Accepted: one call of `cat`, `head`, `tail`, `wc`, `ls`, `pwd`, `rg`,
/// `grep`, `sed -n <range>p` or `find` with only matching predicates, optionally wrapped in
/// `zsh|bash|sh -c|-lc '…'`, with every path operand readable inside the worktree. Anything
/// that could expand, chain, redirect or run another program is declined.
enum ReadCommand {
    static func accepts(_ command: String, context: ApprovalContext) -> Bool {
        guard let argv = argv(command), let first = argv.first, let name = program(first), let rule = rules[name] else { return false }
        guard let paths = rule(Array(argv.dropFirst())) else { return false }
        return paths.allSatisfy { !$0.isEmpty && CodexApprovals.readable($0, context: context) }
    }

    /// The words of the command, unwrapping one `shell -c|-lc '…'`; nil when anything is unsafe.
    static func argv(_ command: String) -> [String]? {
        guard let outer = words(command), let first = outer.first else { return nil }
        guard ["zsh", "bash", "sh"].contains(program(first) ?? "") else { return outer }
        guard outer.count == 3, ["-c", "-lc"].contains(outer[1]), let inner = words(outer[2]), !inner.isEmpty else { return nil }
        if ["zsh", "bash", "sh"].contains(program(inner[0]) ?? "") { return nil }
        return inner
    }

    /// A bare program name, or one in `/bin` or `/usr/bin`.
    static func program(_ word: String) -> String? {
        for folder in ["/bin/", "/usr/bin/"] where word.hasPrefix(folder) {
            let name = String(word.dropFirst(folder.count))
            return name.contains("/") || name.isEmpty ? nil : name
        }
        return word.contains("/") ? nil : word
    }

    /// Shell words with single and double quotes. Declines operators, substitutions, escapes,
    /// control and format characters anywhere, and globbing, `~`, history and zsh `=cmd` outside
    /// quotes. Works on Unicode scalars, as zsh works on bytes: a grapheme cluster such as CR LF
    /// or a prepended mark must not hide an operator or a separator.
    static func words(_ text: String) -> [String]? {
        let forbidden = Set(";|&<>$`\\()".unicodeScalars)
        let unquotedForbidden = Set("*?[]{}~!#^".unicodeScalars)
        guard !text.unicodeScalars.contains(where: { scalar in
            forbidden.contains(scalar) || (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
                || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .control
                || (scalar.properties.isWhitespace && scalar != " " && scalar != "\t")
        }) else { return nil }
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        var quote: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if let open = quote {
                if scalar == open { quote = nil } else { current.append(scalar) }
                continue
            }
            switch scalar {
            case "'", "\"":
                quote = scalar
                inWord = true
            case " ", "\t":
                if inWord { result.append(String(current)) }
                current = String.UnicodeScalarView()
                inWord = false
            default:
                if unquotedForbidden.contains(scalar) { return nil }
                // zsh expands an unquoted `=` at the start of a word, also after empty quotes.
                if scalar == "=", current.isEmpty { return nil }
                current.append(scalar)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { result.append(String(current)) }
        return result
    }

    /// Per program: the path operands of an allowed argument list, or nil.
    static let rules: [String: @Sendable ([String]) -> [String]?] = [
        "cat": { simple($0, flags: ["-n", "-b", "-s"]) },
        "wc": { simple($0, flags: ["-l", "-c", "-w", "-m"]) },
        "head": { simple($0, flags: [], valued: ["-n", "-c"], numericShort: true) },
        "tail": { simple($0, flags: [], valued: ["-n", "-c"], numericShort: true) },
        "ls": { simple($0, flags: Set("1aAlhRtrSFdG".map { "-\($0)" })) },
        "pwd": { $0.isEmpty ? [] : nil },
        "rg": { search($0, flags: rgFlags, valued: rgValued) },
        "grep": { arguments in
            // Without files and without `-r` grep reads standard input: nothing to approve.
            guard let paths = search(arguments, flags: grepFlags, valued: grepValued) else { return nil }
            let recursive = arguments.contains { $0.range(of: #"^-[A-Za-z]*[rR][A-Za-z]*$"#, options: .regularExpression) != nil }
            return paths.isEmpty && !recursive ? nil : paths
        },
        "sed": { arguments in
            // Only printing a line range: `sed -n 5p file` or `sed -n 1,20p file`.
            guard arguments.count >= 3, arguments[0] == "-n",
                  arguments[1].range(of: #"^[0-9]+(,[0-9]+)?p$"#, options: .regularExpression) != nil else { return nil }
            let files = Array(arguments.dropFirst(2))
            return files.contains { $0.hasPrefix("-") } ? nil : files
        },
        "find": { find($0) },
    ]

    static let rgFlags: Set<String> = [
        "-n", "-i", "-S", "-s", "-l", "-c", "-w", "-F", "-x", "-v", "-H", "-N", "--hidden", "--files", "--line-number", "--no-heading",
        "--heading", "--count", "--ignore-case", "--smart-case", "--fixed-strings", "--word-regexp", "--files-with-matches", "--no-ignore",
    ]
    static let rgValued: Set<String> = ["-e", "-g", "--glob", "-t", "--type", "-A", "-B", "-C", "-m", "--max-count", "--max-depth", "-M", "--max-columns"]
    static let grepFlags: Set<String> = ["-n", "-i", "-r", "-R", "-l", "-c", "-w", "-F", "-E", "-v", "-H", "-h", "-s", "-I", "-x", "-o"]
    static let grepValued: Set<String> = ["-e", "-A", "-B", "-C", "-m", "--include", "--exclude", "--exclude-dir"]

    /// Options from the allowlist (combined short flags too, `-n5` style numbers for valued short
    /// options, `--long=value`), then operands; returns the operands.
    /// `permutes`: the program also reads options after operands (GNU `getopt_long`, `rg`); the
    /// BSD tools stop at the first operand, so every later word is a path for them.
    static func options(
        _ arguments: [String], flags: Set<String>, valued: Set<String>, numericShort: Bool = false, permutes: Bool = false
    ) -> (operands: [String], values: [String: String])? {
        var operands: [String] = []
        var values: [String: String] = [:]
        var index = 0
        var endOfOptions = false
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if endOfOptions || !word.hasPrefix("-") || word == "-" || (!permutes && !operands.isEmpty) {
                if word == "-" { return nil } // standard input: nothing to read
                operands.append(word)
                continue
            }
            if word == "--" { endOfOptions = true; continue }
            if flags.contains(word) { continue }
            if valued.contains(word) {
                guard index < arguments.count else { return nil }
                values[word] = arguments[index]
                index += 1
                continue
            }
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "="), valued.contains(String(word[..<equals])) {
                values[String(word[..<equals])] = String(word[word.index(after: equals)...])
                continue
            }
            if numericShort, word.range(of: #"^-[0-9]+$"#, options: .regularExpression) != nil { continue }
            if word.range(of: #"^-[A-Za-z][0-9]+$"#, options: .regularExpression) != nil, valued.contains(String(word.prefix(2))) {
                values[String(word.prefix(2))] = String(word.dropFirst(2))
                continue
            }
            // Combined short flags such as `-rn` or `-la`.
            if word.range(of: #"^-[A-Za-z]{2,}$"#, options: .regularExpression) != nil, word.dropFirst().allSatisfy({ flags.contains("-\($0)") }) { continue }
            return nil
        }
        return (operands, values)
    }

    static func simple(_ arguments: [String], flags: Set<String>, valued: Set<String> = [], numericShort: Bool = false) -> [String]? {
        options(arguments, flags: flags, valued: valued, numericShort: numericShort)?.operands
    }

    /// `rg`/`grep`: the first operand is the pattern unless `-e` gave it (or `--files` lists files).
    static func search(_ arguments: [String], flags: Set<String>, valued: Set<String>) -> [String]? {
        guard let (operands, values) = options(arguments, flags: flags, valued: valued, permutes: true) else { return nil }
        if values["-e"] != nil || arguments.contains("--files") { return operands }
        guard !operands.isEmpty else { return nil }
        return Array(operands.dropFirst())
    }

    /// `find <paths> <predicates>` with only matching predicates (no actions, no output files).
    static func find(_ arguments: [String]) -> [String]? {
        let paths = Array(arguments.prefix { !$0.hasPrefix("-") })
        var rest = Array(arguments.dropFirst(paths.count))
        let valued: Set<String> = ["-name", "-iname", "-path", "-ipath", "-type", "-maxdepth", "-mindepth"]
        let bare: Set<String> = ["-print", "-o", "-a", "-or", "-and"]
        while let word = rest.first {
            rest.removeFirst()
            if bare.contains(word) { continue }
            guard valued.contains(word), let value = rest.first, !value.hasPrefix("-") else { return nil }
            rest.removeFirst()
        }
        return paths
    }
}
