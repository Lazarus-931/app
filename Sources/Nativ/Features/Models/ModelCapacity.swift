import Foundation

enum ModelCapacity {
    enum Tier {
        case recommended
        case fits
        case tooBig
    }

    static var unifiedMemory: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    static let activationReserveBytes: Int64 = 1 << 30

    static let cpuWeightCeiling: Int64 = 6 << 30

    static func effectiveContextTokens(maxKVSize: Int, modelContextSize: Int?) -> Int {
        if maxKVSize > 0 {
            return maxKVSize
        }
        return min(modelContextSize ?? 8192, 16384)
    }

    static func kvCacheBytes(elementsPerToken: Int64, contextTokens: Int, kvBits: Double?) -> Int64 {
        let bytesPerElement: Double
        if let kvBits, kvBits > 0, kvBits < 16 {
            bytesPerElement = kvBits / 8.0
        } else {
            bytesPerElement = 2.0
        }
        let tokens = Double(max(contextTokens, 0))
        return Int64(Double(elementsPerToken) * tokens * bytesPerElement)
    }

    static func workingSetBytes(
        weightBytes: Int64,
        kvElementsPerToken: Int64?,
        contextTokens: Int,
        kvBits: Double?
    ) -> Int64 {
        guard let kvElementsPerToken else {
            return weightBytes
        }
        return weightBytes
            + kvCacheBytes(elementsPerToken: kvElementsPerToken, contextTokens: contextTokens, kvBits: kvBits)
            + activationReserveBytes
    }

    static func tier(footprintBytes: Int64) -> Tier {
        let ram = unifiedMemory
        if footprintBytes > (ram / 4) * 3 {
            return .tooBig
        }
        if footprintBytes <= ram / 2 {
            return .recommended
        }
        return .fits
    }

    static func tier(weightBytes: Int64) -> Tier {
        tier(footprintBytes: weightBytes)
    }

    static func tier(
        weightBytes: Int64,
        kvElementsPerToken: Int64?,
        contextTokens: Int,
        kvBits: Double?
    ) -> Tier {
        tier(footprintBytes: workingSetBytes(
            weightBytes: weightBytes,
            kvElementsPerToken: kvElementsPerToken,
            contextTokens: contextTokens,
            kvBits: kvBits
        ))
    }

    static func cpuCapable(weightBytes: Int64) -> Bool {
        cpuCapable(weightBytes: weightBytes, kvElementsPerToken: nil, contextTokens: 0, kvBits: nil)
    }

    static func cpuCapable(
        weightBytes: Int64,
        kvElementsPerToken: Int64?,
        contextTokens: Int,
        kvBits: Double?
    ) -> Bool {
        guard weightBytes <= cpuWeightCeiling else {
            return false
        }
        let footprint = workingSetBytes(
            weightBytes: weightBytes,
            kvElementsPerToken: kvElementsPerToken,
            contextTokens: contextTokens,
            kvBits: kvBits
        )
        return footprint <= unifiedMemory / 4
    }
}
