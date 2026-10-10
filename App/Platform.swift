#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// The small things done differently on the Mac and on iPhone and iPad.
@MainActor
enum Platform {
    /// Posted the moment scopeOS stops being the app in front: on the Mac when another app is, on iOS also when
    /// Control Center, the app switcher, an alert or the lock button takes over. Held moves stop on it.
    static var resignActive: Notification.Name {
        #if os(macOS)
        NSApplication.didResignActiveNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }

    /// "Mac", "iPhone" or "iPad", for text like "runs on this Mac".
    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// Where recordings go unless the user chooses: `~/Movies/scopeOS` on the Mac; on iOS a folder in the app's
    /// Documents, which the Files app shows (On My iPhone / iPad › scopeOS).
    nonisolated static var recordingsFolder: URL {
        #if os(macOS)
        folder(.moviesDirectory, "scopeOS")
        #else
        folder(.documentDirectory, "Recordings")
        #endif
    }

    /// Where the traffic log is mirrored: `~/Library/Logs/scopeOS` on the Mac, Documents › Logs on iOS.
    nonisolated static var logsFolder: URL {
        #if os(macOS)
        folder(.libraryDirectory, "Logs/scopeOS")
        #else
        folder(.documentDirectory, "Logs")
        #endif
    }

    nonisolated private static func folder(_ directory: FileManager.SearchPathDirectory, _ path: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent(path, isDirectory: true)
    }

    #if os(macOS)
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}
