import SwiftUI

@main
struct HeartbeatWatchApp: App {
    @StateObject private var beatPlayer = BeatPlayer()
    @StateObject private var workout = WorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(beatPlayer)
                .environmentObject(workout)
        }
    }
}
