import SwiftUI

struct AccountSnapshot: Decodable, Sendable {
    struct PullRequest: Decodable, Identifiable {
        let title: String
        let number: Int
        let url: URL
        let repository: Repository
        struct Repository: Decodable { let nameWithOwner: String }
        var id: URL { url }
    }
    struct Requests: Decodable { let nodes: [PullRequest] }
    struct Contributions: Decodable {
        let totalContributions: Int
        let weeks: [Week]
        struct Week: Decodable { let contributionDays: [Day] }
        struct Day: Decodable { let contributionCount: Int }
    }
    struct Viewer: Decodable {
        let login: String
        let pullRequests: Requests
        let contributionsCollection: Collection
        struct Collection: Decodable { let contributionCalendar: Contributions }
    }
    let viewer: Viewer
    let reviews: Requests

    static func fetch() throws -> AccountSnapshot {
        let query = """
        query {
          viewer {
            login
            contributionsCollection {
              contributionCalendar { totalContributions weeks { contributionDays { contributionCount } } }
            }
            pullRequests(first: 10, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { ...pr }
            }
          }
          reviews: search(type: ISSUE, first: 10, query: "is:open is:pr review-requested:@me archived:false") {
            nodes { ... on PullRequest { ...pr } }
          }
        }
        fragment pr on PullRequest { title number url repository { nameWithOwner } }
        """
        struct Response: Decodable { let data: AccountSnapshot }
        let json = try Command.run("gh", ["api", "--hostname", "github.com", "graphql", "-f", "query=" + query])
        return try JSONDecoder().decode(Response.self, from: json).data
    }
}

@MainActor
struct AccountPanel: View {
    @State private var snapshot: AccountSnapshot?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.map { "@" + $0.viewer.login } ?? "GitHub").font(.headline)
                Spacer()
                Link("Notifications", destination: URL(string: "https://github.com/notifications")!)
                Button("Refresh") { Task { await refresh() } }.disabled(loading)
            }
            if loading { ProgressView().controlSize(.small) }
            if let error {
                Text(error).font(.caption).textSelection(.enabled)
                Text("GitHub access uses your gh auth login for github.com.").font(.caption)
            }
            if let snapshot {
                let calendar = snapshot.viewer.contributionsCollection.contributionCalendar
                Text("\(calendar.totalContributions) contributions in the last year").font(.caption)
                HStack(alignment: .top, spacing: 2) {
                    ForEach(calendar.weeks.indices, id: \.self) { week in
                        VStack(spacing: 2) {
                            let days = calendar.weeks[week].contributionDays
                            if week == 0 && days.count < 7 {
                                Color.clear.frame(width: 5, height: CGFloat(7 - days.count) * 7 - 2)
                            }
                            ForEach(days.indices, id: \.self) { day in
                                let count = days[day].contributionCount
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(count == 0 ? Color.secondary.opacity(0.18) : Color.green.opacity(min(1, 0.35 + Double(count) * 0.12)))
                                    .frame(width: 5, height: 5)
                                    .help("\(count) contributions")
                            }
                        }
                    }
                }
                requests("Review requested", snapshot.reviews.nodes)
                requests("Your open pull requests", snapshot.viewer.pullRequests.nodes)
            }
        }
        .task { if snapshot == nil { await refresh() } }
    }

    private func requests(_ title: String, _ items: [AccountSnapshot.PullRequest]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            if items.isEmpty { Text("None").font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { pr in
                Link("\(pr.repository.nameWithOwner)#\(pr.number)  \(pr.title)", destination: pr.url)
                    .font(.caption).lineLimit(1)
            }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await Task.detached { Result { try AccountSnapshot.fetch() } }.value
        switch result {
        case .success(let account):
            snapshot = account
            error = nil
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}
