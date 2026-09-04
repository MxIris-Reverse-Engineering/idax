import ArgumentParser
import Foundation
import Testing
@testable import IDAXCommandLineCore

/// Format names measured against IDA Professional 9.4 via `build_loaders_list`.
private enum MeasuredFormatName {
    static let fatIntel64 = "Fat Mach-O file, 1. X86_64"
    static let fatArm64 = "Fat Mach-O file, 2. ARM64"
    static let fatArm64First = "Fat Mach-O file, 1. ARM64"
    static let fatArm64e = "Fat Mach-O file, 2. ARM64e-pauth1"
    static let thinArm64 = "Mach-O file (EXECUTE). ARM64"
}

@Suite("Mach-O Architecture")
struct MachOArchitectureTests {
    @Test func parsesTheArchitectureOffEachMeasuredFormatName() {
        #expect(MachOArchitecture(formatName: MeasuredFormatName.fatIntel64) == .x86_64)
        #expect(MachOArchitecture(formatName: MeasuredFormatName.fatArm64) == .arm64)
        #expect(MachOArchitecture(formatName: MeasuredFormatName.thinArm64) == .arm64)
    }

    /// `arm64e` has `arm64` as a prefix. Testing arm64 first folds every arm64e
    /// slice onto arm64, which would make the two indistinguishable.
    @Test func arm64eIsNotMistakenForArm64() {
        #expect(MachOArchitecture(formatName: MeasuredFormatName.fatArm64e) == .arm64e)
        #expect(MachOArchitecture(formatName: MeasuredFormatName.fatArm64e) != .arm64)
    }

    /// The pointer-authentication ABI version moves with Apple's ABI, so the
    /// match has to survive a version that does not exist yet.
    @Test func arm64eToleratesAnUnseenPointerAuthenticationVersion() {
        #expect(MachOArchitecture(formatName: "Fat Mach-O file, 2. ARM64e-pauth9") == .arm64e)
    }

    @Test func formatNamesWithoutAnArchitectureParseAsNil() {
        #expect(MachOArchitecture(formatName: "Binary file") == nil)
        #expect(MachOArchitecture(formatName: "") == nil)
    }

    @Test func architectureNamesAreCaseInsensitive() {
        #expect(MachOArchitecture(rawValue: "ARM64") == .arm64)
        #expect(MachOArchitecture(argument: "X86_64") == .x86_64)
    }

    @Test func arm64PrefersItselfThenArm64e() {
        #expect(MachOArchitecture.arm64.preferenceOrder == [.arm64, .arm64e])
        #expect(MachOArchitecture.arm64e.preferenceOrder == [.arm64e, .arm64])
        #expect(MachOArchitecture.x86_64.preferenceOrder == [.x86_64])
    }
}

/// Builds fat headers byte by byte, matching <mach-o/fat.h>.
private enum FatHeaderBuilder {
    static let cpuTypeX86_64: UInt32 = 0x0100_0007
    static let cpuTypeARM64: UInt32 = 0x0100_000C
    static let cpuTypePowerPC: UInt32 = 18

