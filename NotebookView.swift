import SwiftUI

private enum NameRequest {
    case newSection
    case renameSection(UUID)
    case newPage
    case renamePage(UUID)
    case renameNotebook

    var title: String {
        switch self {
        case .newSection: return "New Section"
        case .renameSection: return "Rename Section"
        case .newPage: return "New Page"
        case .renamePage: return "Rename Page"
        case .renameNotebook: return "Rename Notebook"
        }
    }
}

private enum DeleteRequest {
    case section(UUID)
    case page(UUID)
}

/// One notebook: section tabs along the top, the page list on the left, and the infinite page.
struct NotebookView: View {
    let notebookID: UUID

    @EnvironmentObject var store: NotebookStore
    @EnvironmentObject var settings: ToolSettings
    @StateObject private var controller = CanvasController()

    @State private var selectedSectionID: UUID?
    @State private var selectedPageID: UUID?
    @State private var showPages = true

    @State private var nameRequest: NameRequest?
    @State private var nameText = ""
    @State private var showNameAlert = false

    @State private var deleteRequest: DeleteRequest?
    @State private var showDeleteAlert = false

    // MARK: Selection helpers

    private func currentSection(in nb: Notebook) -> NotebookSection? {
        nb.sections.first { $0.id == selectedSectionID } ?? nb.sections.first
    }

    private func currentPage(in section: NotebookSection?) -> PageInfo? {
        section?.pages.first { $0.id == selectedPageID } ?? section?.pages.first
    }

    // MARK: Body

    var body: some View {
        Group {
            if let nb = store.notebook(id: notebookID) {
                content(nb)
            } else {
                Text("This notebook is no longer available.")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .alert(nameRequest?.title ?? "Name", isPresented: $showNameAlert) {
            TextField("Name", text: $nameText)
            Button("Save") { commitName() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(deleteTitle, isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .onDisappear { store.flush() }
    }

    private func content(_ nb: Notebook) -> some View {
        let section = currentSection(in: nb)
        let page = currentPage(in: section)
        return VStack(spacing: 0) {
            sectionTabs(nb, current: section)
            Rectangle().fill(Theme.accentDim).frame(height: 1)
            HStack(spacing: 0) {
                if showPages, let section {
                    pageList(section, current: page)
                        .frame(width: 250)
                    Rectangle().fill(Theme.accentDim).frame(width: 1)
                }
                canvasArea(nb, section: section, page: page)
            }
        }
        .navigationTitle(nb.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation { showPages.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                Menu {
                    Button {
                        ask(.renameNotebook, initial: nb.name)
                    } label: { Label("Rename Notebook", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: page?.id) { _, _ in store.flush() }
    }

    // MARK: Section tabs

    private func sectionTabs(_ nb: Notebook, current: NotebookSection?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(nb.sections) { s in
                    let selected = s.id == current?.id
                    Button {
                        selectedSectionID = s.id
                        selectedPageID = nil
                    } label: {
                        Text(s.name)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .foregroundStyle(selected ? Color.black : Theme.text)
                            .background(selected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                    }
                    .contextMenu {
                        Button {
                            ask(.renameSection(s.id), initial: s.name)
                        } label: { Label("Rename Section", systemImage: "pencil") }
                        Button(role: .destructive) {
                            confirmDelete(.section(s.id))
                        } label: { Label("Delete Section", systemImage: "trash") }
                    }
                }
                Button {
                    ask(.newSection)
                } label: {
                    Label("Section", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(Theme.accent)
                        .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
    }

    // MARK: Page list

    private func pageList(_ section: NotebookSection, current: PageInfo?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                EditButton().font(.subheadline)
                Button {
                    ask(.newPage)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            List {
                ForEach(section.pages) { p in
                    Button {
                        selectedPageID = p.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.accent)
                            Text(p.name)
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                            Spacer()
                        }
                    }
                    .listRowBackground(p.id == current?.id ? Theme.accentDim : Theme.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            confirmDelete(.page(p.id))
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            ask(.renamePage(p.id), initial: p.name)
                        } label: { Label("Rename", systemImage: "pencil") }
                            .tint(Theme.accent)
                    }
                    .contextMenu {
                        Button {
                            ask(.renamePage(p.id), initial: p.name)
                        } label: { Label("Rename Page", systemImage: "pencil") }
                        Button(role: .destructive) {
                            confirmDelete(.page(p.id))
                        } label: { Label("Delete Page", systemImage: "trash") }
                    }
                }
                .onMove { from, to in
                    store.movePages(notebookID: notebookID, sectionID: section.id, from: from, to: to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.surface)
    }

    // MARK: Canvas

    @ViewBuilder
    private func canvasArea(_ nb: Notebook, section: NotebookSection?, page: PageInfo?) -> some View {
        if let page {
            ZStack(alignment: .top) {
                CanvasHost(notebookID: nb.id, pageID: page.id, store: store, settings: settings, controller: controller)
                    .id(page.id)
                    .ignoresSafeArea(edges: .bottom)
                DrawingToolbar(settings: settings, controller: controller)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
        } else if section == nil {
            emptyState(message: "This notebook has no sections yet.", button: "Add a Section") { ask(.newSection) }
        } else {
            emptyState(message: "This section has no pages yet.", button: "Add a Page") { ask(.newPage) }
        }
    }

    private func emptyState(message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(message).foregroundStyle(Theme.secondaryText)
            Button(button, action: action).buttonStyle(GreenButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Naming and deleting

    private func ask(_ request: NameRequest, initial: String = "") {
        nameRequest = request
        nameText = initial
        showNameAlert = true
    }

    private func commitName() {
        guard let request = nameRequest, let nb = store.notebook(id: notebookID) else { return }
        switch request {
        case .newSection:
            if let s = store.addSection(to: notebookID, name: nameText) {
                selectedSectionID = s.id
                selectedPageID = nil
            }
        case .renameSection(let id):
            store.renameSection(notebookID: notebookID, sectionID: id, to: nameText)
        case .newPage:
            if let section = currentSection(in: nb),
               let p = store.addPage(notebookID: notebookID, sectionID: section.id, name: nameText) {
                selectedSectionID = section.id
                selectedPageID = p.id
            }
        case .renamePage(let id):
            if let section = currentSection(in: nb) {
                store.renamePage(notebookID: notebookID, sectionID: section.id, pageID: id, to: nameText)
            }
        case .renameNotebook:
            store.renameNotebook(notebookID, to: nameText)
        }
    }

    private var deleteTitle: String {
        guard let request = deleteRequest else { return "Delete?" }
        switch request {
        case .section: return "Delete this section and all its pages?"
        case .page: return "Delete this page?"
        }
    }

    private func confirmDelete(_ request: DeleteRequest) {
        deleteRequest = request
        showDeleteAlert = true
    }

    private func commitDelete() {
        guard let request = deleteRequest, let nb = store.notebook(id: notebookID) else { return }
        switch request {
        case .section(let id):
            store.deleteSection(notebookID: notebookID, sectionID: id)
        case .page(let id):
            if let section = currentSection(in: nb) {
                store.deletePage(notebookID: notebookID, sectionID: section.id, pageID: id)
            }
        }
    }
}
