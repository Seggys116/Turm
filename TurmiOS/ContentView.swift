import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "terminal")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Turm")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
