internal import CIDAX

/// Path helpers that follow IDA's own conventions.
///
/// Named `FilePath` rather than `Path` because these mirror IDA's notion of a
/// path, which is not always Foundation's — prefer `URL` for ordinary path
/// manipulation and reach for these when a result has to agree with what IDA
/// would compute.
public enum FilePath {

    /// The final component of `path`.
    public static func basename(_ path: String) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_path_basename(path, &out), "path.basename")
        return takeCString(out)
    }

    /// Everything before the final component of `path`.
    public static func dirname(_ path: String) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_path_dirname(path, &out), "path.dirname")
        return takeCString(out)
    }

    /// Whether `path` names an existing directory.
    public static func isDirectory(_ path: String) throws(IDAError) -> Bool {
        try withOutput("path.isDirectory", Int32(0)) {
            idax_path_is_directory(path, $0)
        } != 0
    }
}
