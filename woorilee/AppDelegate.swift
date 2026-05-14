// Application delegate and IMKServer bootstrap for woorilee.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa
import IMKSwift
import OSLog

private let lifecycleLogger = Logger(
    subsystem: "com.twoprom.inputmethod.woorilee",
    category: "Lifecycle"
)

// MARK: - NSManualApplication
// Custom NSApplication subclass required by InputMethodKit.
// IMK input methods must NOT use a storyboard/nib-based launch.
// Instead, we register the IMKServer programmatically in main().
class NSManualApplication: NSApplication {
    private let appDelegate = AppDelegate()

    override init() {
        super.init()
        self.delegate = appDelegate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - AppDelegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// The IMKServer instance that manages the connection between
    /// the input method and the system.
    var server: IMKServer?
    private let hanjaServices = HanjaServiceCoordinator.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize IMKServer with the connection name defined in Info.plist.
        // The connection name MUST match `InputMethodConnectionName` in Info.plist.
        let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
            ?? "com.twoprom.inputmethod.woorilee_Connection"

        server = IMKServer(
            name: connectionName,
            bundleIdentifier: Bundle.main.bundleIdentifier!
        )

        lifecycleLogger.info(
            "woorilee: IMKServer started with connection name: \(connectionName, privacy: .public)"
        )

        startHanjaServiceWarmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hanjaServices.flushUsageWrites()
        hanjaServices.hideManualCandidatePanel()
        hanjaServices.hideWarmUpPanel()
        lifecycleLogger.info("woorilee: Input method terminating")
    }

    private func startHanjaServiceWarmUp() {
        hanjaServices.warmUp(
            kiwiStatusDidResolve: logKiwiWarmUpStatus(_:),
            hanjaStatusDidResolve: logHanjaWarmUpStatus(_:),
        )
    }

    private func logKiwiWarmUpStatus(_ status: KiwiAnalysisService.Status) {
        switch status {
        case .ready:
            lifecycleLogger.info("woorilee: Kiwi analysis service ready")
        case .unavailable(let reason):
            lifecycleLogger.error("woorilee: Kiwi analysis service unavailable: \(reason, privacy: .public)")
        case .uninitialized:
            lifecycleLogger.error("woorilee: Kiwi analysis service remained uninitialized")
        case .loading:
            lifecycleLogger.info("woorilee: Kiwi analysis service is still loading")
        }
    }

    private func logHanjaWarmUpStatus(_ status: HanjaDictionaryService.Status) {
        switch status {
        case .ready:
            lifecycleLogger.info("woorilee: Hanja dictionary service ready")
        case .unavailable(let reason):
            lifecycleLogger.error("woorilee: Hanja dictionary service unavailable: \(reason, privacy: .public)")
        case .uninitialized:
            lifecycleLogger.error("woorilee: Hanja dictionary service remained uninitialized")
        case .loading:
            lifecycleLogger.info("woorilee: Hanja dictionary service is still loading")
        }
    }
}
