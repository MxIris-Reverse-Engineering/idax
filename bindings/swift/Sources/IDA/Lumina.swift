import CIDA

/// Lumina metadata pull/push.
///
/// Mirrors C++ `ida::lumina`.
public enum Lumina {
    public struct BatchResult: Sendable {
        public let requested: Int
        public let completed: Int
        public let succeeded: Int
        public let failed: Int
    }

    public static func hasConnection(feature: Int = 0) throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(idax_lumina_has_connection(Int32(feature), &out), "lumina.hasConnection")
        return out != 0
    }

    public static func closeConnection(feature: Int = 0) throws(IDAError) {
        try checkStatus(idax_lumina_close_connection(Int32(feature)), "lumina.closeConnection")
    }

    public static func pull(
        addresses: [Address], autoApply: Bool = true, feature: Int = 0
    ) throws(IDAError) -> BatchResult {
        var raw = IdaxLuminaBatchResult()
        try checkStatus(
            addresses.withUnsafeBufferPointer {
                idax_lumina_pull($0.baseAddress, $0.count, autoApply ? 1 : 0, Int32(feature), &raw)
            },
            "lumina.pull"
        )
        return BatchResult(requested: raw.requested, completed: raw.completed,
                           succeeded: raw.succeeded, failed: raw.failed)
    }

    public static func push(
        addresses: [Address], pushMode: Int = 0, feature: Int = 0
    ) throws(IDAError) -> BatchResult {
        var raw = IdaxLuminaBatchResult()
        try checkStatus(
            addresses.withUnsafeBufferPointer {
                idax_lumina_push($0.baseAddress, $0.count, Int32(pushMode), Int32(feature), &raw)
            },
            "lumina.push"
        )
        return BatchResult(requested: raw.requested, completed: raw.completed,
                           succeeded: raw.succeeded, failed: raw.failed)
    }
}
