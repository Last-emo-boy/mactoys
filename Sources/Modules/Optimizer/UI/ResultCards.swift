import AppKit
import MacToysCore
import SwiftUI

/// The stack of result cards in a screen corner.
struct ResultStackView: View {
    let center: JobCenter
    let corner: ScreenCorner
    /// Previews show the actions as if hovered.
    var forceActions = false
    var onSize: (CGSize) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 360
    static let maxCards = 5

    var body: some View {
        let cards = Array(center.cards.suffix(Self.maxCards))
        let ordered = corner.isTop ? cards.reversed() : cards
        VStack(alignment: corner.isLeft ? .leading : .trailing, spacing: 10) {
            ForEach(ordered) { item in
                Group {
                    switch item {
                    case .job(let job):
                        ResultCardView(job: job, center: center, showsActions: forceActions || center.pointerInside)
                    case .batch(let batch, let jobs):
                        BatchCardView(batch: batch, jobs: jobs, center: center, showsActions: forceActions || center.pointerInside)
                    }
                }
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .move(edge: corner.isLeft ? .leading : .trailing).combined(with: .opacity),
                                          removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .padding(16)
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: cards.map(\.id))
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: center.pointerInside)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }
}

/// One job: thumbnail, name, before → after and the saving; actions on hover.
struct ResultCardView: View {
    let job: OptimizationJob
    let center: JobCenter
    var showsActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                JobThumbnail(image: job.thumbnail, kind: job.kind, size: 56, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: job.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if job.isWorking || showsActions { closeButton }
                    }
                    status
                }
            }
            if showsActions, !job.isWorking, hasActions {
                actions.transition(.opacity)
            }
        }
        .padding(12)
        .frame(width: ResultStackView.width, alignment: .leading)
        .overlaySurface(cornerRadius: 22)
        .accessibilityElement(children: .contain)
    }

    private var closeButton: some View {
        Button {
            job.isWorking ? center.cancel(job) : center.dismiss(job)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(job.isWorking ? Text("Cancel", comment: "Optimizer card button: stop this job") : Text("Dismiss", comment: "Optimizer card button: close this card"))
        .accessibilityLabel(job.isWorking ? Text("Cancel", comment: "Optimizer card button: stop this job") : Text("Dismiss", comment: "Optimizer card button: close this card"))
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            line(Text("Waiting…", comment: "Optimizer: job is queued"), symbol: "clock")
        case .working(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(workingTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 4)
                    if let progress {
                        Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                SlimProgress(value: progress)
                HStack(spacing: 6) {
                    Text(verbatim: FileSize.format(job.originalSize))
                    if let left = job.remaining() {
                        Text(verbatim: "·")
                        Text("About \(Duration.seconds(left.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))) left",
                             comment: "Optimizer: time left while encoding a video; the value is a duration like '40 sec'")
                    }
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        case .done:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    SizeChange(before: job.originalSize, after: job.resultSize)
                    if let saving = job.saving { SavingBadge(saving: saving) }
                }
                Text(verbatim: job.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        case .unchanged:
            VStack(alignment: .leading, spacing: 4) {
                line(Text("Already optimized", comment: "Optimizer: the file couldn't be made smaller"), symbol: "checkmark.seal.fill", color: .white.opacity(0.85))
                Text("\(FileSize.format(job.originalSize)) · no smaller version found", comment: "Optimizer: the value is the file size")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.monochrome).foregroundStyle(Tint.orange.color)
                Text(verbatim: message).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
        case .cancelled:
            line(Text("Cancelled", comment: "Optimizer: the job was stopped"), symbol: "xmark.circle")
        case .restored:
            VStack(alignment: .leading, spacing: 4) {
                line(Text("Original restored", comment: "Optimizer: the optimized file was replaced by the original"),
                     symbol: "arrow.uturn.backward.circle.fill", color: .white.opacity(0.85))
                Text(verbatim: FileSize.format(job.originalSize))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var workingTitle: LocalizedStringKey {
        switch job.kind {
        case .video: job.isConversion ? "Converting to video…" : "Encoding video…"
        case .pdf: "Shrinking PDF…"
        case .image:
            switch job.operation {
            case .convert(let f): "Converting to \(f.title)…"
            case .downscale(let f): "Downscaling to \(f.formatted(.percent.precision(.fractionLength(0))))…"
            case .optimize: "Optimizing…"
            }
        }
    }

    private func line(_ text: Text, symbol: String, color: Color = .white.opacity(0.6)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical)
            text
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private var hasActions: Bool {
        job.state == .done || job.state == .unchanged || job.state == .restored
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if job.canRestore {
                CardIconButton(symbol: "arrow.uturn.backward", label: Text("Restore Original", comment: "Optimizer card action")) {
                    center.restore(job)
                }
            }
            if job.canDownscale {
                CardIconButton(symbol: "arrow.down.right.and.arrow.up.left", label: Text("Downscale More", comment: "Optimizer card action")) {
                    center.downscaleMore(job)
                }
            }
            if job.resultURL != nil {
                CardIconButton(symbol: "doc.on.doc", label: Text("Copy", comment: "Optimizer card action: copy the optimized file")) {
                    center.copy(job)
                }
            }
            if job.origin != .clipboard || job.resultURL != nil {
                CardIconButton(symbol: "folder", label: Text("Show in Finder", comment: "Optimizer card action")) { center.reveal(job) }
                CardIconButton(symbol: "arrow.up.forward.app", label: Text("Open", comment: "Optimizer card action: open the file")) { center.open(job) }
            }
            Spacer(minLength: 0)
            moreMenu
        }
        .padding(.leading, 68)
    }

    private var moreMenu: some View {
        Menu {
            if job.kind == .image {
                Menu("Convert To", content: {
                    ForEach(ImageFormat.writable, id: \.self) { f in
                        Button(f.title) { center.convert(job, to: f) }
                    }
                })
            }
            if job.kind == .video, !job.isConversion {
                let fast = (job.options.speed ?? 1) == 2
                Button {
                    var o = job.options
                    o.speed = fast ? 1 : 2
                    center.rerun(job, options: o)
                } label: {
                    fast ? Text("Normal Speed", comment: "Optimizer card menu: re-encode the video at its own speed")
                         : Text("Speed Up 2×", comment: "Optimizer card menu: re-encode the video twice as fast")
                }
                let muted = job.options.removeAudio ?? false
                Button {
                    var o = job.options
                    o.removeAudio = !muted
                    center.rerun(job, options: o)
                } label: {
                    muted ? Text("Keep Audio", comment: "Optimizer card menu: re-encode with sound")
                          : Text("Remove Audio", comment: "Optimizer card menu: re-encode without sound")
                }
            }
            Divider()
            Button("Dismiss All") { center.dismissAll() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.11)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More", comment: "Optimizer card: menu with more actions"))
    }
}

/// Several files from one drop or command: overall progress and savings, then the files.
struct BatchCardView: View {
    let batch: JobBatch
    let jobs: [OptimizationJob]
    let center: JobCenter
    var showsActions: Bool

    static let visibleRows = 5

    private var done: [OptimizationJob] { jobs.filter { !$0.isWorking } }
    private var before: Int64 { jobs.filter { $0.state == .done }.reduce(0) { $0 + $1.originalSize } }
    private var after: Int64 { jobs.filter { $0.state == .done }.reduce(0) { $0 + ($1.resultSize ?? $1.originalSize) } }
    private var working: Bool { jobs.contains(where: \.isWorking) }

    /// The rows worth seeing: files being worked on, then the latest finished, then those waiting.
    private var listed: [OptimizationJob] {
        let rank: (OptimizationJob) -> Int = { job in
            switch job.state {
            case .working: 0
            case .queued: 2
            default: 1
            }
        }
        let sorted = jobs.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            if ra == 1, let fa = a.element.finishedAt, let fb = b.element.finishedAt, fa != fb { return fa > fb }
            return a.offset < b.offset
        }
        return sorted.prefix(Self.visibleRows).map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tint.green.gradient)
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        (working ? Text("Optimizing \(jobs.count) files", comment: "Optimizer batch card title")
                                 : Text("\(jobs.count) files optimized", comment: "Optimizer batch card title"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 4)
                        if working || showsActions {
                            Button {
                                center.dismiss(batch: batch)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .help(working ? Text("Cancel All", comment: "Optimizer batch card button") : Text("Dismiss", comment: "Optimizer card button: close this card"))
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(done.count) of \(jobs.count) done", comment: "Optimizer batch progress: finished count of total")
                            .foregroundStyle(.white.opacity(0.6))
                        if before > 0 {
                            Text("\(FileSize.format(before - after)) saved", comment: "Optimizer batch: total bytes saved, e.g. '38 MB saved'")
                                .foregroundStyle(.white.opacity(0.85))
                            SavingBadge(saving: SizeGate.saving(original: before, result: after))
                        }
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                }
            }
            if working {
                SlimProgress(value: Double(done.count) / Double(max(1, jobs.count)))
            }
            VStack(spacing: 2) {
                ForEach(listed) { job in row(job) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
            if jobs.count > Self.visibleRows {
                Text("and \(jobs.count - Self.visibleRows) more", comment: "Optimizer batch card: files not listed")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 6)
            }
            if showsActions, !working {
                HStack(spacing: 8) {
                    if jobs.contains(where: \.canRestore) {
                        Button { center.restoreAll(in: batch) } label: {
                            Label { Text("Restore All", comment: "Optimizer batch card action") } icon: { Image(systemName: "arrow.uturn.backward") }
                        }
                        .buttonStyle(CapsuleButtonStyle())
                    }
                    Button {
                        let urls = jobs.compactMap { $0.resultURL ?? $0.fileURL }.filter { FileManager.default.fileExists(atPath: $0.path) }
                        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                    } label: {
                        Label { Text("Show in Finder", comment: "Optimizer card action") } icon: { Image(systemName: "folder") }
                    }
                    .buttonStyle(CapsuleButtonStyle())
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(width: ResultStackView.width, alignment: .leading)
        .overlaySurface(cornerRadius: 22)
    }

    private func row(_ job: OptimizationJob) -> some View {
        HStack(spacing: 10) {
            JobThumbnail(image: job.thumbnail, kind: job.kind, size: 28, cornerRadius: 6)
            Text(verbatim: job.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            switch job.state {
            case .done:
                Text(verbatim: FileSize.format(job.resultSize ?? job.originalSize))
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                if let s = job.saving { SavingBadge(saving: s) }
            case .working(let p):
                if let p { ProgressRing(value: p) } else { SpinnerRing() }
            case .queued:
                Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            case .unchanged:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .help(Text("Already optimized", comment: "Optimizer: the file couldn't be made smaller"))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).symbolRenderingMode(.monochrome).foregroundStyle(Tint.orange.color)
                    .help(Text(verbatim: message))
            case .cancelled, .restored:
                Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
    }
}

/// A tiny determinate progress ring for batch rows.
struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: min(1, max(0.02, value)))
                .stroke(Tint.green.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}

/// The ring's indeterminate twin: a short arc that turns (still with Reduce Motion).
struct SpinnerRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: 0.3)
                .stroke(Tint.green.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turning ? 270 : -90))
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityLabel(Text("Working", comment: "Optimizer: a file in a batch is being processed"))
    }
}

/// A small glass capsule button for card footers.
struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.11)))
            .contentShape(Capsule())
    }
}
