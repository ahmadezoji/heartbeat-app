import SwiftUI

struct RootView: View {
    @State private var showHome = false

    var body: some View {
        ZStack {
            if showHome {
                HomeView()
            } else {
                SplashView()
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeInOut) {
                    showHome = true
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AudioEngineManager())
        .environmentObject(LocationManager())
}
