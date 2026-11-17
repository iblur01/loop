import WidgetKit
import SwiftUI

@main
struct LoopWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LoopMetricsWidget()
        LoopSleepAccessoryWidget()
        LoopRecoveryAccessoryWidget()
        LoopStrainAccessoryWidget()
        LoopBatteryAccessoryWidget()
        LoopStatusAccessoryWidget()
        BraceletBatteryLiveActivityWidget()
    }
}
