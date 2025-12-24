import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("AccentColor"), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)

                Text("Heartbeat")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("Adaptive Tempo Player")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

#Preview {
    SplashView()
}
