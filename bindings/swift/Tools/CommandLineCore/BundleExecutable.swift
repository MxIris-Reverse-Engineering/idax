import ArgumentParser
import Foundation

/// The binary a bundle stands for, so `Foo.app` or `Foo.framework` can be
/// given wherever a binary is expected.
///
/// The answer is `Bundle.executableURL`, which already knows every layout in
/// use: `Contents/MacOS/<name>` for applications, app extensions and XPC
/// services, a top-level executable for iOS bundles, and the
/// `Versions/Current` link of a macOS framework.
nonisolated enum BundleExecutable {
    /// The executable to load for `inputFileURL`, or `nil` when the input is
    /// not a directory and is loaded as it is.
    ///
    /// A framework's executable comes back as its top-level symbolic link,
    /// `Foo.framework/Foo`. That is left in place for the output name and the
    /// messages; `WorkingDatabaseDirectory` opens the file it names.
    static func executableFileURL(forInputAt inputFileURL: URL) throws -> URL? {
        var inputIsDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: inputFileURL.path,
            isDirectory: &inputIsDirectory
        ), inputIsDirectory.boolValue else {
            return nil
        }

        let bundle = Bundle(url: inputFileURL)
        if let executableURL = bundle?.executableURL,
           FileManager.default.fileExists(atPath: executableURL.path) {
            return executableURL
        }

        // Named but absent is its own case. Apple's frameworks have kept their
        // binaries only in the dyld shared cache since macOS 11, and the
        // bundle on disk still names one: `executableURL` then comes back as a
        // dangling link for AppKit, and as nil for a simulator's UIKit.
        if let executableName = bundle?.infoDictionary?["CFBundleExecutable"] as? String {
            throw ValidationError("""
                \(inputFileURL.path) names its executable \(executableName), but no such \
                file is in the bundle. Apple's system frameworks keep their binaries only in \
                the dyld shared cache; load those with `idax dyld-cache`.
                """)
        }
        throw ValidationError("""
            \(inputFileURL.path) is a directory but not a bundle with an executable. Pass \
            the binary itself, or a bundle such as an .app or a .framework.
            """)
    }
}
