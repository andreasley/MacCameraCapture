import SwiftUI

struct PhotoPreview : View
{
    let image: NSImage
    
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(x: -1, y: 1)
    }
}
