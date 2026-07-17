import SwiftUI
import UniformTypeIdentifiers

public struct ImportFromDevicesButtons: View
{
    /// A snapshot of one actionable item from the Continuity Camera submenu that
    /// `ImportFromDevicesCommands` adds to the File menu. The title and image are
    /// whatever AppKit generated, so the title is already localized ("Take Photo",
    /// "Scan Documents", …). It keeps a reference to the original menu item so the
    /// exact item — and thereby the correct device — can be performed on click.
    private struct DeviceImportAction: Identifiable, Equatable {
        let id: Int
        let title: String
        let image: NSImage?
        let isEnabled: Bool
        let menuItem: NSMenuItem

        static func == (lhs: DeviceImportAction, rhs: DeviceImportAction) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.isEnabled == rhs.isEnabled && lhs.menuItem === rhs.menuItem
        }
    }

    /// The actions belonging to one device, delimited in the original submenu by a
    /// device-name header item and separators.
    private struct DeviceImportSection: Identifiable, Equatable {
        let id: Int
        let deviceName: String?
        let actions: [DeviceImportAction]
    }

    /// Mirrors the current items of the Continuity Camera submenu, grouped per device.
    @State private var deviceImportSections: [DeviceImportSection] = []

    public init() {}
    
    public var body: some View {
        ForEach(deviceImportSections) { section in
            // Sections render device names as native menu headers
            // (small, gray) and draw separators between devices.
            Section {
                ForEach(section.actions) { action in
                    Button {
                        performDeviceImport(action, in: section)
                    } label: {
                        Label {
                            Text(action.title)
                        } icon: {
                            if let image = action.image {
                                Image(nsImage: image)
                            }
                        }
                    }
                    .disabled(!action.isEnabled)
                }
            } header: {
                if let deviceName = section.deviceName {
                    Text(deviceName)
                }
            }
        }
        // Fires when the menu content is created, i.e. when the
        // menu opens. The equality check in the refresh method
        // prevents update loops.
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: refreshDeviceImportSections)
    }
    
    /// Copies the current items of the Continuity Camera submenu into
    /// `deviceImportSections` so the `Menu` can present them.
    @MainActor
    private func refreshDeviceImportSections() {
        let sections = deviceImportSections(from: populatedImportFromDevicesMenu())
        if sections != deviceImportSections {
            deviceImportSections = sections
        }
    }

    /// Groups the submenu's items into per-device sections. Device-name headers
    /// start a new section; separators end one.
    @MainActor
    private func deviceImportSections(from menu: NSMenu?) -> [DeviceImportSection] {
        guard let menu else { return [] }

        var sections: [DeviceImportSection] = []
        var deviceName: String?
        var actions: [DeviceImportAction] = []

        func closeSection() {
            if deviceName != nil || !actions.isEmpty {
                sections.append(DeviceImportSection(id: sections.count, deviceName: deviceName, actions: actions))
            }
            deviceName = nil
            actions = []
        }

        for item in menu.items {
            if item.isSeparatorItem {
                closeSection()
            } else if isDeviceHeader(item) {
                closeSection()
                deviceName = item.title
            } else {
                actions.append(DeviceImportAction(id: actions.count, title: item.title, image: item.image, isEnabled: item.isEnabled, menuItem: item))
            }
        }
        closeSection()
        return sections
    }

    /// Performs the original menu item a copied entry was created from. The stored
    /// item is performed directly, so with several devices connected the action of
    /// the correct one is executed even if they have identical names or actions.
    @MainActor
    private func performDeviceImport(_ action: DeviceImportAction, in section: DeviceImportSection) {
        // The item captured at snapshot time is usually still in the menu; perform
        // exactly that one. Don't repopulate the menu first — that could replace it.
        if let menu = action.menuItem.menu,
           let index = menu.items.firstIndex(of: action.menuItem) {
            menu.performActionForItem(at: index)
            return
        }

        // Fallback: AppKit recreated the items since the snapshot (e.g. a device
        // appeared or disappeared). Re-locate the action within the block of items
        // belonging to the same device.
        guard let importMenu = populatedImportFromDevicesMenu() else { return }
        var inTargetSection = (section.deviceName == nil)
        for (index, item) in importMenu.items.enumerated() {
            if item.isSeparatorItem { continue }
            if isDeviceHeader(item) {
                inTargetSection = (item.title == section.deviceName)
            } else if inTargetSection && item.isEnabled && item.title == action.title {
                importMenu.performActionForItem(at: index)
                return
            }
        }
    }

    /// A device-name header is a non-interactive item: either a real section
    /// header or a disabled item without an action (AppKit has used both
    /// representations). Disabled items that do have an action are actionable
    /// entries that are merely unavailable, not headers.
    private func isDeviceHeader(_ item: NSMenuItem) -> Bool {
        item.isSectionHeader || (!item.isEnabled && item.action == nil)
    }

    /// Returns the "Import from iPhone" submenu from the File menu, after asking
    /// its delegate to populate it (AppKit fills it in lazily, normally right
    /// before the menu is displayed).
    @MainActor
    private func populatedImportFromDevicesMenu() -> NSMenu? {
        guard let mainMenu = NSApp.mainMenu,
              let importMenu = importFromDevicesMenu(in: mainMenu) else { return nil }
        if let delegate = importMenu.delegate {
            delegate.menuNeedsUpdate?(importMenu)
        }
        importMenu.update()
        return importMenu
    }

    /// Recursively finds the "Import from iPhone" submenu in the menu bar,
    /// identified by `NSMenuItem.importFromDeviceIdentifier` (the identifier
    /// AppKit uses for Continuity Camera menu items).
    private func importFromDevicesMenu(in menu: NSMenu) -> NSMenu? {
        for item in menu.items {
            if item.identifier == NSMenuItem.importFromDeviceIdentifier {
                return item.submenu
            }
            if let submenu = item.submenu, let found = importFromDevicesMenu(in: submenu) {
                return found
            }
        }
        return nil
    }
}
