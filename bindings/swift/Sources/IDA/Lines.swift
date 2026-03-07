internal import CIDA

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

    public static func tagAdvance(_ taggedText: String, position: Int) -> Int {
        taggedText.withCString { Int(idax_lines_tag_advance($0, Int32(position))) }
    }

    public static func makeAddressTag(itemIndex: Int) throws(IDAError) -> String {
        try withStringOutput("lines.makeAddressTag") { idax_lines_make_addr_tag(Int32(itemIndex), $0) }
    }

    public static func decodeAddressTag(_ taggedText: String, position: Int) -> Int {
        taggedText.withCString { Int(idax_lines_decode_addr_tag($0, position)) }
    }
}
