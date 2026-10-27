import AppKit
import SwiftUI

// MARK: Dropdown

/// One entry in a `Dropdown` menu.
struct DropdownItem {
    enum Kind {
        case action(() -> Void)
        case divider
        /// A greyed line of explanation.
        case note
    }

    let kind: Kind
    var title = ""
    var checked = false

    static func action(_ title: String, checked: Bool = false, _ perform: @escaping () -> Void) -> DropdownItem {
        DropdownItem(kind: .action(perform), title: title, checked: checked)
    }

    static let divider = DropdownItem(kind: .divider)

    static func note(_ title: String) -> DropdownItem { DropdownItem(kind: .note, title: title) }
}

/// The app's one dropdown: a control drawn in the app's own tokens that opens a native menu, so
/// keyboard navigation and accessibility stay the system's. (SwiftUI's `Menu` draws the stock
/// pop-up button on macOS and drops custom label content.)
struct Dropdown: View {
    enum Look {
        /// Bordered control, for a page's main choice.
        case field
        /// Smaller bordered control, for a row's value (a folder's account).
        case chip
        /// Text in the data hue, for a section header.
        case link
        /// A bare symbol, for a row's "more" menu.
        case icon(String)
    }

    let title: String
    var look: Look = .field
    var help: String?
    let items: () -> [DropdownItem]

    @State private var anchor = MenuAnchor()
    @State private var hovering = false

    var body: some View {
        Button { anchor.present(items()) } label: { label }
            .buttonStyle(DropdownStyle(look: look, hovering: hovering))
            .background(MenuAnchorView(anchor: anchor))
            .onHover { hovering = $0 }
            .help(help ?? title)
            .accessibilityLabel(title)
            .fixedSize()
    }

    @ViewBuilder private var label: some View {
        switch look {
        case .icon(let symbol):
            Image(systemName: symbol)
        default:
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
        }
    }
}

private struct DropdownStyle: ButtonStyle {
    let look: Dropdown.Look
    let hovering: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        styled(configuration)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    @ViewBuilder private func styled(_ configuration: Configuration) -> some View {
        let fill = configuration.isPressed ? Ink.active : (hovering ? Ink.raised : Ink.sheet)
        switch look {
        case .field:
            configuration.label
                .font(TypeScale.body.weight(.medium))
                .foregroundStyle(Ink.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Ink.border))
        case .chip:
            configuration.label
                .font(TypeScale.meta.weight(.medium))
                .foregroundStyle(Ink.text)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.border))
        case .link:
            configuration.label
                .font(TypeScale.meta.weight(.medium))
                .foregroundStyle(Ink.data.opacity(configuration.isPressed ? 0.6 : 1))
        case .icon:
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Ink.text : Ink.muted)
                .frame(width: 26, height: 26)
                .background(
                    configuration.isPressed || hovering ? Ink.active : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// Where a dropdown's menu opens: the control's own view.
private final class MenuAnchor {
    weak var view: NSView?

    func present(_ items: [DropdownItem]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item.kind {
            case .divider:
                menu.addItem(.separator())
            case .note:
                let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            case .action(let perform):
                let target = MenuTarget(perform)
                let entry = NSMenuItem(title: item.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                entry.target = target
                entry.representedObject = target  // NSMenuItem holds its target weakly
                entry.state = item.checked ? .on : .off
                menu.addItem(entry)
            }
        }
        let below = view.isFlipped ? view.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
    }
}

private final class MenuTarget: NSObject {
    private let perform: () -> Void

    init(_ perform: @escaping () -> Void) {
        self.perform = perform
    }

    /// Runs after the menu has closed, so an action may open a panel or a window.
    @objc func fire() {
        DispatchQueue.main.async(execute: perform)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: Segmented

/// A small set of exclusive choices on a raised track; the chosen one sits on the sheet.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var marker

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(TypeScale.meta.weight(.medium))
                        .foregroundStyle(chosen ? Ink.text : Ink.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Ink.sheet)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.border))
                                    .matchedGeometryEffect(id: "chosen", in: marker)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.rule))
        .fixedSize()
    }
}

// MARK: Text field

/// Text input on the sheet with a 1px edge that turns to the data hue while editing.
struct FieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(TypeScale.body)
            .foregroundStyle(Ink.text)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Ink.sheet, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Ink.data : Ink.border, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension TextFieldStyle where Self == FieldStyle {
    static var spillover: FieldStyle { FieldStyle() }
}
