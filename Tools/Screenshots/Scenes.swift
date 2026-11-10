import RowsterCore
import SwiftUI

struct ScreenshotScene {
    let name: String
    let size: CGSize
    let make: @MainActor () -> AnyView
}

enum ScreenshotScenes {
    @MainActor
    static var all: [ScreenshotScene] {
        [
            ScreenshotScene(name: "welcome", size: CGSize(width: 760, height: 480)) {
                AnyView(Text("Welcome to Rowster").font(.title).frame(maxWidth: .infinity, maxHeight: .infinity))
            }
        ]
    }
}
