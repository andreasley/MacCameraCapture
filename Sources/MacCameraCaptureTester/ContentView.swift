import SwiftUI
import MacCameraCapture

struct ContentView: View
{
    @State private var isShowingCaptureSheet = false
    @State private var image: NSImage?
    
    var body: some View {
        VStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()

            }
            Button("Capture") {
                isShowingCaptureSheet = true
            }
        }
        .padding()
        .sheet(isPresented: $isShowingCaptureSheet) {
            CameraCaptureView { image in
                self.image = image
            }
        }
    }
}

#Preview {
    ContentView()
}
