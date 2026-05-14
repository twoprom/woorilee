//
//  AboutWindowController.swift
//  woorilee
//

import AppKit

@MainActor
enum AboutPanelPresenter {
    static func show() {
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSApp.applicationIconImage as Any,
        ])
    }
}
