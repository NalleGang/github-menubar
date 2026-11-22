import Foundation

struct GitChange: Identifiable, Sendable {
    let id: String
    let path: String
    let staged: Bool
    let unstaged: Bool
    let conflict: Bool
}

struct Git: Sendable {
    static func status(_ path: String) throws -> [GitChange] {
        let nestedRepositories = nestedRepositoryPaths(in: path)
        let output = try run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            in: path, readOnly: true
        )
        let records = output.split(separator: 0)
        var changes: [GitChange] = []
        var index = 0

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
            var originalPath: String?
            if flags.contains("R") || flags.contains("C") {
                guard index < records.count else {
                    throw Failure("Git returned a rename without its original path.")
                }
                let original = String(decoding: records[index], as: UTF8.self)
                displayPath = "\(original) → \(displayName)"
                originalPath = original
                index += 1
            }

            guard !isInsideNestedRepository(displayName, nestedRepositories),
                  originalPath.map({ !isInsideNestedRepository($0, nestedRepositories) }) ?? true else {
                continue
            }

            let conflict = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(flags)
            changes.append(GitChange(
                id: flags + ":" + name.base64EncodedString(),
                path: displayPath,
                staged: !conflict && flags != "??" && flags.first != " ",
                unstaged: !conflict && flags.last != " ",
                conflict: conflict
            ))
        }
        return changes
    }

    static func stage(_ path: String) throws {
        let exclusions = nestedRepositoryPaths(in: path).map { ":(exclude)\($0)" }
        _ = try run(["add", "--all", "--", "."] + exclusions, in: path)
    }

    static func commit(_ path: String, message: String) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("Enter a commit message.")
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
            if let repository = try? root(candidate.path), !repositories.contains(repository) {
                repositories.append(repository)
            }
        }
        return repositories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func nestedRepositoryPaths(in path: String) -> [String] {
        let files = FileManager.default
        let rootURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard let children = try? files.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let repository = try? root(child.path) else {
                return nil
            }
            let repositoryURL = URL(fileURLWithPath: repository, isDirectory: true).standardizedFileURL
            guard repositoryURL.path != rootURL.path,
                  repositoryURL.path.hasPrefix(rootURL.path + "/") else {
                return nil
            }
            return String(repositoryURL.path.dropFirst(rootURL.path.count + 1))
        }
    }

    private static func isInsideNestedRepository(_ candidate: String, _ nestedRepositories: [String]) -> Bool {
        let normalized = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
        return nestedRepositories.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private static func run(
        _ arguments: [String], in path: String, readOnly: Bool = false
    ) throws -> Data {
        let files = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let directories = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let git = directories.map({ $0 + "/git" }).first(where: files.isExecutableFile(atPath:)) else {
            throw Failure("Git is unavailable. Install the Xcode Command Line Tools or Homebrew Git.")
        }

        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        let errorFile = scratch.appendingPathComponent("stderr")
        try Data().write(to: errorFile)
        let stderr = try FileHandle(forWritingTo: errorFile)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", path] + arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        var gitEnvironment = environment
        gitEnvironment["PATH"] = directories.joined(separator: ":")
        gitEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        if readOnly { gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0" }
        process.environment = gitEnvironment

        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errors = (try? Data(contentsOf: errorFile)) ?? Data()
            let details = String(decoding: (errors.isEmpty ? output : errors).suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(details.isEmpty ? "Git exited with status \(process.terminationStatus)." : details)
        }
        return output
    }

    private struct Failure: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
