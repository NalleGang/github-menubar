import Foundation

struct GitChange: Identifiable, Sendable {
    let id: String
    let path: String
    let name: Data
    let renameSource: Data?
    let deletedFromWorktree: Bool
    let canPreview: Bool
    let staged: Bool
    let unstaged: Bool
    let conflict: Bool
}

struct RepositoryStatus: Sendable {
    let branch: String
    let changes: [GitChange]
    let excludedPaths: [Data]
    let hasExcludedIndexChanges: Bool

    // Porcelain v1 appends "[ahead N, behind M]" after the upstream name.
    // Git ref names cannot contain a space or an opening bracket.
    var divergence: (ahead: Int, behind: Int) {
        guard let start = branch.range(of: " ["), branch.last == "]" else { return (0, 0) }
        let counts = branch[start.upperBound...].dropLast().split(separator: ",")
        var ahead = 0, behind = 0
        for count in counts {
            let fields = count.split(separator: " ")
            guard fields.count == 2, let value = Int(fields[1]) else { continue }
            if fields[0] == "ahead" { ahead = value }
            if fields[0] == "behind" { behind = value }
        }
        return (ahead, behind)
    }
}

enum SyncAction: String, CaseIterable {
    case fetch = "Fetch"
    case pull = "Pull (fast-forward only)"
    case push = "Push"

    var arguments: [String] {
        switch self {
        case .fetch: return ["fetch"]
        case .pull: return ["pull", "--ff-only"]
        case .push: return ["push"]
        }
    }
}

