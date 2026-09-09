import Foundation

/// What this Mac can hold. Read once per pane open; injected in tests.
public struct HardwareProfile: Equatable, Sendable {
    public let physicalMemoryBytes: Int64
    public let chipName: String?

    public init(physicalMemoryBytes: Int64, chipName: String?) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.chipName = chipName
    }

    public static func current() -> HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip: String?
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                chip = String(cString: buffer)
            }
        }
        return HardwareProfile(
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory), chipName: chip)
    }
}

/// How a model's weight compares with the memory of this Mac. Unified memory is shared with
/// everything else running, so the thresholds are deliberately conservative.
public enum ModelFit: Equatable, Sendable {
    case recommended, tight, tooLarge

    public static let recommendedShare = 0.45
    public static let tightShare = 0.70

    public static func classify(modelBytes: Int64, memoryBytes: Int64) -> ModelFit {
        guard memoryBytes > 0 else { return .tooLarge }
        let share = Double(modelBytes) / Double(memoryBytes)
        if share <= recommendedShare { return .recommended }
        if share <= tightShare { return .tight }
        return .tooLarge
    }

    public var label: String {
        switch self {
        case .recommended: "Recommended for this Mac"
        case .tight: "Tight on this Mac"
        case .tooLarge: "Too large for this Mac"
        }
    }

    public var symbolName: String {
        switch self {
        case .recommended: "checkmark.seal"
        case .tight: "exclamationmark.circle"
        case .tooLarge: "xmark.octagon"
        }
    }
}