    static func build(
        magic: UInt32 = 0xCAFE_BABE,
        entries: [(cpuType: UInt32, cpuSubtype: UInt32)],
        sliceCountOverride: UInt32? = nil
    ) -> [UInt8] {
        var bytes = bigEndianBytes(magic)
        bytes += bigEndianBytes(sliceCountOverride ?? UInt32(entries.count))
        let is64BitHeader = magic == 0xCAFE_BABF
        for entry in entries {
            bytes += bigEndianBytes(entry.cpuType)
            bytes += bigEndianBytes(entry.cpuSubtype)
            // offset, size, align (+ reserved for the 64-bit form); unused here.
            bytes += [UInt8](repeating: 0, count: is64BitHeader ? 24 : 12)
        }
        return bytes
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}

@Suite("Mach-O Fat Header")
struct MachOFatHeaderTests {
    /// The reported bug in header form: `lipo` orders slices by CPU type, so
    /// x86_64 lands at ordinal 1 and arm64 at ordinal 2.
    @Test func parsesAUniversalBinaryInFileOrder() throws {
        let bytes = FatHeaderBuilder.build(entries: [
            (FatHeaderBuilder.cpuTypeX86_64, 3),
            (FatHeaderBuilder.cpuTypeARM64, 0),
        ])

        let slices = try #require(MachOFatHeader.slices(parsingHeaderBytes: bytes))

        #expect(slices == [
            MachOFatSlice(architecture: .x86_64, ordinal: 1),
            MachOFatSlice(architecture: .arm64, ordinal: 2),
        ])
    }

    @Test func distinguishesArm64eByCpuSubtype() throws {
        let bytes = FatHeaderBuilder.build(entries: [
            (FatHeaderBuilder.cpuTypeARM64, 0),
            (FatHeaderBuilder.cpuTypeARM64, 2),
        ])

        let slices = try #require(MachOFatHeader.slices(parsingHeaderBytes: bytes))

        #expect(slices.map(\.architecture) == [.arm64, .arm64e])
    }

    /// Apple sets the capability bits in the high byte of cpusubtype; they must
    /// not defeat the arm64e comparison.
    @Test func ignoresCapabilityBitsInCpuSubtype() throws {
        let bytes = FatHeaderBuilder.build(entries: [
            (FatHeaderBuilder.cpuTypeARM64, 0x8000_0002),
        ])

        let slices = try #require(MachOFatHeader.slices(parsingHeaderBytes: bytes))

        #expect(slices.map(\.architecture) == [.arm64e])
    }

    @Test func parsesThe64BitFatHeaderForm() throws {
        let bytes = FatHeaderBuilder.build(
            magic: 0xCAFE_BABF,
            entries: [
                (FatHeaderBuilder.cpuTypeX86_64, 3),
                (FatHeaderBuilder.cpuTypeARM64, 0),
            ]
        )

        let slices = try #require(MachOFatHeader.slices(parsingHeaderBytes: bytes))

        #expect(slices == [
            MachOFatSlice(architecture: .x86_64, ordinal: 1),
            MachOFatSlice(architecture: .arm64, ordinal: 2),
        ])
    }

    @Test func unknownCpuTypesStillOccupyTheirOrdinal() throws {
        let bytes = FatHeaderBuilder.build(entries: [
            (FatHeaderBuilder.cpuTypePowerPC, 0),
            (FatHeaderBuilder.cpuTypeARM64, 0),
        ])

        let slices = try #require(MachOFatHeader.slices(parsingHeaderBytes: bytes))

        #expect(slices[1] == MachOFatSlice(architecture: .arm64, ordinal: 2))
    }

    @Test func thinAndNonMachOInputsAreNotFat() {
        // Thin arm64 Mach-O magic (MH_MAGIC_64), little-endian on disk.
        #expect(MachOFatHeader.slices(parsingHeaderBytes: [0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]) == nil)
        // ELF.
        #expect(MachOFatHeader.slices(parsingHeaderBytes: [0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 0]) == nil)
    }

    @Test func truncatedAndEmptyHeadersAreRejected() {
        #expect(MachOFatHeader.slices(parsingHeaderBytes: []) == nil)
        #expect(MachOFatHeader.slices(parsingHeaderBytes: [0xCA, 0xFE, 0xBA, 0xBE]) == nil)
        // Declares two slices but carries one.
        let truncated = FatHeaderBuilder.build(
            entries: [(FatHeaderBuilder.cpuTypeARM64, 0)],
            sliceCountOverride: 2
        )
        #expect(MachOFatHeader.slices(parsingHeaderBytes: truncated) == nil)
    }

    /// A corrupt or hostile count must not drive a huge allocation.
    @Test func absurdSliceCountsAreRejected() {
        let bytes = FatHeaderBuilder.build(
            entries: [(FatHeaderBuilder.cpuTypeARM64, 0)],
            sliceCountOverride: 0xFFFF_FFFF
        )
        #expect(MachOFatHeader.slices(parsingHeaderBytes: bytes) == nil)
    }

    @Test func aZeroSliceCountIsRejected() {
        let bytes = FatHeaderBuilder.build(entries: [], sliceCountOverride: 0)
        #expect(MachOFatHeader.slices(parsingHeaderBytes: bytes) == nil)
    }
}

