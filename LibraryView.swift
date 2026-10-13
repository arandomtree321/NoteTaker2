import SwiftUI

/// Home screen: all notebooks, with a button to create and name a new one.
struct LibraryView: View {
    @EnvironmentObject var store: NotebookStore

    @State private var showingNewNotebook = false
    @State private var newName = ""
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var showingRename = false
    @State private var deleting: Notebook?
    @State private var showingDelete = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 28) {
                    newNotebookTile
                    ForEach(store.notebooks) { nb in
                        NavigationLink(value: nb.id) {
                            NotebookCover(notebook: nb)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renameText = nb.name
                                renaming = nb
                                showingRename = true
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) {
                                deleting = nb
                                showingDelete = true
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(28)
            }
            .background(Theme.background)
            .navigationTitle("My Notebooks")
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                        storageBadge
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newName = ""
                        showingNewNotebook = true
                    } label: {
                        Label("New Notebook", systemImage: "plus")
                    }
                    .buttonStyle(GreenButtonStyle())
                }
            }
            .navigationDestination(for: UUID.self) { id in
                NotebookView(notebookID: id)
            }
        }
        .alert("New Notebook", isPresented: $showingNewNotebook) {
            TextField("Notebook name", text: $newName)
            Button("Create") { store.createNotebook(name: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give your notebook a name, like \"Biology\" or \"Algebra II\".")
        }
        .alert("Rename Notebook", isPresented: $showingRename) {
            TextField("Notebook name", text: $renameText)
            Button("Save") {
                if let nb = renaming { store.renameNotebook(nb.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \"\(deleting?.name ?? "")\"?", isPresented: $showingDelete) {
            Button("Delete", role: .destructive) {
                if let nb = deleting { store.deleteNotebook(nb.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All sections and pages in this notebook will be deleted.")
        }
    }

    private var newNotebookTile: some View {
        Button {
            newName = ""
            showingNewNotebook = true
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 36, weight: .light))
                Text("New Notebook")
                    .font(.headline)
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            )
        }
    }

    private var storageBadge: some View {
        Label(store.isUsingICloud ? "iCloud" : "On this iPad",
              systemImage: store.isUsingICloud ? "icloud" : "ipad")
            .font(.footnote)
            .foregroundStyle(store.isUsingICloud ? Theme.accent : Theme.secondaryText)
    }
}

private struct NotebookCover: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text(notebook.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Text("\(notebook.sections.count) section\(notebook.sections.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 220)
        .background(
            LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(alignment: .leading) {
            // Green spine along the left edge.
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accent)
                .frame(width: 8)
                .padding(.vertical, 12)
                .padding(.leading, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.accentDim, lineWidth: 1))
    }
}
