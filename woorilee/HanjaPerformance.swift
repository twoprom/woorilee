// Scalar-only timing diagnostics shared with the offline app-settings harness.
import Foundation
import OSLog

@MainActor
enum HanjaPerformance {
    private static let logger = Logger(subsystem: "com.twoprom.inputmethod.woorilee", category: "Performance")
    /// Offline evaluation can collect samples without scraping logs. Never pass text or features.
    static var observer: ((String, Double) -> Void)?

    static func record(_ stage: String, since start: UInt64) {
        let microseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        if let observer {
            observer(stage, microseconds)
        } else {
            logger.debug("stage=\(stage, privacy: .public) duration_us=\(microseconds, privacy: .public)")
        }
    }
}
