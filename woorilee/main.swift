// Entry point for the woorilee macOS Korean input method.
//     Copyright (C) 2026 Seungjin Lee.

import Cocoa

// Use the custom NSManualApplication class as the principal class.
// This is required for InputMethodKit-based apps which must not use
// storyboard/nib-based launch sequences.
let app = NSManualApplication.shared
NSApp.run()
