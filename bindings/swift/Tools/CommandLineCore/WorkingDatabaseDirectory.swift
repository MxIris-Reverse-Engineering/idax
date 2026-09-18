import ArgumentParser
import Darwin
import Foundation

/// A private directory holding a hard link to the input, so IDA unpacks its
/// working database there instead of beside the original file.
///
/// IDA writes the unpacked database — `.id0`, `.id1`, `.nam`, `.til` — next to
/// the file it opens. Two processes opening one dyld shared cache therefore
/// write two working databases into the same directory and corrupt each other,
/// and a set of those files left behind by an interrupted run makes every later
/// open of that cache fail outright.
///
/// A hard link is what moves them. Three other routes were measured and do not
/// work:
///
/// - A symbolic link does not: IDA resolves the input path to its real path
///   before deciding where the working database goes.
/// - `-o<path>` passed to `init_library` does not: it refuses the switch.
/// - `-o<path>` passed through `open_database`'s argument string relocates the
///   database and then dies in teardown with internal error 30500, the same
///   failure documented for passing `-T` that way.
///
/// A hard link has no target to resolve, so opening one puts the working
/// database beside the link. The cost is that a hard link must live on the same
/// volume as its file, which is what `resolveParentDirectory` is for, and that
/// the sealed system volume refuses one at all, which is what the copy in
/// `place(fileAt:as:)` is for.
nonisolated struct WorkingDatabaseDirectory: Sendable {
    /// The private directory. Removed by `remove()`, including anything IDA
    /// left in it.
    let directoryURL: URL
    /// The hard link to open instead of the original input.
    let inputFileURL: URL
    /// True when the input had to be copied because its volume refused a hard
    /// link. See `place(fileAt:as:)`.
    let inputWasCopied: Bool

    /// File extensions of IDA's own database artefacts.
    ///
    /// Sibling parts are matched by name prefix, and a leftover database from
    /// an earlier run shares that prefix. Linking one in would recreate exactly
    /// the failure this type exists to prevent: IDA refuses an input whose
    /// unpacked database is lying beside it.
    static let databaseArtefactExtensions: Set<String> = [
        "i64", "idb", "id0", "id1", "id2", "nam", "til", "asm", "lst",
    ]

    /// Create the directory and link `originalInputFileURL` into it.
    ///
    /// - Parameters:
    ///   - originalInputFileURL: the file the caller was asked to open.
    ///   - preferredParentDirectory: `--work-dir`, when given. Must be on the
    ///     same volume as the input.
    ///   - linkingSiblingParts: also link files sharing the input's name plus a
    ///     suffix. A dyld shared cache is split across `.01`, `.atlas`, `.map`
    ///     and friends, and IDA finds them by appending to the path it was
    ///     given — so they have to sit beside the link under their own names.
    static func make(
        forInputAt originalInputFileURL: URL,
        preferredParentDirectory: URL?,
        linkingSiblingParts: Bool
    ) throws -> WorkingDatabaseDirectory {
        let fileManager = FileManager.default
        let parentDirectoryURL = try resolveParentDirectory(
            forInputAt: originalInputFileURL,
            preferred: preferredParentDirectory,
            temporaryDirectoryURL: fileManager.temporaryDirectory
        )

        let directoryURL = parentDirectoryURL.appendingPathComponent(
            directoryName(processIdentifier: ProcessInfo.processInfo.processIdentifier),
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // The link keeps the original name: a dyld shared cache's parts are
        // found by appending to it, and IDA's own format names quote it back.
        let inputFileURL = directoryURL.appendingPathComponent(
            originalInputFileURL.lastPathComponent
        )
        let inputWasCopied: Bool
        do {
            inputWasCopied = try place(fileAt: originalInputFileURL, as: inputFileURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }

        if linkingSiblingParts {
            let originalDirectoryURL = originalInputFileURL.deletingLastPathComponent()
            let entryNames = (try? fileManager.contentsOfDirectory(
                atPath: originalDirectoryURL.path
            )) ?? []
            for partName in siblingPartNames(
                ofFileNamed: originalInputFileURL.lastPathComponent,
                among: entryNames
            ) {
                // A part that cannot be placed is not fatal on its own: IDA
                // reports what it actually needs and could not find, which is
                // a better message than anything guessable from here.
                _ = try? place(
                    fileAt: originalDirectoryURL.appendingPathComponent(partName),
                    as: directoryURL.appendingPathComponent(partName)
                )
            }
        }

        return WorkingDatabaseDirectory(
            directoryURL: directoryURL,
            inputFileURL: inputFileURL,
            inputWasCopied: inputWasCopied
        )
    }

    /// Put `originalFileURL` into the private directory under `placedFileURL`,
    /// by hard link if the volume allows one and by copy if it does not.
    ///
    /// - Returns: whether it had to copy.
    ///
    /// Copying is the fallback because a hard link changes the file's link
    /// count, which the sealed system volume does not permit — so `/bin/ls`
    /// and everything else under `/bin`, `/usr` and `/System` can only be
    /// copied. Those same inputs could not be opened at all before, since IDA
    /// cannot write its working database into a read-only directory either.
    /// The device numbers cannot decide this in advance: macOS reports one
    /// `st_dev` for the system and data volumes together.
    private static func place(fileAt originalFileURL: URL, as placedFileURL: URL) throws -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.linkItem(at: originalFileURL, to: placedFileURL)
            return false
        } catch let linkError {
            // Printed here rather than by the caller because the copy that
            // follows can take a while on a large input, and a silent pause is
            // worse than a line of explanation.
            print(
                "Copying \(originalFileURL.lastPathComponent) into the working directory: "
                    + "its volume does not allow hard links"
            )
            do {
                try fileManager.copyItem(at: originalFileURL, to: placedFileURL)
                return true
            } catch let copyError {
                throw ValidationError("""
                    Could not put \(originalFileURL.path) in the working directory. \
                    Hard-linking failed (\(linkError.localizedDescription)) and copying \
                    failed (\(copyError.localizedDescription)).
                    """)
            }
        }
    }

    /// Delete the directory and everything IDA put in it.
    ///
    /// Failure is ignored: this runs from a `defer` on the failure path too,
    /// where the error that got us there is the one worth reporting.
    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: - Placement

    /// Pick a directory to create the private directory in.
    ///
    /// A hard link cannot cross volumes, so the answer is constrained: the
    /// explicit `--work-dir` if it is on the input's volume, otherwise the
    /// temporary directory if it is, otherwise the input's own directory —
    /// which is the same volume by construction. The last case still fixes the
    /// concurrency hazard, because each run gets its own directory there.
    static func resolveParentDirectory(
        forInputAt inputFileURL: URL,
        preferred preferredParentDirectory: URL?,
        temporaryDirectoryURL: URL
    ) throws -> URL {
        let inputDirectoryURL = inputFileURL.deletingLastPathComponent()
        guard let inputDeviceIdentifier = deviceIdentifier(ofFileAt: inputDirectoryURL) else {
            throw ValidationError(
                "The directory holding the input does not exist: \(inputDirectoryURL.path)"
            )
        }

        if let preferredParentDirectory {
            var preferredIsDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: preferredParentDirectory.path,
                isDirectory: &preferredIsDirectory
            ), preferredIsDirectory.boolValue else {
                throw ValidationError(
                    "The working directory does not exist: \(preferredParentDirectory.path)"
                )
            }
            guard deviceIdentifier(ofFileAt: preferredParentDirectory) == inputDeviceIdentifier
            else {
                throw ValidationError("""
                    The working directory is on a different volume than the input, and IDA's \
                    working database is moved off the input by hard-linking, which cannot cross \
                    volumes. Pick a --work-dir on the same volume as \(inputFileURL.path), or \
                    omit it.
                    """)
            }
            return preferredParentDirectory
        }

        if deviceIdentifier(ofFileAt: temporaryDirectoryURL) == inputDeviceIdentifier {
            return temporaryDirectoryURL
        }
        return inputDirectoryURL
    }

    static func directoryName(processIdentifier: Int32) -> String {
        "idax-work-\(processIdentifier)-\(UUID().uuidString.prefix(8))"
    }

    /// The parts of a split input, taken from the names beside it.
    ///
    /// A dyld shared cache is `dyld_shared_cache_arm64e` plus
    /// `dyld_shared_cache_arm64e.01`, `.atlas`, `.map`, and on some platforms
    /// `.symbols`. New suffixes appear with new cache formats, so this matches
    /// the prefix and subtracts what is known not to belong — IDA's own
    /// database artefacts — rather than listing what does.
    static func siblingPartNames(
        ofFileNamed inputFileName: String,
        among entryNames: [String]
    ) -> [String] {
        let partPrefix = inputFileName + "."
        return entryNames
            .filter { entryName in
                guard entryName.hasPrefix(partPrefix), entryName != inputFileName else {
                    return false
                }
                let suffix = String(entryName.dropFirst(partPrefix.count))
                guard !suffix.isEmpty else { return false }
                // The trailing extension rather than the whole suffix, so a
                // database built from one part (`…_arm64e.01.i64`) is dropped
                // as readily as one built from the cache itself.
                let trailingExtension = URL(fileURLWithPath: entryName)
                    .pathExtension
                    .lowercased()
                return !databaseArtefactExtensions.contains(trailingExtension)
            }
            .sorted()
    }

    /// The volume a path lives on, as the device number `stat` reports.
    private static func deviceIdentifier(ofFileAt url: URL) -> dev_t? {
        var fileStatus = stat()
        guard stat(url.path, &fileStatus) == 0 else { return nil }
        return fileStatus.st_dev
    }
}