struct Git: Sendable {
    static func status(_ path: String) throws -> RepositoryStatus {
        let output = try run(
            ["status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all"],
            in: path, readOnly: true
        )
        let records = output.split(separator: 0)
        var changes: [GitChange] = []
        var excludedPaths: [Data] = []
        var hasExcludedIndexChanges = false
        guard let header = records.first, header.starts(with: [35, 35, 32]) else {
            throw Failure("Git returned an unreadable branch status.")
        }
        let branch = String(decoding: header.dropFirst(3), as: UTF8.self)
        var index = 1
        var nestedCache: [String: Bool] = [:]

        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count >= 4, record[record.startIndex + 2] == 32 else {
                throw Failure("Git returned an unreadable file status.")
            }
            let flags = String(decoding: record.prefix(2), as: UTF8.self)
            let name = Data(record.dropFirst(3))
            let displayName = String(decoding: name, as: UTF8.self)
            var displayPath = displayName
            var renameSource: Data?
            if flags.contains("R") || flags.contains("C") {
                guard index < records.count else {
                    throw Failure("Git returned a rename without its original path.")
                }
                let original = String(decoding: records[index], as: UTF8.self)
                displayPath = "\(original) → \(displayName)"
                if flags.contains("R") { renameSource = Data(records[index]) }
                index += 1
            }

            guard !isNested(displayName, in: path, cache: &nestedCache) else {
                if flags != "??", flags.first != " " { hasExcludedIndexChanges = true }
                excludedPaths.append(name)
                continue
            }

            let conflict = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(flags)
            changes.append(GitChange(
                id: flags + ":" + name.base64EncodedString(),
                path: displayPath,
                name: name, renameSource: renameSource,
                deletedFromWorktree: flags.last == "D",
                canPreview: flags != "??" && String(data: name, encoding: .utf8) != nil,
                staged: !conflict && flags != "??" && flags.first != " ",
                unstaged: !conflict && flags.last != " ",
                conflict: conflict
            ))
        }
        return RepositoryStatus(branch: branch, changes: changes, excludedPaths: excludedPaths,
                                hasExcludedIndexChanges: hasExcludedIndexChanges)
    }

    static func stage(_ path: String, change: GitChange? = nil) throws {
        let current = try status(path)
        let candidates: [GitChange]
        if let change {
            guard let match = current.changes.first(where: { $0.id == change.id }), match.unstaged else {
                throw Failure("This file changed. Refresh and try again.")
            }
            candidates = [match]
        } else {
            guard !current.changes.contains(where: \.conflict) else {
                throw Failure("Resolve merge conflicts before staging all changes.")
            }
            candidates = current.changes.filter(\.unstaged)
        }
        // A tracked file replaced by a directory has a deletion row and separate
        // untracked children. Staging that row must only update the tracked file.
        let trackedOnly = change != nil && candidates.first?.deletedFromWorktree == true
        try updateIndex(path, arguments: ["add", trackedOnly ? "--update" : "--all"],
                        names: candidates.map(\.name), excluding: current.excludedPaths)
    }

    static func unstage(_ path: String, change: GitChange) throws {
        guard let match = try status(path).changes.first(where: { $0.id == change.id }), match.staged else {
            throw Failure("This file changed. Refresh and try again.")
        }
        try updateIndex(path, arguments: ["reset", "--quiet"], names: [match.name, match.renameSource].compactMap { $0 })
    }

    private static func updateIndex(_ path: String, arguments: [String], names: [Data], excluding: [Data] = []) throws {
        guard !names.isEmpty else { return }
        // NUL-separated literal paths preserve arbitrary filenames and avoid argv limits.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var paths = Data()
        for name in names {
            paths.append(contentsOf: ":(literal)".utf8)
            paths.append(name)
            paths.append(0)
        }
        for name in excluding {
            paths.append(contentsOf: ":(exclude,literal)".utf8)
            paths.append(name)
            paths.append(0)
        }
        try paths.write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try run(arguments + ["--pathspec-from-file=\(file.path)", "--pathspec-file-nul"], in: path)
    }

    static func sync(_ path: String, action: SyncAction) throws {
        _ = try run(action.arguments, in: path)
    }

    static func diff(_ path: String, change: GitChange, staged: Bool) throws -> String {
        guard let name = String(data: change.name, encoding: .utf8) else {
            throw Failure("Git cannot preview this filename.")
        }
        var args = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv"]
        if staged { args.append("--cached") }
        args += ["--", name]
        if staged, let source = change.renameSource.flatMap({ String(data: $0, encoding: .utf8) }) {
            args.append(source)
        }
        let data = try run(args, in: path, readOnly: true, limit: 32769)
        if data.isEmpty { return "No diff to display." }
        return String(decoding: data.prefix(32768), as: UTF8.self)
            + (data.count > 32768 ? "\n… Preview limited to 32 KiB" : "")
    }

    static func history(_ path: String) throws -> String {
        let data = try run(["log", "-8", "--no-show-signature", "--format=%h  %s"], in: path, readOnly: true)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func commit(_ path: String, message: String) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("Enter a commit message.")
        }
        guard try !status(path).hasExcludedIndexChanges else {
            throw Failure("The index includes changes inside a nested checkout. Review and commit those changes in Git before continuing.")
        }
        _ = try run(["commit", "--message=\(message)"], in: path)
    }

    static func root(_ path: String) throws -> String {
        var output = try run(["rev-parse", "--show-toplevel"], in: path, readOnly: true)
        if output.last == 10 { output.removeLast() }
        guard let root = String(data: output, encoding: .utf8), root.hasPrefix("/") else {
            throw Failure("Git returned an unreadable repository path.")
        }
        return root
    }

    /// Finds a Git checkout at `path`, plus any checkouts one directory below it.
    /// This matches the lightweight folder scanning the original Omarchy widget used.
    static func discoverRepositories(in path: String) throws -> [String] {
        let files = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        let children = try files.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let directories = children.filter {
            (try? $0.resourceValues(forKeys: keys).isDirectory) == true
        }
        let candidates = [rootURL] + directories
        var repositories: [String] = []

        for candidate in candidates {
            if files.fileExists(atPath: candidate.appendingPathComponent(".git").path),
               let repository = try? root(candidate.path), !repositories.contains(repository) {
                repositories.append(repository)
            }
        }
        return repositories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func isNested(_ name: String, in root: String, cache: inout [String: Bool]) -> Bool {
        var prefix = ""
        for component in name.split(separator: "/") {
            prefix += String(component)
            if cache[prefix] == nil {
                let url = URL(fileURLWithPath: root + "/" + prefix)
                cache[prefix] = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
                    && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            }
            if cache[prefix] == true { return true }
            prefix += "/"
        }
        return false
    }

    private static func run(
        _ arguments: [String], in path: String, readOnly: Bool = false, limit: Int? = nil
    ) throws -> Data {
        let files = FileManager.default
        // A removed checkout inside another repository must never fall back to its parent.
        if arguments.first != "rev-parse", !files.fileExists(atPath: path + "/.git") {
            throw Failure("This folder is no longer a Git checkout.")
        }
        let location = arguments.first == "rev-parse" ? ["-C", path] :
            ["-C", path, "--git-dir=\(path)/.git", "--work-tree=\(path)"]
        return try Command.run("git", location + arguments, readOnly: readOnly, limit: limit)
    }
}

enum Command {
    static func run(_ executable: String, _ arguments: [String], readOnly: Bool = false, limit: Int? = nil) throws -> Data {
        let files = FileManager.default
        var environment = ProcessInfo.processInfo.environment
        for variable in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"] {
            environment.removeValue(forKey: variable)
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let directories = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let binary = directories.map({ $0 + "/" + executable }).first(where: files.isExecutableFile(atPath:)) else {
            throw Failure("\(executable) is unavailable. Install it to use this action.")
        }

        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        let errorFile = scratch.appendingPathComponent("stderr")
        try Data().write(to: errorFile)
        let stderr = try FileHandle(forWritingTo: errorFile)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        environment["PATH"] = directories.joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if readOnly {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["LC_ALL"] = "C"
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment

        try process.run()
        var output = Data()
        while let chunk = try stdout.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            output.append(chunk.prefix(limit.map { max(0, $0 - output.count) } ?? chunk.count))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errors = (try? Data(contentsOf: errorFile)) ?? Data()
            let details = String(decoding: (errors.isEmpty ? output : errors).suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(details.isEmpty ? "Git exited with status \(process.terminationStatus)." : details)
        }
        return output
    }
}

struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
