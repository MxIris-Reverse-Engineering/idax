import CIDA

/// Color tag manipulation for pseudocode and listing output.
///
/// Mirrors C++ `ida::lines`.
public enum Lines {
    public static func colorString(_ text: String, color: UInt8) throws(IDAError) -> String {
        try withStringOutput("lines.colstr") { out in
            text.withCString { idax_lines_colstr($0, color, out) }
        }
    }

    public static func tagRemove(_ taggedText: String) throws(IDAError) -> String {
        try withStringOutput("lines.tagRemove") { out in
            taggedText.withCString { idax_lines_tag_remove($0, out) }
        }
    }

    public static func tagLength(_ taggedText: String) -> Int {
        taggedText.withCString { Int(idax_lines_tag_strlen($0)) }
    }
}
