import CUVC
import Foundation

/// The standard USB Video Class controls that matter for planetary imaging.
public enum UVCControl: String, CaseIterable, Sendable {
    case autoExposure, exposureTime, gain, gamma, brightness, contrast, saturation, autoWhiteBalance, whiteBalance

    enum Unit { case cameraTerminal, processingUnit }

    var unit: Unit {
        switch self {
        case .autoExposure, .exposureTime: .cameraTerminal
        default: .processingUnit
        }
    }

    /// Control selector from the UVC 1.1 specification.
    var selector: UInt8 {
        switch self {
        case .autoExposure: 0x02 // CT_AE_MODE_CONTROL
        case .exposureTime: 0x04 // CT_EXPOSURE_TIME_ABSOLUTE_CONTROL, units of 100 µs
        case .brightness: 0x02
        case .contrast: 0x03
        case .gain: 0x04
        case .saturation: 0x07
        case .gamma: 0x09
        case .whiteBalance: 0x0A // PU_WHITE_BALANCE_TEMPERATURE_CONTROL, kelvin
        case .autoWhiteBalance: 0x0B
        }
    }

    var size: Int {
        switch self {
        case .autoExposure, .autoWhiteBalance: 1
        case .exposureTime: 4
        default: 2
        }
    }

    var isSigned: Bool { self == .brightness }

    public var label: String {
        switch self {
        case .autoExposure: "Auto exposure"
        case .exposureTime: "Exposure"
        case .gain: "Gain"
        case .gamma: "Gamma"
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .autoWhiteBalance: "Auto white balance"
        case .whiteBalance: "White balance"
        }
    }
}

public struct UVCRange: Sendable, Equatable {
    public var minimum: Int
    public var maximum: Int
    public var step: Int
    public var defaultValue: Int
}

/// A UVC camera's controls, reached over USB alongside macOS's own video streaming.
/// Calls block for a few milliseconds each; use from a background queue.
public final class UVCCamera: @unchecked Sendable {
    private let device: OpaquePointer
    private let lock = NSLock()

    /// Opens the controls of the camera AVFoundation calls `uniqueID` (for USB cameras, a hex number packing
    /// location, vendor and product IDs, e.g. 0x21210000bda5880).
    public convenience init?(captureDeviceID uniqueID: String) {
        let hex = uniqueID.lowercased().hasPrefix("0x") ? String(uniqueID.dropFirst(2)) : uniqueID
        guard let value = UInt64(hex, radix: 16) else { return nil }
        self.init(vendor: UInt16(value >> 16 & 0xFFFF), product: UInt16(value & 0xFFFF), location: UInt32(value >> 32 & 0xFFFF_FFFF))
    }

    public init?(vendor: UInt16, product: UInt16, location: UInt32 = 0) {
        guard let device = cuvc_open(vendor, product, location) else { return nil }
        self.device = device
    }

    deinit {
        cuvc_close(device)
    }

    private func unitID(_ control: UVCControl) -> UInt8 {
        control.unit == .cameraTerminal ? cuvc_camera_terminal(device) : cuvc_processing_unit(device)
    }

    private func read(_ control: UVCControl, _ request: Int32) -> Int? {
        let unit = unitID(control)
        guard unit != 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: control.size)
        let result = lock.withLock {
            bytes.withUnsafeMutableBytes { cuvc_request(device, UInt8(request), unit, control.selector, $0.baseAddress, UInt16(control.size)) }
        }
        guard result == 0 else { return nil }
        var value = 0
        for (index, byte) in bytes.enumerated() { value |= Int(byte) << (8 * index) } // little-endian
        if control.isSigned, control.size == 2, value >= 0x8000 { value -= 0x10000 }
        return value
    }

    /// The control's limits, or nil if the camera doesn't support it.
    public func range(_ control: UVCControl) -> UVCRange? {
        guard let current = read(control, Int32(CUVC_GET_CUR)) else { return nil }
        if control == .autoExposure {
            // For the mode bitmap, RES lists the supported modes rather than a step.
            return UVCRange(minimum: 0, maximum: read(control, Int32(CUVC_GET_RES)) ?? 0x0F, step: 1,
                            defaultValue: read(control, Int32(CUVC_GET_DEF)) ?? current)
        }
        let minimum = read(control, Int32(CUVC_GET_MIN)) ?? 0
        let maximum = read(control, Int32(CUVC_GET_MAX)) ?? max(current, 1)
        guard maximum >= minimum else { return nil }
        return UVCRange(minimum: minimum, maximum: maximum, step: max(1, read(control, Int32(CUVC_GET_RES)) ?? 1),
                        defaultValue: read(control, Int32(CUVC_GET_DEF)) ?? current)
    }

    public func value(_ control: UVCControl) -> Int? {
        read(control, Int32(CUVC_GET_CUR))
    }

    @discardableResult
    public func set(_ control: UVCControl, _ value: Int) -> Bool {
        let unit = unitID(control)
        guard unit != 0 else { return false }
        var bytes = (0 ..< control.size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        let result = lock.withLock {
            bytes.withUnsafeMutableBytes { cuvc_request(device, UInt8(CUVC_SET_CUR), unit, control.selector, $0.baseAddress, UInt16(control.size)) }
        }
        return result == 0
    }

    /// AE mode bitmap values (UVC: 1 manual, 2 auto, 4 shutter priority, 8 aperture priority).
    public static func autoExposureMode(supported: Int) -> Int {
        supported & 0x08 != 0 ? 0x08 : supported & 0x02 != 0 ? 0x02 : 0x08
    }
    public static let manualExposureMode = 0x01
}