@Suite("Slice Resolution")
struct SliceResolverTests {
    private static let universalIntelFirst = [
        MachOFatSlice(architecture: .x86_64, ordinal: 1),
        MachOFatSlice(architecture: .arm64, ordinal: 2),
    ]

    /// The reported bug: unattended IDA takes slice 1 (x86_64). Resolution has
    /// to reach past it.
    @Test func universalBinaryResolvesToArm64RatherThanTheFirstSlice() throws {
        let resolved = try SliceResolver.resolve(
            slices: Self.universalIntelFirst,
            requested: .arm64
        )

        #expect(resolved == MachOFatSlice(architecture: .arm64, ordinal: 2))
    }

    @Test func arm64IsPreferredWhenBothArmSlicesArePresent() throws {
        let resolved = try SliceResolver.resolve(
            slices: [
                MachOFatSlice(architecture: .arm64, ordinal: 1),
                MachOFatSlice(architecture: .arm64e, ordinal: 2),
            ],
            requested: .arm64
        )

        #expect(resolved?.architecture == .arm64)
    }

    @Test func arm64FallsBackToArm64eWhenPlainArm64IsAbsent() throws {
        let resolved = try SliceResolver.resolve(
            slices: [
                MachOFatSlice(architecture: .x86_64, ordinal: 1),
                MachOFatSlice(architecture: .arm64e, ordinal: 2),
            ],
            requested: .arm64
        )

        #expect(resolved?.architecture == .arm64e)
    }

    @Test func explicitArchitectureOverridesThePreferredOne() throws {
        let resolved = try SliceResolver.resolve(
            slices: Self.universalIntelFirst,
            requested: .x86_64
        )

        #expect(resolved == MachOFatSlice(architecture: .x86_64, ordinal: 1))
    }

    @Test func aMissingArchitectureIsReportedRatherThanSubstituted() {
        #expect(throws: ValidationError.self) {
            try SliceResolver.resolve(
                slices: [
                    MachOFatSlice(architecture: MachOArchitecture(rawValue: "ppc"), ordinal: 1),
                    MachOFatSlice(architecture: MachOArchitecture(rawValue: "ppc64"), ordinal: 2),
                ],
                requested: .arm64
            )
        }
    }

    @Test func aNonFatInputNeedsNoSelection() throws {
        #expect(try SliceResolver.resolve(slices: nil, requested: nil) == nil)
    }

    /// `--arch` must never silently do nothing.
    @Test func requestingAnArchitectureOnANonFatInputIsReported() {
        #expect(throws: ValidationError.self) {
            try SliceResolver.resolve(slices: nil, requested: .arm64)
        }
    }

    @Test func aSingleSliceMatchingTheRequestIsAccepted() throws {
        let resolved = try SliceResolver.resolve(
            slices: [MachOFatSlice(architecture: .arm64, ordinal: 1)],
            requested: .arm64
        )

        #expect(resolved == nil)
    }

    @Test func aSingleSliceMissingTheRequestIsReported() {
        #expect(throws: ValidationError.self) {
            try SliceResolver.resolve(
                slices: [MachOFatSlice(architecture: .arm64, ordinal: 1)],
                requested: .x86_64
            )
        }
    }

    @Test func omittingTheArchitectureResolvesTheSameAsRequestingTheHostOne() throws {
        let slices = [
            MachOFatSlice(architecture: .x86_64, ordinal: 1),
            MachOFatSlice(architecture: .arm64, ordinal: 2),
            MachOFatSlice(architecture: .arm64e, ordinal: 3),
        ]

        let defaulted = try SliceResolver.resolve(slices: slices, requested: nil)
        let explicit = try SliceResolver.resolve(slices: slices, requested: .current)

        #expect(defaulted == explicit)
    }

    /// The ordinal is what reaches IDA through `-T`. The trailing `.` keeps
    /// slice 1 from also matching slice 10 and later.
    @Test func theInputFormatNameCarriesTheOrdinalAndATrailingDot() {
        #expect(
            SliceResolver.inputFormatName(
                for: MachOFatSlice(architecture: .arm64, ordinal: 2)
            ) == "Fat Mach-O file, 2."
        )
    }
}
