import AppKit
import DiskGraphUI

// No nib, matching the reference app, which also builds its UI entirely in code.
// The delegate is created first so its NSDocumentController becomes the shared one
// before AppKit asks for it.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
