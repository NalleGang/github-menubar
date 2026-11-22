import AppKit
import SwiftUI

@main
@MainActor
struct GitMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: DashboardModel { delegate.model }

    var body: some Scene {
        MenuBarExtra {
            Dashboard(model: model)
        } label: {
            StatusIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DashboardModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.poll() }
    }
}

@MainActor
struct StatusIcon: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.icon)
            if !model.syncCounts.isEmpty { Text(model.syncCounts) }
        }
        .accessibilityLabel(Text([model.iconDescription, model.syncCounts].filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var repos = UserDefaults.standard.stringArray(forKey: "repositories") ?? []
    @Published private(set) var watchedFolders = UserDefaults.standard.stringArray(forKey: "watchedFolders") ?? []
    @Published private(set) var statuses: [String: RepositoryStatus] = [:]
    @Published private(set) var statusErrors: [String: String] = [:]
    @Published private(set) var busy = false
    @Published var selected = ""
    @Published var actionError: String?
    @Published var drafts: [String: String] = [:]
    @Published var inspection: String?
    private var refreshTask: Task<Void, Never>?
    private var excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedRepositories") ?? [])
    private var lastDiscovery = Date.distantPast

    var needsAttention: Bool { statuses.values.contains { !$0.changes.isEmpty } }
    var syncCounts: String {
        var ahead = 0, behind = 0
        for status in statuses.values {
            let counts = status.divergence
            ahead += counts.ahead
            behind += counts.behind
        }
        return [ahead > 0 ? "↑\(ahead)" : "", behind > 0 ? "↓\(behind)" : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    var icon: String {
        if !statusErrors.isEmpty { return "exclamationmark.circle.fill" }
        return needsAttention ? "tray.full.fill" : "tray"
    }
    var iconDescription: String {
        if !statusErrors.isEmpty { return "Git Stage: repository status unavailable" }
        if needsAttention { return "Git Stage: changes need attention" }
        return repos.isEmpty ? "Git Stage: add a repository" : "Git Stage: working trees clean"
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
        }
    }

    func refresh() async {
        guard !busy else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }

        let paths = repos
        let folders = watchedFolders
        let shouldDiscover = !folders.isEmpty && Date().timeIntervalSince(lastDiscovery) >= 30
        let task = Task {
            let result = await Task.detached(priority: .utility) {
                let discovered = shouldDiscover
                    ? folders.flatMap { (try? Git.discoverRepositories(in: $0)) ?? [] }
                    : []
                let allPaths = Array(Set(paths + discovered)).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                let statuses = allPaths.map { path in (path, Result { try Git.status(path) }) }
                return (discovered, statuses)
            }.value
            if shouldDiscover && watchedFolders == folders {
                lastDiscovery = Date()
                let added = Set(result.0).subtracting(repos).subtracting(excluded)
                if !added.isEmpty {
                    repos.append(contentsOf: added)
                    repos.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                    save()
                }
            }
            for (path, status) in result.1 where repos.contains(path) {
                switch status {
                case .success(let changes):
                    statuses[path] = changes
                    statusErrors[path] = nil
                case .failure(let error):
                    statuses[path] = nil
                    statusErrors[path] = error.localizedDescription
                }
            }
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func add(_ folder: URL) async {
        await perform {
            try Git.root(folder.path)
        } onSuccess: { root in
            self.excluded.remove(root)
            if !self.repos.contains(root) {
                self.repos.append(root)
                self.save()
            }
            self.selected = root
        }
    }

    func watch(_ folder: URL) async {
        await perform {
            try Git.discoverRepositories(in: folder.path)
        } onSuccess: { repositories in
            let path = folder.path
            if !self.watchedFolders.contains(path) {
                self.watchedFolders.append(path)
                self.watchedFolders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                self.save()
            }
            self.excluded.subtract(repositories)
            let added = repositories.filter { !self.repos.contains($0) }
            if !added.isEmpty {
                self.repos.append(contentsOf: added)
                self.repos.sort { $0.localizedStandardCompare($1) == .orderedAscending }
                self.save()
            }
            self.selected = repositories.first ?? self.selected
            self.lastDiscovery = Date()
        }
    }

    func stopWatching(_ folder: String) {
        watchedFolders.removeAll { $0 == folder }
        save()
    }

    func removeSelected() {
        guard !busy else { return }
        let path = selected
        if !watchedFolders.isEmpty { excluded.insert(path) }
        repos.removeAll { $0 == path }
        statuses[path] = nil
        statusErrors[path] = nil
        drafts[path] = nil
        actionError = nil
        selected = repos.first ?? ""
        save()
    }

    func stage(_ change: GitChange? = nil) async {
        let path = selected
        guard repos.contains(path) else { return }
        await perform { try Git.stage(path, change: change) } onSuccess: { _ in }
    }

    func unstage(_ change: GitChange) async {
        let path = selected
        await perform { try Git.unstage(path, change: change) } onSuccess: { _ in }
    }

    func sync(_ action: SyncAction) async {
        let path = selected
        await perform { try Git.sync(path, action: action) } onSuccess: { _ in }
    }

    func inspect(_ operation: @escaping @Sendable (String) throws -> String) async {
        let path = selected
        await perform { try operation(path) } onSuccess: { text in
            self.inspection = text
        }
    }

    func commit() async {
        let path = selected
        let message = drafts[path, default: ""]
        guard repos.contains(path), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await perform {
            try Git.commit(path, message: message)
        } onSuccess: { _ in
            self.drafts[path] = nil
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(excluded), forKey: "excludedRepositories")
        UserDefaults.standard.set(repos, forKey: "repositories")
        UserDefaults.standard.set(watchedFolders, forKey: "watchedFolders")
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value,
        onSuccess: (Value) -> Void
    ) async {
        guard !busy else { return }
        busy = true
        actionError = nil
        inspection = nil
        // Let an in-flight refresh finish before mutating the index.
        await refreshTask?.value
        let result = await Task.detached { Result(catching: operation) }.value
        switch result {
        case .success(let value): onSuccess(value)
        case .failure(let error): actionError = error.localizedDescription
        }
        busy = false
        await refresh()
    }
}

@MainActor
struct Dashboard: View {
    @State private var showAccount = false
    @ObservedObject var model: DashboardModel

    private var changes: [GitChange] { model.statuses[model.selected]?.changes ?? [] }
    private var hasConflict: Bool { changes.contains { $0.conflict } }
    private var stagedCount: Int { changes.filter(\.staged).count }
    private var unstagedCount: Int { changes.filter(\.unstaged).count }
    private var totalChangeCount: Int { model.statuses.values.reduce(0) { $0 + $1.changes.count } }
    private var repositoryName: String {
        URL(fileURLWithPath: model.selected).lastPathComponent
    }
    private var subtitle: String {
        guard !model.repos.isEmpty else { return "Your local Git dashboard" }
        let repositoryText = model.repos.count == 1 ? "1 repo" : "\(model.repos.count) repos"
        let changeText = totalChangeCount == 1 ? "1 change" : "\(totalChangeCount) changes"
        return "\(repositoryText) · \(changeText)"
    }
    private var message: Binding<String> {
        let path = model.selected
        return Binding(get: { model.drafts[path, default: ""] }, set: { model.drafts[path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if showAccount {
                ScrollView { AccountPanel().frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 360)
            } else if model.repos.isEmpty {
                emptyState
            } else {
                repositoryPicker
                if model.selected.isEmpty {
                    Text("Select a repository to inspect its changes and prepare a commit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    repositoryTools
                    summary
                    repositoryContents
                }
            }

            if !showAccount, let error = model.actionError ?? model.statusErrors[model.selected] {
                Label {
                    ScrollView { Text(error).font(.caption).textSelection(.enabled) }
                        .frame(maxHeight: 64)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            footer
        }
        .padding(16)
        .frame(width: 440)
        .task {
            await model.refresh()
        }
        .onChange(of: model.selected) { _ in
            model.actionError = nil
            model.inspection = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.needsAttention ? "arrow.triangle.branch" : "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(model.needsAttention ? Color.accentColor : .green)
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Git Stage").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(showAccount ? "Repositories" : "GitHub") { showAccount.toggle() }
                .disabled(model.busy)
            if !showAccount { addMenu }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Add a Repository…", action: chooseRepository)
            Button("Watch a Folder…", action: chooseWatchFolder)
            if !model.watchedFolders.isEmpty {
                Divider()
                Menu("Stop Watching Folder") {
                    ForEach(model.watchedFolders, id: \.self) { folder in
                        Button((folder as NSString).abbreviatingWithTildeInPath) {
                            model.stopWatching(folder)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .help("Add a repository or watch a folder")
        .accessibilityLabel("Add a repository or watch a folder")
        .disabled(model.busy)
    }

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Repositories")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(model.repos, id: \.self) { path in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                model.selected = model.selected == path ? "" : path
                            }
                        } label: {
                            RepositoryRow(
                                path: path,
                                changes: model.statuses[path]?.changes,
                                error: model.statusErrors[path],
                                isExpanded: model.selected == path
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(URL(fileURLWithPath: path).lastPathComponent), \(model.selected == path ? "expanded" : "collapsed")")
                        .disabled(model.busy)
                    }
                }
            }
            .frame(height: min(150, CGFloat(model.repos.count) * 53))
        }
    }

    @ViewBuilder private var repositoryTools: some View {
        if let status = model.statuses[model.selected] {
            HStack {
                Label(status.branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .lineLimit(1)
                    .help(status.branch)
                Spacer()
                Button("History") {
                    Task { await model.inspect { try Git.history($0) } }
                }
                Menu("Sync") {
                    ForEach(SyncAction.allCases, id: \.self) { action in
                        Button(action.rawValue) { Task { await model.sync(action) } }
                    }
                }
                .fixedSize()
            }
            .disabled(model.busy)
        }
        if let inspection = model.inspection {
            HStack(alignment: .top) {
                ScrollView {
                    Text(verbatim: inspection)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
                Button { model.inspection = nil } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close preview")
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            SummaryPill(icon: "checkmark.circle.fill", title: "Staged", value: stagedCount, tint: .green)
            SummaryPill(icon: "pencil.circle.fill", title: "Unstaged", value: unstagedCount, tint: .orange)
            if hasConflict {
                SummaryPill(icon: "exclamationmark.triangle.fill", title: "Conflicts", value: changes.filter(\.conflict).count, tint: .red)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Add your first repository").font(.headline)
            Text("Use + to add one checkout, or watch a folder to keep its Git repositories in view.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 30)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Updates every 5 seconds", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Refresh") { Task { await model.refresh() } }
                Button("Remove Repository") { model.removeSelected() }
                    .disabled(model.selected.isEmpty || model.busy)
                Divider()
                Button("Quit Git Stage") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More actions")
        }
    }

    private func chooseRepository() {
        let picker = NSOpenPanel()
        picker.title = "Add a Git Repository"
        picker.prompt = "Add"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        Task { await model.add(folder) }
    }

    private func chooseWatchFolder() {
        let picker = NSOpenPanel()
        picker.title = "Watch a Folder"
        picker.message = "Git Stage will find Git repositories in this folder and its direct subfolders."
        picker.prompt = "Watch"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        Task { await model.watch(folder) }
    }

    @ViewBuilder private var repositoryContents: some View {
        Text("Changes in \(repositoryName)")
            .font(.subheadline.weight(.semibold))
        if changes.isEmpty {
            if model.statuses[model.selected] != nil {
                Label("Working tree clean", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 82)
                    .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if model.statusErrors[model.selected] == nil {
                ProgressView("Checking repository…")
                    .frame(maxWidth: .infinity, minHeight: 82)
            }
        } else {
            if hasConflict {
                Label("Resolve merge conflicts before staging or committing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(changes) { change in
                        ChangeRow(change: change, label: statusLabel(for: change)) {
                            if change.unstaged {
                                Button("Stage File") { Task { await model.stage(change) } }
                            }
                            if change.staged {
                                Button("Unstage File") { Task { await model.unstage(change) } }
                            }
                            if change.canPreview {
                                if change.unstaged {
                                    Button("Show Unstaged Diff") {
                                        Task { await model.inspect { try Git.diff($0, change: change, staged: false) } }
                                    }
                                }
                                if change.staged {
                                    Button("Show Staged Diff") {
                                        Task { await model.inspect { try Git.diff($0, change: change, staged: true) } }
                                    }
                                }
                            }
                        }
                        .disabled(model.busy || change.conflict)
                    }
                }
                .padding(1)
            }
            .frame(height: min(model.inspection == nil ? 170 : 78, CGFloat(changes.count) * 42))
        }

        VStack(spacing: 10) {
            TextField("Commit message", text: message)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(model.busy)
            HStack {
                Button("Stage All in \(repositoryName)") { Task { await model.stage() } }
                    .disabled(model.busy || hasConflict || !changes.contains { $0.unstaged })
                Spacer()
                Button("Commit") { Task { await model.commit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || hasConflict || !changes.contains { $0.staged }
                        || message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statusLabel(for change: GitChange) -> String {
        if change.conflict { return "Conflict" }
        if change.staged && change.unstaged { return "Staged + unstaged" }
        return change.staged ? "Staged" : "Unstaged"
    }
}

@MainActor
private struct SummaryPill: View {
    let icon: String
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text("\(value)").font(.subheadline.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct ChangeRow<Actions: View>: View {
    let change: GitChange
    let label: String
    @ViewBuilder let actions: () -> Actions

    private var tint: Color {
        if change.conflict { return .red }
        return change.staged ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: change.conflict ? "exclamationmark.triangle.fill" : change.staged ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(change.path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(change.path)
            Spacer(minLength: 8)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.12), in: Capsule())
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(change.path)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

@MainActor
private struct RepositoryRow: View {
    let path: String
    let changes: [GitChange]?
    let error: String?
    let isExpanded: Bool

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }
    private var state: (text: String, icon: String, tint: Color) {
        if error != nil { return ("Unavailable", "exclamationmark.triangle.fill", .red) }
        guard let changes else { return ("Checking…", "arrow.triangle.2.circlepath", .secondary) }
        if changes.isEmpty { return ("Clean", "checkmark.circle.fill", .green) }
        let count = changes.count
        return (count == 1 ? "1 change" : "\(count) changes", "circle.fill", .orange)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.medium))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Label(state.text, systemImage: state.icon)
                .font(.caption)
                .foregroundStyle(state.tint)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isExpanded ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
