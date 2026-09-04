import Foundation

/// One architecture slice of a universal ("fat") Mach-O.
public struct MachOFatSlice: Sendable, Equatable {
    public let architecture: MachOArchitecture
    /// 1-based position in the file, which is also the ordinal IDA prints in
    /// `Fat Mach-O file, N. <ARCH>`.
    public let ordinal: Int

    public init(architecture: MachOArchitecture, ordinal: Int) {
        self.architecture = architecture
        self.ordinal = ordinal
    }
}

/// Reads the architecture list out of a universal Mach-O header.
///
/// The tool has to know which slice it wants *before* IDA is initialised —
/// IDA only accepts an input format on the initialisation call, and its own
/// loader list cannot be built before that call. So the ordinal is derived
/// here and the result is verified against IDA after the database opens,
/// rather than trusted blindly.
public enum MachOFatHeader {
    // Values from <mach-o/fat.h> and <mach-o/machine.h>. Fat headers are
    // always big-endian regardless of the slices they contain.
    private static let magic32: UInt32 = 0xCAFE_BABE
    private static let magic64: UInt32 = 0xCAFE_BABF
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let cpuSubtypeARM64E: UInt32 = 2
    private static let cpuSubtypeMask: UInt32 = 0x00FF_FFFF

    /// A fat binary with more slices than this is treated as not fat, so a
    /// corrupt or hostile header cannot make the tool allocate wildly.
    private static let maximumSliceCount: UInt32 = 64

    /// Read the slice list from the file at `url`.
    ///
    /// Returns `nil` when the file is not a universal Mach-O — a thin Mach-O,
    /// an ELF, a PE, or anything else IDA might load.
    public static func slices(inFileAt url: URL) throws -> [MachOFatSlice]? {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        // 8 bytes of header plus 64 slices of the larger (32-byte) entry.
        guard let headerBytes = try fileHandle.read(upToCount: 8 + 32 * Int(maximumSliceCount))
        else {
            return nil
        }
        return slices(parsingHeaderBytes: [UInt8](headerBytes))
    }

    /// Pure parse over header bytes, so the format handling is testable
    /// without touching the filesystem.
    static func slices(parsingHeaderBytes bytes: [UInt8]) -> [MachOFatSlice]? {
        guard let magic = readBigEndianUInt32(bytes, at: 0) else { return nil }
        let is64BitHeader: Bool
        switch magic {
        case magic32: is64BitHeader = false
        case magic64: is64BitHeader = true
        default: return nil
        }

        guard let sliceCount = readBigEndianUInt32(bytes, at: 4),
              sliceCount > 0,
              sliceCount <= maximumSliceCount
        else {
            return nil
        }

        let entrySize = is64BitHeader ? 32 : 20
        var parsedSlices: [MachOFatSlice] = []
        parsedSlices.reserveCapacity(Int(sliceCount))

        for sliceIndex in 0..<Int(sliceCount) {
            let entryOffset = 8 + sliceIndex * entrySize
            guard let cpuType = readBigEndianUInt32(bytes, at: entryOffset),
                  let cpuSubtype = readBigEndianUInt32(bytes, at: entryOffset + 4)
            else {
                return nil
            }
            parsedSlices.append(
                MachOFatSlice(
                    architecture: architecture(cpuType: cpuType, cpuSubtype: cpuSubtype),
                    ordinal: sliceIndex + 1
                )
            )
        }
        return parsedSlices
    }

    private static func architecture(cpuType: UInt32, cpuSubtype: UInt32) -> MachOArchitecture {
        switch cpuType {
        case cpuTypeARM64:
            return (cpuSubtype & cpuSubtypeMask) == cpuSubtypeARM64E
                ? .arm64e
                : .arm64
        case cpuTypeX86_64:
            return .x86_64
        default:
            return MachOArchitecture(rawValue: "cputype-\(cpuType)")
        }
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
