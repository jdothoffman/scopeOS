import SwiftUI

/// How much room the window gives the tabs. The Mac's window is always `.wide` (its minimum size is wider); an iPad
/// is `.wide` in landscape and `.medium` in portrait or Split View; an iPhone is `.narrow`, or `.medium` turned on its
/// side.
enum LayoutWidth: Comparable {
    /// One column, a compact header, and STOP in a bar along the bottom.
    case narrow
    /// A main column and a side column; compact header and the STOP bar as on `.narrow`.
    case medium
    /// The full layout, with STOP in the header.
    case wide

    init(windowWidth: CGFloat) {
        self = windowWidth >= 1040 ? .wide : windowWidth >= 700 ? .medium : .narrow
    }
}

extension EnvironmentValues {
    @Entry var layoutWidth: LayoutWidth = .wide
}
