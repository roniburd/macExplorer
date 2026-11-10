import SwiftUI
import Core

/// §6.2 job titles from Core's typed JobDescription: "Copying 1,204 items from Downloads to Backup".
@MainActor
enum JobTitle {
    static func title(_ description: JobDescription, locale: Locale = .current) -> String {
        let what = subject(description, locale: locale)
        let from = description.sourceFolderName, to = description.destinationFolderName
        switch description.verb {
        case .copying:
            return route(L10n.string("Copying %@"), L10n.string("Copying %@ to %@"), L10n.string("Copying %@ from %@ to %@"), what, from, to)
        case .moving:
            return route(L10n.string("Moving %@"), L10n.string("Moving %@ to %@"), L10n.string("Moving %@ from %@ to %@"), what, from, to)
        case .duplicating: return String(format: L10n.string("Duplicating %@"), what)
        case .trashing: return String(format: L10n.string("Moving %@ to the Trash"), what)
        case .deleting: return String(format: L10n.string("Deleting %@"), what)
        case .creating:
            return to.map { String(format: L10n.string("Creating %@ in %@"), what, $0) } ?? String(format: L10n.string("Creating %@"), what)
        case .renaming: return String(format: L10n.string("Renaming %@"), what)
        case .makingAlias: return String(format: L10n.string("Making an alias of %@"), what)
        case .makingSymlink: return String(format: L10n.string("Making a symbolic link to %@"), what)
        case .changingPermissions: return String(format: L10n.string("Changing permissions of %@"), what)
        case .changingAttributes: return String(format: L10n.string("Changing attributes of %@"), what)
        case .tagging: return String(format: L10n.string("Tagging %@"), what)
        case .changingIcon: return String(format: L10n.string("Changing the icon of %@"), what)
        case .compressing: return String(format: L10n.string("Compressing %@"), what)
        case .undoing: return String(format: L10n.string("Undoing changes to %@"), what)
        case .redoing: return String(format: L10n.string("Redoing changes to %@"), what)
        }
    }

    /// "'a.txt'" for one named item, otherwise "1,204 items".
    static func subject(_ description: JobDescription, locale: Locale = .current) -> String {
        if description.itemCount == 1, let name = description.firstItemName { return String(format: L10n.string("'%@'"), name) }
        if description.itemCount == 1 { return L10n.string("1 item") }
        return String(format: L10n.string("%@ items"), description.itemCount.formatted(.number.locale(locale)))
    }

    private static func route(_ plain: String, _ toOnly: String, _ fromTo: String, _ what: String, _ from: String?, _ to: String?) -> String {
        switch (from, to) {
        case (let from?, let to?): String(format: fromTo, what, from, to)
        case (nil, let to?): String(format: toOnly, what, to)
        default: String(format: plain, what)
        }
    }
}

/// Everything one job row shows (§6.2), computed from a snapshot.
struct JobRowModel: Equatable, Identifiable {
    let id: JobID
    let title: String
    let fraction: Double?
    let countText: String?          // "12 of 1,204"
    let bytesText: String?          // "1.2 MB of 3 GB"
    let speedText: String?          // "12 MB/s", running only
    let etaText: String?            // "About 2 minutes remaining", running only
    let statusText: String?         // Preparing…, Paused, Waiting for your answer, …
    let currentItem: String?
    let graph: [Double]             // 0…1, oldest first
    let isWaiting: Bool
    let canPause: Bool
    let canResume: Bool
    let canCancel: Bool

