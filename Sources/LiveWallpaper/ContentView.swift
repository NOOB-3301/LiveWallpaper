import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    init(model: AppModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Text("stub")
    }
}
