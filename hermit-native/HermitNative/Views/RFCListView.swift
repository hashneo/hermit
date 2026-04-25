import SwiftUI

// MARK: - hermit-vj3: RFCListView — shared RFC catalog with filter chips

struct RFCListView: View {
    let rfcs: [RFC]
    @Binding var selectedRFC: RFC?
    var onRefresh: (() async -> Void)? = nil

    enum Filter: String, CaseIterable {
        case all = "All"
        case mainBranch = "Published"
        case pullRequest = "In Review"
    }

    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isRefreshing = false

    var filtered: [RFC] {
        rfcs.filter { rfc in
            let matchesFilter: Bool
            switch filter {
            case .all:         matchesFilter = true
            case .mainBranch:
                if case .mainBranch = rfc.source { matchesFilter = true }
                else { matchesFilter = false }
            case .pullRequest:
                if case .pullRequest = rfc.source { matchesFilter = true }
                else { matchesFilter = false }
            }
            let matchesSearch = searchText.isEmpty ||
                rfc.title.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        FilterChip(label: f.rawValue, isSelected: filter == f) {
                            filter = f
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No RFCs" : "No Results",
                    systemImage: "doc.text",
                    description: Text(searchText.isEmpty ? "No RFCs found." : "Try a different search term.")
                )
            } else {
                List(filtered, selection: $selectedRFC) { rfc in
                    RFCRow(rfc: rfc)
                        .tag(rfc)
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search RFCs")
        .refreshable {
            isRefreshing = true
            await onRefresh?()
            isRefreshing = false
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RFCRow: View {
    let rfc: RFC

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rfc.title)
                .font(.subheadline).fontWeight(.medium)
                .lineLimit(2)
            HStack(spacing: 6) {
                switch rfc.source {
                case .mainBranch:
                    Label("Published", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .pullRequest(let pr):
                    Label("PR #\(pr.number)", systemImage: "arrow.triangle.pull")
                        .foregroundStyle(.orange)
                    if pr.draft {
                        Text("Draft").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
