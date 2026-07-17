import SwiftUI
import MacCameraCapture
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View
{
    enum ImportedContent {
        case image(NSImage)
        case pdf(PDFDocument)
    }

    @State private var isShowingCaptureSheet = false
    @State private var importedContent: ImportedContent?

    var body: some View {
        VStack {
            // Show the imported content so the import actually has an effect.
            switch importedContent {
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            case .pdf(let document):
                PDFDocumentView(document: document)
            case nil:
                ContentUnavailableView(
                    "No Image Imported",
                    systemImage: "photo.badge.arrow.down",
                    description: Text("Use File ▸ Import from iPhone to take a photo or scan a document.")
                )
                .labelStyle(.titleAndIcon)
            }
        }
        .padding()
        // This is the modifier `ImportFromDevicesCommands` looks for. Declaring
        // the content types the view accepts is what enables the submenu items
        // (Take Photo, Scan Documents, …).
        .importsItemProviders([.jpeg, .heic, .png, .pdf]) { providers in
            guard let provider = providers.first else { return false }
            // Scanned documents arrive as PDF data, photos as images.
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                    guard let data, let document = PDFDocument(data: data) else { return }
                    Task { @MainActor in
                        importedContent = .pdf(document)
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in
                        importedContent = .image(image)
                    }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItem {
                Button("Capture") {
                    isShowingCaptureSheet = true
                }
            }
            ToolbarItem {
                Menu("Import") {
                    ImportFromDevicesButtons()
                }
            }
        }
        .sheet(isPresented: $isShowingCaptureSheet) {
            CameraCaptureView { image in
                self.importedContent = .image(image)
            }
        }
    }
}

#Preview {
    ContentView()
}
