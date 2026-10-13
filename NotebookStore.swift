import Foundation
import SwiftUI

/// Coordinated file access, required for files that live in the iCloud container.
enum FileIO {
    static func read(_ url: URL) -> Data? {
        var result: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    static func write(_ data: Data, to url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { u in
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u, options: .atomic)
        }
    }

    static func remove(_ url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }
}

/// Owns all notebooks. Data lives in the iCloud Drive container when available, otherwise in the app's local Documents folder.
///
/// Layout on disk:
///   Notebooks/<notebookID>/notebook.json        (names, sections, page list)
///   Notebooks/<notebookID>/pages/<pageID>.json   (ink and images for one page)
@MainActor
final class NotebookStore: ObservableObject {
    @Published private(set) var notebooks: [Notebook] = []
    @Published private(set) var isUsingICloud = false
    @Published private(set) var isReady = false

    private var rootURL: URL
    private var query: NSMetadataQuery?
    private var pending: [UUID: (notebookID: UUID, content: PageContent)] = [:]
    private var saveTask: Task<Void, Never>?
    private let ioQueue = DispatchQueue(label: "notetaker.io", qos: .utility)

    init() {
        rootURL = Self.localRoot()
        Task { await bootstrap() }
    }

    // MARK: Setup

    private static func localRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var notebooksURL: URL { rootURL.appendingPathComponent("Notebooks", isDirectory: true) }
    private func notebookURL(_ id: UUID) -> URL { notebooksURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func metaURL(_ id: UUID) -> URL { notebookURL(id).appendingPathComponent("notebook.json") }
    private func pageURL(_ notebookID: UUID, _ pageID: UUID) -> URL {
        notebookURL(notebookID).appendingPathComponent("pages", isDirectory: true).appendingPathComponent("\(pageID.uuidString).json")
    }

    private func bootstrap() async {
        // Asking for the iCloud container and moving files into it can block, so do both off the main thread.
        let localNotebooks = Self.localRoot().appendingPathComponent("Notebooks", isDirectory: true)
        let cloud: URL? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                guard let docs = fm.url(forUbiquityContainerIdentifier: nil)?
                    .appendingPathComponent("Documents", isDirectory: true) else {
                    continuation.resume(returning: nil)
                    return
                }
                try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
                Self.migrateLocalNotebooks(from: localNotebooks, to: docs)
                continuation.resume(returning: docs)
            }
        }
        if let cloud {
            rootURL = cloud
            isUsingICloud = true
            startWatching()
        }
        reloadNotebooks()
        isReady = true
    }

    /// Moves notebooks created before iCloud was available into the iCloud container.
    private nonisolated static func migrateLocalNotebooks(from local: URL, to cloud: URL) {
        let fm = FileManager.default
        let destination = cloud.appendingPathComponent("Notebooks", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil), !items.isEmpty else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                // setUbiquitous is the supported way to move an item into the iCloud container.
                try? fm.setUbiquitous(true, itemAt: item, destinationURL: target)
            }
        }
    }

    /// Reads on the same serial queue as the writes, so a save that is still in flight is never missed.
    private func reloadNotebooks() {
        let folder = notebooksURL
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var loaded: [Notebook] = []
            for dir in dirs {
                let meta = dir.appendingPathComponent("notebook.json")
                if let data = FileIO.read(meta), let nb = try? JSONDecoder().decode(Notebook.self, from: data) {
                    loaded.append(nb)
                }
            }
            loaded.sort { $0.createdAt < $1.createdAt }
            Task { @MainActor [weak self] in self?.notebooks = loaded }
        }
    }

    // MARK: iCloud change watching

    private func startWatching() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.queryChanged() }
            }
        }
        q.start()
        query = q
    }

    private func queryChanged() {
        guard let q = query else { return }
        q.disableUpdates()
        for case let item as NSMetadataItem in q.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String else { continue }
            if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        q.enableUpdates()
        reloadNotebooks()
    }

    // MARK: Lookup

    func notebook(id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    // MARK: Notebook changes

    @discardableResult
    func createNotebook(name: String) -> Notebook {
        var nb = Notebook(name: cleaned(name, fallback: "Untitled Notebook"))
        var section = NotebookSection(name: "Section 1")
        section.pages = [PageInfo(name: "Page 1")]
        nb.sections = [section]
        notebooks.append(nb)
        persistMeta(nb)
        return nb
    }

    func renameNotebook(_ id: UUID, to name: String) {
        mutate(id) { $0.name = cleaned(name, fallback: $0.name) }
    }

    func deleteNotebook(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        pending = pending.filter { $0.value.notebookID != id }
        let url = notebookURL(id)
        ioQueue.async { FileIO.remove(url) }
    }

    // MARK: Section changes

    @discardableResult
    func addSection(to notebookID: UUID, name: String) -> NotebookSection? {
        var created: NotebookSection?
        mutate(notebookID) { nb in
            var section = NotebookSection(name: cleaned(name, fallback: "Section \(nb.sections.count + 1)"))
            section.pages = [PageInfo(name: "Page 1")]
            nb.sections.append(section)
            created = section
        }
        return created
    }

    func renameSection(notebookID: UUID, sectionID: UUID, to name: String) {
        mutate(notebookID) { nb in
            guard let i = nb.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            nb.sections[i].name = cleaned(name, fallback: nb.sections[i].name)
        }
    }

    func deleteSection(notebookID: UUID, sectionID: UUID) {
        guard let nb = notebook(id: notebookID), let section = nb.sections.first(where: { $0.id == sectionID }) else { return }
        for page in section.pages { removePageFile(notebookID: notebookID, pageID: page.id) }
        mutate(notebookID) { $0.sections.removeAll { $0.id == sectionID } }
    }

    // MARK: Page changes

    @discardableResult
    func addPage(notebookID: UUID, sectionID: UUID, name: String) -> PageInfo? {
        var created: PageInfo?
        mutate(notebookID) { nb in
            guard let i = nb.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            let page = PageInfo(name: cleaned(name, fallback: "Page \(nb.sections[i].pages.count + 1)"))
            nb.sections[i].pages.append(page)
            created = page
        }
        return created
    }

    func renamePage(notebookID: UUID, sectionID: UUID, pageID: UUID, to name: String) {
        mutate(notebookID) { nb in
            guard let s = nb.sections.firstIndex(where: { $0.id == sectionID }),
                  let p = nb.sections[s].pages.firstIndex(where: { $0.id == pageID }) else { return }
            nb.sections[s].pages[p].name = cleaned(name, fallback: nb.sections[s].pages[p].name)
        }
    }

    func deletePage(notebookID: UUID, sectionID: UUID, pageID: UUID) {
        removePageFile(notebookID: notebookID, pageID: pageID)
        mutate(notebookID) { nb in
            guard let s = nb.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            nb.sections[s].pages.removeAll { $0.id == pageID }
        }
    }

    func movePages(notebookID: UUID, sectionID: UUID, from: IndexSet, to: Int) {
        mutate(notebookID) { nb in
            guard let s = nb.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            nb.sections[s].pages.move(fromOffsets: from, toOffset: to)
        }
    }

    // MARK: Page content

    func loadPage(notebookID: UUID, pageID: UUID) -> PageContent {
        // A page edited a moment ago may not be on disk yet.
        if let item = pending[pageID] { return item.content }
        guard let data = FileIO.read(pageURL(notebookID, pageID)),
              let content = try? JSONDecoder().decode(PageContent.self, from: data) else { return PageContent() }
        return content
    }

    /// Queues a save. Rapid edits are merged and written about 0.7 seconds after the last one.
    func scheduleSave(notebookID: UUID, pageID: UUID, content: PageContent) {
        pending[pageID] = (notebookID, content)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes any queued page changes right away. Called when switching pages and when the app goes to the background.
    func flush() {
        let items = pending
        pending.removeAll()
        for (pageID, item) in items {
            let url = pageURL(item.notebookID, pageID)
            let content = item.content
            ioQueue.async {
                if let data = try? JSONEncoder().encode(content) { FileIO.write(data, to: url) }
            }
        }
    }

    // MARK: Helpers

    private func mutate(_ id: UUID, _ body: (inout Notebook) -> Void) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        var nb = notebooks[i]
        body(&nb)
        notebooks[i] = nb
        persistMeta(nb)
    }

    private func persistMeta(_ nb: Notebook) {
        let url = metaURL(nb.id)
        ioQueue.async {
            if let data = try? JSONEncoder().encode(nb) { FileIO.write(data, to: url) }
        }
    }

    private func removePageFile(notebookID: UUID, pageID: UUID) {
        pending[pageID] = nil
        let url = pageURL(notebookID, pageID)
        ioQueue.async { FileIO.remove(url) }
    }

    private func cleaned(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
