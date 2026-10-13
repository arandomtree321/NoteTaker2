import SwiftUI

/// Hosts the UIKit ink canvas for one page and wires it to storage.
struct CanvasHost: UIViewRepresentable {
    let notebookID: UUID
    let pageID: UUID
    let store: NotebookStore
    let settings: ToolSettings
    let controller: CanvasController

    func makeUIView(context: Context) -> InkCanvasView {
        let view = InkCanvasView(settings: settings)
        let content = store.loadPage(notebookID: notebookID, pageID: pageID)
        view.load(elements: content.elements, viewport: ViewportStore.load(pageID: pageID))
        view.controller = controller

        let notebookID = notebookID, pageID = pageID, store = store
        view.onChange = { [weak view] in
            guard let view else { return }
            store.scheduleSave(notebookID: notebookID, pageID: pageID, content: PageContent(elements: view.elements))
        }
        view.onViewportChange = { scale, offset in
            ViewportStore.save(pageID: pageID, scale: scale, offset: offset)
        }
        controller.canvas = view
        return view
    }

    func updateUIView(_ uiView: InkCanvasView, context: Context) {}
}