    @MainActor
    init(_ job: JobSnapshot, locale: Locale = .current) {
        let progress = job.progress
        let running = job.state == .running
        id = job.id
        title = JobTitle.title(job.description, locale: locale)
        fraction = progress.fraction
        countText = progress.itemsTotal.map {
            String(format: L10n.string("%@ of %@"), progress.itemsDone.formatted(.number.locale(locale)), $0.formatted(.number.locale(locale)))
        }
        bytesText = progress.bytesTotal.flatMap { total in
            total > 0 ? String(format: L10n.string("%@ of %@"), Formatters.bytes(progress.bytesDone), Formatters.bytes(total)) : nil
        }
        speedText = running ? progress.throughput.last.flatMap { $0 > 0 ? String(format: L10n.string("%@/s"), Formatters.bytes(Int64($0))) : nil } : nil
        etaText = running ? progress.estimatedRemaining.map { Self.eta($0, locale: locale) } : nil
        statusText = switch job.state {
        case .queued: L10n.string("Waiting to start…")
        case .planning: L10n.string("Preparing…")
        case .paused: L10n.string("Paused")
        case .waitingForUser: L10n.string("Waiting for your answer")
        case .cancelling: L10n.string("Cancelling…")
        case .running, .finished: nil
        }
        currentItem = progress.currentItem
        graph = ThroughputGraph.normalized(progress.throughput)
        isWaiting = job.state == .waitingForUser
        canPause = job.state == .queued || job.state == .planning || job.state == .running
        canResume = job.state == .paused
        canCancel = job.state != .cancelling && job.state != .finished
    }

    @MainActor
    static func eta(_ remaining: Duration, locale: Locale = .current) -> String {
        let seconds = max(1, Int(remaining.components.seconds))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        return String(format: L10n.string("About %@ remaining"), formatter.string(from: TimeInterval(seconds)) ?? "")
    }
}

/// The 60-sample throughput graph (§6.2).
enum ThroughputGraph {
    static func normalized(_ samples: [Double]) -> [Double] {
        guard let peak = samples.max(), peak > 0 else { return samples.map { _ in 0 } }
        return samples.map { max(0, $0) / peak }
    }

    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
        }
    }

    static func path(_ values: [Double], in size: CGSize) -> Path {
        var path = Path()
        path.addLines(points(values, in: size))
        return path
    }
}

struct JobActions {
    var pause: @MainActor (JobID) -> Void
    var resume: @MainActor (JobID) -> Void
    var cancel: @MainActor (JobID) -> Void
    var showQuestion: @MainActor (JobID) -> Void
}

/// The job list shared by the capsule's popover and Window › Operations (§6.2, §6.7). `visibleJobs` hides jobs
/// younger than 1 s; the timeline re-evaluates it as time passes.
struct OperationsListView: View {
    let operations: OperationsCenter
    let actions: JobActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let jobs = operations.visibleJobs
            if jobs.isEmpty {
                Text(verbatim: L10n.string("No operations"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(jobs) { job in
                            JobRowView(model: JobRowModel(job), actions: actions)
                            if job.id != jobs.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 80, idealHeight: 260)
    }
}

struct JobRowView: View {
    let model: JobRowModel
    let actions: JobActions
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isWaiting {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityLabel(L10n.string("Waiting for your answer"))
                }
                Text(verbatim: model.title).lineLimit(2)
                Spacer()
                if model.canPause {
                    Button { actions.pause(model.id) } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Pause"))
                }
                if model.canResume {
                    Button { actions.resume(model.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Resume"))
                }
                if model.canCancel {
                    Button { actions.cancel(model.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel(L10n.string("Cancel"))
                }
            }
            if let fraction = model.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(verbatim: model.statusText ?? model.countText ?? "")
                Spacer()
                if let speed = model.speedText { Text(verbatim: speed) }
                if let eta = model.etaText { Text(verbatim: eta) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.isWaiting {
                Button(L10n.string("Show")) { actions.showQuestion(model.id) }.controlSize(.small)
            }
            if model.graph.count > 1 {
                GeometryReader { geometry in
                    ThroughputGraph.path(model.graph, in: geometry.size).stroke(Color.accentColor, lineWidth: 1)
                }
                .frame(height: 28)
                .accessibilityHidden(true)
            }
            DisclosureGroup(L10n.string("More details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    if let item = model.currentItem { Text(verbatim: item).lineLimit(1).truncationMode(.middle) }
                    if let count = model.countText { Text(verbatim: count) }
                    if let bytes = model.bytesText { Text(verbatim: bytes) }
                }
                .font(.caption)
            }
        }
    }
}
