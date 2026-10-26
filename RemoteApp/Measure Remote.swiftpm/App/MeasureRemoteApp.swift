import MeasureRemoteUI
import SwiftUI
import UIKit

@main
struct MeasureRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteRootView()
                // A remote is used at arm's length, often for minutes without a touch: keep the screen on.
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}
