/// Debug builds show developer tools (the simulator, a DEBUG badge, the movement enable switches).
/// Release builds hide them and keep movement enabled.
enum BuildMode {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
    static var isRelease: Bool { !isDebug }
}
