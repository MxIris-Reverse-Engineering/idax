import CIDA

/// Comment operations (regular, repeatable, anterior/posterior).
///
/// Mirrors C++ `ida::comment`.
public enum Comment {
    public static func get(at address: Address, repeatable: Bool = false) throws(IDAError) -> String {
        try withStringOutput("comment.get") { idax_comment_get(address, repeatable ? 1 : 0, $0) }
    }

    public static func set(_ text: String, at address: Address, repeatable: Bool = false) throws(IDAError) {
        try checkStatus(
            text.withCString { idax_comment_set(address, $0, repeatable ? 1 : 0) },
            "comment.set"
        )
    }

    public static func append(_ text: String, at address: Address, repeatable: Bool = false) throws(IDAError) {
        try checkStatus(
            text.withCString { idax_comment_append(address, $0, repeatable ? 1 : 0) },
            "comment.append"
        )
    }

    public static func remove(at address: Address, repeatable: Bool = false) throws(IDAError) {
        try checkStatus(idax_comment_remove(address, repeatable ? 1 : 0), "comment.remove")
    }

    // MARK: - Anterior / Posterior

    public static func addAnterior(_ text: String, at address: Address) throws(IDAError) {
        try checkStatus(text.withCString { idax_comment_add_anterior(address, $0) }, "comment.addAnterior")
    }

    public static func addPosterior(_ text: String, at address: Address) throws(IDAError) {
        try checkStatus(text.withCString { idax_comment_add_posterior(address, $0) }, "comment.addPosterior")
    }

    public static func clearAnterior(at address: Address) throws(IDAError) {
        try checkStatus(idax_comment_clear_anterior(address), "comment.clearAnterior")
    }

    public static func clearPosterior(at address: Address) throws(IDAError) {
        try checkStatus(idax_comment_clear_posterior(address), "comment.clearPosterior")
    }
}
