import Foundation

/// Central capacity policy for model weights on this Mac. All tiers key off
/// unified memory so the rules are identical across machines and only the
/// thresholds scale: weights above 3/4 of RAM cannot run at all, weights whose
/// working set (weights plus KV cache and activation headroom) stays within
/// half of RAM leave room for the rest of the system and are recommended.
enum ModelCapacity {
    enum Tier {
        case recommended
        case fits
        case tooBig
    }

    static var unifiedMemory: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    static func tier(weightBytes: Int64) -> Tier {
        let ram = unifiedMemory
        if weightBytes > (ram / 4) * 3 {
            return .tooBig
        }
        if weightBytes * 2 <= ram {
            return .recommended
        }
        return .fits
    }

    /// CPU decode is compute-bound well before memory-bound, so the ceiling is
    /// both a fixed weight budget and a fraction of RAM that keeps the GPU's
    /// share untouched when both devices serve at once.
    static func cpuCapable(weightBytes: Int64) -> Bool {
        weightBytes <= min(unifiedMemory / 4, 6 << 30)
    }
}
