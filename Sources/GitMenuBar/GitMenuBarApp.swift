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
        Image(systemName: model.icon)
            .accessibilityLabel(Text(model.iconDescription))
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var repos = UserDefaults.standard.stringArray(forKey: "repositories") ?? []
    @Published private(set) var statuses: [String: [GitChange]] = [:]
    @Published private(set) var statusErrors: [String: String] = [:]
    @Published private(set) var busy = false
    @Published var selected = ""
    @Published var actionError: String?
    @Published var drafts: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?

    var needsAttention: Bool { statuses.values.contains { !$0.isEmpty } }
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
        let task = Task {
            let results = await Task.detached(priority: .utility) {
                paths.map { path in (path, Result { try Git.status(path) }) }
            }.value
            for (path, result) in results where repos.contains(path) {
                switch result {
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
            if !self.repos.contains(root) {
                self.repos.append(root)
                self.save()
            }
            self.selected = root
        }
    }

    func removeSelected() {
        guard !busy else { return }
        let path = selected
        repos.removeAll { $0 == path }
        statuses[path] = nil
        statusErrors[path] = nil
        drafts[path] = nil
        actionError = nil
        selected = repos.first ?? ""
        save()
    }

    func stage() async {
        let path = selected
        guard repos.contains(path) else { return }
        await perform { try Git.stage(path) } onSuccess: { _ in }
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
        UserDefaults.standard.set(repos, forKey: "repositories")
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value,
        onSuccess: (Value) -> Void
    ) async {
        guard !busy else { return }
        busy = true
        actionError = nil
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
    @ObservedObject var model: DashboardModel

    private var changes: [GitChange] { model.statuses[model.selected] ?? [] }
    private var hasConflict: Bool { changes.contains { $0.conflict } }
    private var message: Binding<String> {
        let path = model.selected
        return Binding(get: { model.drafts[path, default: ""] }, set: { model.drafts[path] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if !model.repos.isEmpty {
                    Picker("Repository", selection: $model.selected) {
                        ForEach(model.repos, id: \.self) { path in
                            Text((path as NSString).abbreviatingWithTildeInPath).tag(path)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Repository")
                    .disabled(model.busy)
                } else {
                    Text("Git Stage").font(.headline)
                    Spacer()
                }
                Button(action: chooseFolder) label: { Image(systemName: "plus") }
                    .help("Add a repository")
                    .accessibilityLabel("Add a repository")
                    .disabled(model.busy)
            }

            if model.repos.isEmpty {
                Text("Add a local Git checkout to see changes and commit from the menu bar.")
                    .foregroundStyle(.secondary)
            } else {
                repositoryContents
            }

            if let error = model.actionError ?? model.statusErrors[model.selected] {
                ScrollView {
                    Text(error).font(.caption).foregroundStyle(Color.red).textSelection(.enabled)
                }
                .frame(maxHeight: 85)
            }

            Divider()
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Menu {
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Remove Repository") { model.removeSelected() }
                        .disabled(model.selected.isEmpty || model.busy)
                    Divider()
                    Button("Quit Git Stage") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .fixedSize()
                .accessibilityLabel("More actions")
            }
        }
        .padding(14)
        .frame(width: 390)
        .task {
            if model.selected.isEmpty { model.selected = model.repos.first ?? "" }
            await model.refresh()
        }
        .onChange(of: model.selected) { _ in model.actionError = nil }
    }

    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Add a Git Repository"
        picker.prompt = "Add"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let folder = picker.url else { return }
        Task { await model.add(folder) }
    }

    @ViewBuilder private var repositoryContents: some View {
        if changes.isEmpty {
            if model.statuses[model.selected] != nil {
                Label("Working tree clean", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else if model.statusErrors[model.selected] == nil {
                Text("Checking repository…").foregroundStyle(.secondary)
            }
        } else {
            if hasConflict {
                Text("Resolve merge conflicts before staging or committing.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(changes) { change in
                        HStack {
                            Text(change.path).lineLimit(1).truncationMode(.middle).help(change.path)
                            Spacer()
                            Text(statusLabel(for: change)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(170, CGFloat(changes.count) * 22))
        }

        TextField("Commit message", text: message)
            .disabled(model.busy)
        HStack {
            Button("Stage All") { Task { await model.stage() } }
                .disabled(model.busy || hasConflict || !changes.contains { $0.unstaged })
            Spacer()
            Button("Commit") { Task { await model.commit() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || hasConflict || !changes.contains { $0.staged }
                    || message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func statusLabel(for change: GitChange) -> String {
        if change.conflict { return "Conflict" }
        if change.staged && change.unstaged { return "Staged + unstaged" }
        return change.staged ? "Staged" : "Unstaged"
    }
}
