//
//  HanjaUserDictionaryWindowController.swift
//  woorilee
//

import AppKit
import SwiftUI

@MainActor
final class HanjaUserDictionaryWindowController: NSObject, NSWindowDelegate {
    static let shared = HanjaUserDictionaryWindowController()

    private var window: NSWindow?
    private var viewModel: HanjaUserDictionaryViewModel?

    private override init() {
        super.init()
    }

    func show() {
        guard let store = HanjaDictionaryService.shared.userHanjaStore else {
            NSSound.beep()
            return
        }

        let window = ensureWindow(store: store)
        viewModel?.reloadFromStore()
        // An IMK server process starts with an activation policy that bars its
        // own windows from becoming key. Promote to .accessory so this prefs
        // window can take keyboard focus while still keeping the IME dockless.
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow(store: UserHanjaStore) -> NSWindow {
        if let window {
            return window
        }

        let viewModel = HanjaUserDictionaryViewModel(store: store)
        let rootView = HanjaUserDictionaryView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "한자 사전"
        window.setContentSize(NSSize(width: 520, height: 400))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.viewModel = viewModel
        self.window = window
        return window
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            viewModel?.commitAllDirty()
        }
    }
}
