// Sources/UI/Properties/PropertiesViewModel.swift
import Foundation
import CoreGraphics
import Darwin
import UniformTypeIdentifiers
import Core
import MacxFS

/// What a Properties window shows (§5.8): one or more items, or a volume.
enum PropertiesSubject: Hashable {
    case items([URL])
    case volume(VolumeInfo)
}

/// Questions the view model asks its window before acting.
enum PropertiesConfirmation {
    case applyToEnclosed(name: String)
    case rename(RenamePrompt)
}

/// Name checks for the Properties name field (§5.6 rules). The duplicate test asks the file system on a read lane
/// (S5-C3), so hidden items count too (Review Focus 2).
enum NameAvailability {
    static func validate(_ proposed: String, original: String, in directory: URL, caseSensitive: Bool,
                         lanes: LanePool, volume: VolumeID) async -> NameValidation {
        let result = try? await lanes.perform(on: volume) { _ in
            NameRules.validate(proposed, original: original, caseSensitive: caseSensitive) { name in
                var st = Darwin.stat()
                return lstat(directory.appending(path: name).path, &st) == 0
            }
        }
        // An unresponsive lane can't answer: let the rename job report the real outcome.
        return result ?? .ok(warnings: [])
    }
}

/// State of one Properties window. Every read runs on a lane; every edit is a job (undoable, §6.6) whose failure
/// shows `inlineError` and reverts the control by reloading what is on disk.
@MainActor @Observable
final class PropertiesViewModel {
    enum Content: Equatable {
        case loading
        case item(ItemProperties)
        case items(MultiProperties)
        case volume(VolumeProperties)
        case failed(String)
    }

    private(set) var subject: PropertiesSubject
    private(set) var content: Content = .loading
    private(set) var folderCount: CountProgress?
    private(set) var defaultApp: AppInfo?
    var nameDraft = ""
    private(set) var nameProblem: String?
    private(set) var inlineError: String?
    private(set) var isApplying = false
    var icon: CGImage?
    /// The Access Control table (P4-18): one item only; nil for several items or a volume.
    private(set) var acl: ACLEditorModel?

    let environment: CoreEnvironment
    /// The window's number; jobs carry it so P1-38's router answers their errors inline.
    @ObservationIgnored var origin: OriginID?
    @ObservationIgnored var confirm: @MainActor (PropertiesConfirmation) async -> Bool = { _ in false }
    @ObservationIgnored var perform: @MainActor (JobRequest) async -> JobOutcome
    /// A finished job (ours, another window's, or undo/redo) changed our items' custom icons: the window drops its
    /// cached icon and fetches it again (P4-08).
    @ObservationIgnored var onIconChanged: (@MainActor () -> Void)?
    /// A rename (also by undo or another window) moved our items: the window updates its key and title.
    @ObservationIgnored var onSubjectChanged: (@MainActor (PropertiesSubject) -> Void)?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var finishedToken: ObserverToken?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadedName: String?

    init(subject: PropertiesSubject, environment: CoreEnvironment) {
        self.subject = subject
        self.environment = environment
        let operations = environment.operations
        perform = { request in await operations.perform(request) }
        finishedToken = operations.onFinished { [weak self] _, outcome in self?.jobFinished(outcome) }
    }

    var urls: [URL] {
        if case .items(let urls) = subject { urls } else { [] }
    }

    var title: String {
        switch subject {
        case .volume(let volume): String(format: L10n.string("%@ Properties"), volume.name)
        case .items(let urls) where urls.count == 1: String(format: L10n.string("%@ Properties"), urls[0].lastPathComponent)
        case .items(let urls): String(format: L10n.string("%lld Items Properties"), urls.count)
        }
    }

    var canEditPermissions: Bool {
        if case .item(let item) = content { item.isOwnedByCurrentUser } else { false }
    }

    /// §5.8: single documents only; folders and applications have no Opens with.
    var showsOpensWith: Bool {
        guard case .item(let item) = content, item.kind != .directory else { return false }
        return !(UTType(item.typeIdentifier)?.conforms(to: .application) ?? false)
    }

    /// The icon well takes drops and pastes (P4-08): items (not a volume, no symlink) on a writable volume.
    var canEditIcon: Bool {
        switch content {
        case .item(let item): item.kind != .symlink && !isOnReadOnlyVolume
        case .items(let multi): multi.symlinks == 0 && !isOnReadOnlyVolume
        case .loading, .volume, .failed: false
        }
    }

    /// "Remove Custom Icon" is offered (any selected item has one).
    var hasCustomIcon: Bool {
        switch content {
        case .item(let item): item.hasCustomIcon
        case .items(let multi): multi.customIcon != .off
        case .loading, .volume, .failed: false
        }
    }

    private var isOnReadOnlyVolume: Bool {
        guard let first = urls.first else { return true }
        return environment.volumes.volume(for: first)?.isReadOnly ?? false
    }

