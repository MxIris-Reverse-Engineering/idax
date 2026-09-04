import ArgumentParser

/// A Mach-O architecture, as named by `lipo` and by IDA's format names.
public struct MachOArchitecture: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }

    public static let arm64 = MachOArchitecture(rawValue: "arm64")
    public static let arm64e = MachOArchitecture(rawValue: "arm64e")
    public static let x86_64 = MachOArchitecture(rawValue: "x86_64")

    #if arch(arm64)
    /// The architecture this tool is running as.
    public static let current = MachOArchitecture.arm64
    #elseif arch(x86_64)
    /// The architecture this tool is running as.
    public static let current = MachOArchitecture.x86_64
    #else
    #error("idax supports arm64 and x86_64 hosts only")
    #endif

    /// Architectures to try, in order, when this one is the target.
    ///
    /// arm64 and arm64e are close enough that a binary offering only the other
    /// one is still worth loading; the ordering states which is preferred when
    /// a file offers both.
    public var preferenceOrder: [MachOArchitecture] {
        if self == .arm64 { return [.arm64, .arm64e] }
        if self == .arm64e { return [.arm64e, .arm64] }
        return [self]
    }

    /// Extract the architecture from one of IDA's format names.
    ///
    /// IDA names a format `<description>. <ARCHITECTURE>`, for example
    /// `Fat Mach-O file, 2. ARM64e-pauth1` or `Mach-O file (EXECUTE). ARM64`.
    /// Returns `nil` for formats that name no architecture at all.
    public init?(formatName: String) {
        guard let separator = formatName.range(of: ". ", options: .backwards) else {
            return nil
        }
        let token = formatName[separator.upperBound...].lowercased()
        guard !token.isEmpty else { return nil }
        self.init(rawValue: Self.canonicalName(ofToken: token))
    }

    /// Fold an architecture token from a format name onto its canonical name.
    ///
    /// arm64e slices carry a pointer-authentication ABI version in the token
    /// (`arm64e-pauth1`), and the version moves with Apple's ABI, so the match
    /// has to be a prefix rather than an equality test.
    ///
    /// The arm64e test must come first: `arm64e` has `arm64` as a prefix, so
    /// the opposite order silently folds every arm64e slice onto arm64.
    private static func canonicalName(ofToken token: String) -> String {
        if token.hasPrefix("arm64e") { return arm64e.rawValue }
        if token.hasPrefix("arm64") { return arm64.rawValue }
        if token.hasPrefix("x86_64") { return x86_64.rawValue }
        return token
    }
}

extension MachOArchitecture: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

extension MachOArchitecture: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Chooses which architecture slice of an input file to load.
public enum SliceResolver {
    /// Pick the slice matching `requested`, or the host architecture.
    ///
    /// Returns `nil` when the input offers no choice to make — a thin Mach-O,
    /// an ELF, a PE — in which case the caller should initialise IDA without
    /// naming a format and let it do what it already does correctly.
    ///
    /// Throws when the input is fat but offers neither the requested nor the
    /// host architecture. Substituting a different slice is exactly the
    /// failure this tool exists to prevent, so it is reported rather than
    /// worked around.
    public static func resolve(
        slices: [MachOFatSlice]?,
        requested: MachOArchitecture?
    ) throws -> MachOFatSlice? {
        guard let slices, slices.count > 1 else {
            guard let requested else { return nil }
            guard let onlySlice = slices?.first else {
                throw ValidationError(
                    "--arch does not apply to this input: it is not a universal binary."
                )
            }
            guard requested.preferenceOrder.contains(onlySlice.architecture) else {
                throw ValidationError(
                    "The input does not contain \(requested). It contains: "
                        + "\(onlySlice.architecture)."
                )
            }
            return nil
        }

        let target = requested ?? .current
        for preferred in target.preferenceOrder {
            if let match = slices.first(where: { $0.architecture == preferred }) {
                return match
            }
        }

        let available = slices.map(\.architecture.description).joined(separator: ", ")
        let requestedDescription = requested.map { "\($0)" }
            ?? "the host architecture (\(MachOArchitecture.current))"
        throw ValidationError(
            "The input does not contain \(requestedDescription). It contains: \(available). "
                + "Pass --arch to select one explicitly."
        )
    }

    /// The IDA input-format name that selects `slice`.
    ///
    /// IDA matches `-T` against a prefix of the format name it displays, and
    /// its names carry their own ordinal (`Fat Mach-O file, 2. ARM64e-pauth1`).
    /// The trailing `.` keeps slice 1 from also matching slice 10 or later.
    public static func inputFormatName(for slice: MachOFatSlice) -> String {
        "Fat Mach-O file, \(slice.ordinal)."
    }
}
