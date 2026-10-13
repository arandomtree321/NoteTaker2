import SwiftUI

/// Floating toolbar above the page: undo, pens, highlighters, eraser, selection, clipboard, zoom.
struct DrawingToolbar: View {
    @ObservedObject var settings: ToolSettings
    @ObservedObject var controller: CanvasController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                iconButton("arrow.uturn.backward", enabled: controller.canUndo) { controller.undo() }
                iconButton("arrow.uturn.forward", enabled: controller.canRedo) { controller.redo() }

                divider

                toolButton(.pen, symbol: "pencil.tip")
                toolButton(.highlighter, symbol: "highlighter")
                toolButton(.eraser, symbol: "eraser")
                toolButton(.lasso, symbol: "lasso")

                divider

                toolOptions

                divider

                iconButton("doc.on.doc", enabled: controller.hasSelection) { controller.copy() }
                iconButton("scissors", enabled: controller.hasSelection) { controller.cut() }
                iconButton("doc.on.clipboard", enabled: true) { controller.paste() }
                iconButton("trash", enabled: controller.hasSelection) { controller.deleteSelection() }

                divider

                iconButton("minus.magnifyingglass", enabled: true) { controller.zoomOut() }
                iconButton("arrow.up.left.and.arrow.down.right", enabled: true) { controller.fit() }
                iconButton("plus.magnifyingglass", enabled: true) { controller.zoomIn() }

                divider

                settingsMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.surface.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Theme.accentDim, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(Theme.accentDim).frame(width: 1, height: 26)
    }

    private func iconButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(enabled ? Theme.text : Theme.secondaryText.opacity(0.4))
        }
        .disabled(!enabled)
    }

    private func toolButton(_ tool: Tool, symbol: String) -> some View {
        let selected = settings.tool == tool
        return Button {
            settings.tool = tool
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 42, height: 38)
                .foregroundStyle(selected ? Color.black : Theme.text)
                .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch settings.tool {
        case .pen:
            swatches(ToolSettings.penPalette, selected: $settings.penColorHex)
            widthSlider(value: $settings.penWidth, range: 1...14)
        case .highlighter:
            swatches(ToolSettings.highlighterPalette, selected: $settings.highlighterColorHex)
            widthSlider(value: $settings.highlighterWidth, range: 8...48)
        case .eraser:
            Text("Size").font(.caption).foregroundStyle(Theme.secondaryText)
            widthSlider(value: $settings.eraserRadius, range: 6...50)
        case .lasso:
            Text("Circle ink or images to select").font(.caption).foregroundStyle(Theme.secondaryText)
        }
    }

    private func swatches(_ palette: [String], selected: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(palette, id: \.self) { hex in
                Button {
                    selected.wrappedValue = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.white, lineWidth: selected.wrappedValue == hex ? 2.5 : 0))
                        .overlay(Circle().stroke(Theme.accentDim, lineWidth: 1))
                }
            }
        }
    }

    private func widthSlider(value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        Slider(value: value, in: range)
            .frame(width: 110)
            .tint(Theme.accent)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Draw with finger", isOn: $settings.fingerDrawing)
            Toggle("Straighten lines", isOn: $settings.autoStraighten)
            Toggle("Scribble to delete", isOn: $settings.scribbleToDelete)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 38, height: 38)
                .foregroundStyle(Theme.text)
        }
    }
}
