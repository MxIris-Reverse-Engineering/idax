import CIDA

/// Logging and performance counters.
///
/// Mirrors C++ `ida::diagnostics`.
public enum Diagnostics {
    public static func setLogLevel(_ level: Int) throws(IDAError) {
        try checkStatus(idax_diagnostics_set_log_level(Int32(level)), "diagnostics.setLogLevel")
    }

    public static func logLevel() -> Int {
        Int(idax_diagnostics_log_level())
    }

    public static func log(level: Int, domain: String, message: String) {
        domain.withCString { d in
            message.withCString { m in
                idax_diagnostics_log(Int32(level), d, m)
            }
        }
    }

    public static func resetPerformanceCounters() {
        idax_diagnostics_reset_performance_counters()
    }

    public struct PerformanceCounters: Sendable {
        public let logMessages: UInt64
        public let invariantFailures: UInt64
    }

    public static func performanceCounters() throws(IDAError) -> PerformanceCounters {
        var raw = IdaxPerformanceCounters()
        try checkStatus(idax_diagnostics_performance_counters(&raw), "diagnostics.performanceCounters")
        return PerformanceCounters(logMessages: raw.log_messages, invariantFailures: raw.invariant_failures)
    }
}
