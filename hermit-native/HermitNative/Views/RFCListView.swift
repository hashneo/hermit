import SwiftUI

// MARK: - hermit-vj3: RFCListView — shared RFC catalog with filter chips

struct RFCListView: View {
    let rfcs: [RFC]
    @Binding var selectedRFC: RFC?
    var client: (any HermitClientProtocol)? = nil
    var onRefresh: (() async -> Void)? = nil

    enum Filter: String, CaseIterable {
        case all = "All"
        case mainBranch = "Published"
        case pullRequest = "In Review"
    }

    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var submitTarget: RFC? = nil

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
                    RFCRow(rfc: rfc, canSubmit: client != nil && rfc.lifecycleStatus == "draft") {
                        submitTarget = rfc
                    }
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
        .sheet(item: $submitTarget) { rfc in
            if let client {
                SubmitForReviewSheet(rfc: rfc, client: client) {
                    submitTarget = nil
                    Task { await onRefresh?() }
                }
            }
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
    var canSubmit: Bool = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
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

            Spacer()

            if canSubmit {
                Button {
                    onSubmit?()
                } label: {
                    Label("Submit for Review", systemImage: "paperplane")
                        .font(.caption)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Submit this draft RFC for review")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Submit for Review sheet

struct SubmitForReviewSheet: View {
    let rfc: RFC
    let client: any HermitClientProtocol
    let onDone: () -> Void

    @StateObject private var session: SubmitForReviewSession

    init(rfc: RFC, client: any HermitClientProtocol, onDone: @escaping () -> Void) {
        self.rfc = rfc
        self.client = client
        self.onDone = onDone
        _session = StateObject(wrappedValue: SubmitForReviewSession(client: client))
    }

    var body: some View {
        VStack(spacing: 20) {
            switch session.currentStep {
            case .idle:
                idleView

            case .success:
                successView

            case .failed:
                failedView

            default:
                progressView
            }
        }
        .padding(24)
        .frame(minWidth: 360, minHeight: 200)
    }

    // MARK: States

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "paperplane.circle")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Submit for Review")
                .font(.headline)
            Text("This will:\n• Rewrite the RFC status to **in-review**\n• Ensure the `hermit:rfc-ready` label exists\n• Create a review branch\n• Open a pull request")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel", role: .cancel) { onDone() }
                Button("Submit") {
                    Task { await session.submit(rfcID: rfc.id) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            ProgressView(value: session.progress)
            Text(session.currentStep.rawValue)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Submitted!")
                .font(.headline)
            if let result = session.result {
                Text("PR #\(result.prNumber) opened on branch `\(result.branch)`")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let url = URL(string: result.htmlURL) {
                    Link("View Pull Request →", destination: url)
                        .font(.subheadline)
                }
            }
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var failedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Submission Failed")
                .font(.headline)
            if let msg = session.errorMessage {
                Text(msg)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Cancel") { onDone() }
                Button("Retry") {
                    session.reset()
                    Task { await session.submit(rfcID: rfc.id) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