    static func permissionsNote(isOwner: Bool) -> String? {
        isOwner ? nil : L10n.string("You can't change permissions because you aren't the owner.")
    }

    // MARK: loading

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let lanes = environment.lanes
        let loaded: Content
        switch subject {
        case .volume(let info):
            loaded = .volume(await PropertiesLoader.loadVolume(info, scanner: SystemVolumeScanner(), lanes: lanes))
        case .items(let urls) where urls.count == 1:
            do { loaded = .item(try await PropertiesLoader.load(urls[0], lanes: lanes, volume: volumeID(urls[0]))) }
            catch { loaded = .failed(Self.loadError(error, name: urls[0].lastPathComponent)) }
        case .items(let urls):
            guard let first = urls.first else { return }
            do { loaded = .items(try await PropertiesLoader.loadMany(urls, lanes: lanes, volume: volumeID(first))) }
            catch { loaded = .failed(Self.loadError(error, name: first.lastPathComponent)) }
        }
        guard generation == loadGeneration else { return }     // a newer load won
        content = loaded
        guard case .item(let item) = loaded else {
            acl?.close()
            acl = nil
            return
        }
        if nameDraft == (loadedName ?? "") { nameDraft = item.name }   // don't clobber a name being typed
        loadedName = item.name
        await loadACL(item)
        if item.kind == .directory || item.kind == .package {
            if folderCount == nil { startCount(item.url) }
            if item.kind == .package, showsOpensWith { await reloadDefaultApp() }
        } else if showsOpensWith {
            await reloadDefaultApp()
        }
    }

    /// Builds the table for this item (again after a rename or an ownership change) and reloads its entries.
    private func loadACL(_ item: ItemProperties) async {
        let isDirectory = item.kind == .directory || item.kind == .package
        if let acl, acl.url == item.url, acl.isEditable == item.isOwnedByCurrentUser, acl.isDirectory == isDirectory {
            await acl.load()
            return
        }
        acl?.close()
        let model = ACLEditorModel(url: item.url, isDirectory: isDirectory, isEditable: item.isOwnedByCurrentUser,
                                   environment: environment)
        model.origin = { [weak self] in self?.origin }
        let operations = environment.operations
        model.perform = { [weak self] request in
            if let self { return await self.perform(request) }
            return await operations.perform(request)
        }
        acl = model
        await model.load()
    }

    func reloadDefaultApp() async {
        guard case .item(let item) = content else { return }
        defaultApp = await environment.launchServices.provider.defaultApplication(toOpen: item.url)
    }

    private func startCount(_ url: URL) {
        countTask?.cancel()
        let stream = FolderCounter.count(url, lanes: environment.lanes, volume: volumeID(url))
        countTask = Task { [weak self] in
            for await progress in stream {
                guard let self, !Task.isCancelled else { return }
                self.folderCount = progress
            }
        }
    }

    private func volumeID(_ url: URL) -> VolumeID {
        environment.volumes.volume(for: url)?.id ?? .unknown
    }

    static func loadError(_ error: any Error, name: String) -> String {
        let code: Int32 = if let failure = error as? ReadFailure { failure.code }
            else if (error as NSError).domain == NSPOSIXErrorDomain { Int32((error as NSError).code) }
            else { 0 }
        return code == ENOENT ? ErrorText.jobError(.sourceGone, name: name) : String(format: L10n.string("'%@' couldn't be read."), name)
    }

    /// Follows renames and moves of our items (inline, from another window, or by undo) and reloads when a finished
    /// job touched them, so the controls always show what is on disk.
    private func jobFinished(_ outcome: JobOutcome) {
        guard case .items(let current) = subject else { return }
        var mapped = current
        var touched = false
        var iconTouched = false
        for action in outcome.record.actions {
            switch action {
            case .renamed(let from, let to, _), .moved(let from, let to, _):
                if let index = mapped.firstIndex(of: from.standardizedFileURL) {
                    mapped[index] = to.standardizedFileURL
                    touched = true
                }
            case .attributesChanged(let url, _, _), .modeChanged(let url, _, _):
                if mapped.contains(url.standardizedFileURL) { touched = true }
            case .customIconChanged(let url, _, _):
                if mapped.contains(url.standardizedFileURL) { touched = true; iconTouched = true }
            default:
                break
            }
        }
        if mapped != current {
            subject = .items(mapped)
            onSubjectChanged?(subject)
        }
        if iconTouched { onIconChanged?() }
        if touched { Task { await self.load() } }
    }

    // MARK: edits (§5.8: apply immediately, undoable, inline error + revert)

    func setLocked(_ on: Bool) async {
        await applyAttribute(.locked(on), item: { $0.isLocked = on }, multi: { $0.locked = Tri(on) })
    }

    func setHidden(_ on: Bool) async {
        await applyAttribute(.hidden(on), item: { $0.isHidden = on }, multi: { $0.hidden = Tri(on) })
    }

    func setExtensionHidden(_ on: Bool) async {
        await applyAttribute(.extensionHidden(on), item: { $0.isExtensionHidden = on }, multi: { $0.extensionHidden = Tri(on) })
    }

    func removeQuarantine() async {
        await applyAttribute(.removeQuarantine, item: { $0.quarantine = nil }, multi: { _ in })
    }

    /// The icon well's drop or paste, or "Remove Custom Icon" (nil): one job for every selected item (P4-08).
    func setCustomIcon(_ data: IconImageData?) async {
        guard canEditIcon else { return }
        await run(.setCustomIcon(urls, data), revertTo: content)
    }

    func setAccess(_ access: PermissionAccess, for who: PermissionClass) async {
        guard case .item(var item) = content, item.isOwnedByCurrentUser else { return }
        let mode = PermissionModel.applying(access, who, to: item.mode,
                                              isDirectory: item.kind == .directory || item.kind == .package)
        guard mode != item.mode else { return }
        let before = content
        item.mode = mode
        content = .item(item)
        await run(.setAttributes(urls, .permissions(mode & 0o7777)), revertTo: before)
    }

    /// Folders: confirmed, then one chmodRecursive job with the folder's access levels: folders get r/w plus x, files
    /// only the r/w bits and keep their own x bits (undo restores each item's mode).
    func applyPermissionsToEnclosed() async {
        guard case .item(let item) = content, item.kind == .directory, item.isOwnedByCurrentUser,
              await confirm(.applyToEnclosed(name: item.name)) else { return }
        let change = ModeChange(mode: PermissionModel.directoryMode(item.mode) & 0o777, keepsFileExecuteBits: true)
        await run(.chmodRecursive(item.url, change), revertTo: content)
    }

    /// Return in the name field. False when the name is refused (problem shown under the field) or declined.
    @discardableResult
    func commitName() async -> Bool {
        guard case .item(let item) = content else { return false }
        let proposed = nameDraft
        guard proposed != item.name else { nameProblem = nil; return true }
        let caseSensitive = environment.volumes.volume(for: item.url)?.capabilities.caseSensitive ?? false
        let validation = await NameAvailability.validate(proposed, original: item.name, in: item.url.deletingLastPathComponent(),
                                                         caseSensitive: caseSensitive, lanes: environment.lanes,
                                                         volume: volumeID(item.url))
        switch validation {
        case .invalid(let problem):
            nameProblem = ErrorText.renameProblem(problem, name: proposed)
            return false
        case .ok(let warnings):
            nameProblem = nil
            for warning in warnings {
                let prompt: RenamePrompt = switch warning {
                case .extensionChanged(let from, let to): .extensionChanged(from: from, to: to)
                case .becomesHidden: .becomesHidden
                }
                guard await confirm(.rename(prompt)) else { nameDraft = item.name; return false }
            }
        }
        return await run(.rename(item.url, to: proposed), revertTo: content) { [weak self] in self?.nameDraft = item.name }
    }

    /// Esc in the name field.
    func revertName() {
        guard case .item(let item) = content else { return }
        nameDraft = item.name
        nameProblem = nil
    }

    func eject() async -> Bool {
        guard case .volume(let info) = subject else { return false }
        do throws(EjectError) {
            try await environment.ejectCoordinator.eject(info)
            return true
        } catch {
            switch error {
            case .busy(let processes) where !processes.isEmpty:
                inlineError = String(format: L10n.string("'%@' can't be ejected because it is in use by %@."), info.name,
                                     ListFormatter.localizedString(byJoining: processes))
            default:
                inlineError = String(format: L10n.string("“%@” couldn't be ejected."), info.name)
            }
            return false
        }
    }

    func close() {
        acl?.close()
        countTask?.cancel()
        countTask = nil
        finishedToken?.cancel()
        finishedToken = nil
    }

    // MARK: private

    private func applyAttribute(_ edit: AttributeEdit, item change: (inout ItemProperties) -> Void,
                                multi changeAll: (inout MultiProperties) -> Void) async {
        let before = content
        switch content {
        case .item(var item): change(&item); content = .item(item)
        case .items(var multi): changeAll(&multi); content = .items(multi)
        default: return
        }
        await run(.setAttributes(urls, edit), revertTo: before)
    }

    /// Runs one job for the window. A skipped item with a reason (the router answers Properties errors with Skip,
    /// P1-38) becomes the inline error; the control reverts and the window reloads from disk either way.
    @discardableResult
    private func run(_ kind: JobKind, revertTo before: Content, onFailure: (() -> Void)? = nil) async -> Bool {
        isApplying = true
        inlineError = nil
        defer { isApplying = false }
        let outcome = await perform(JobRequest(kind, origin: origin))
        var succeeded = !outcome.wasCancelled
        if let failed = outcome.skipped.first(where: { $0.reason != nil }), let reason = failed.reason {
            inlineError = ErrorText.jobError(reason, name: failed.url.lastPathComponent, verb: outcome.record.verb)
            succeeded = false
        }
        if !succeeded {
            content = before
            onFailure?()
        }
        await load()
        return succeeded
    }
}
