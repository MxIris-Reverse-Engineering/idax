import CIDA

/// Opaque type handle wrapping IDA's type system.
///
/// Reference type — `deinit` frees the underlying handle.
public final class TypeHandle: @unchecked Sendable {
    let handle: IdaxTypeHandle

    init(_ handle: IdaxTypeHandle) {
        self.handle = handle
    }

    deinit {
        idax_type_free(handle)
    }

    // MARK: - Primitive constructors

    public static func void_() -> TypeHandle { TypeHandle(idax_type_void()) }
    public static func int8() -> TypeHandle { TypeHandle(idax_type_int8()) }
    public static func int16() -> TypeHandle { TypeHandle(idax_type_int16()) }
    public static func int32() -> TypeHandle { TypeHandle(idax_type_int32()) }
    public static func int64() -> TypeHandle { TypeHandle(idax_type_int64()) }
    public static func uint8() -> TypeHandle { TypeHandle(idax_type_uint8()) }
    public static func uint16() -> TypeHandle { TypeHandle(idax_type_uint16()) }
    public static func uint32() -> TypeHandle { TypeHandle(idax_type_uint32()) }
    public static func uint64() -> TypeHandle { TypeHandle(idax_type_uint64()) }
    public static func float32() -> TypeHandle { TypeHandle(idax_type_float32()) }
    public static func float64() -> TypeHandle { TypeHandle(idax_type_float64()) }

    public static func pointerTo(_ target: TypeHandle) -> TypeHandle {
        TypeHandle(idax_type_pointer_to(target.handle))
    }

    public static func arrayOf(_ element: TypeHandle, count: Int) -> TypeHandle {
        TypeHandle(idax_type_array_of(element.handle, count))
    }

    public static func createStruct() -> TypeHandle {
        TypeHandle(idax_type_create_struct())
    }

    public static func createUnion() -> TypeHandle {
        TypeHandle(idax_type_create_union())
    }

    // MARK: - Predicates

    public var isVoid: Bool { idax_type_is_void(handle) != 0 }
    public var isInteger: Bool { idax_type_is_integer(handle) != 0 }
    public var isFloatingPoint: Bool { idax_type_is_floating_point(handle) != 0 }
    public var isPointer: Bool { idax_type_is_pointer(handle) != 0 }
    public var isArray: Bool { idax_type_is_array(handle) != 0 }
    public var isFunction: Bool { idax_type_is_function(handle) != 0 }
    public var isStruct: Bool { idax_type_is_struct(handle) != 0 }
    public var isUnion: Bool { idax_type_is_union(handle) != 0 }
    public var isEnum: Bool { idax_type_is_enum(handle) != 0 }

    // MARK: - Introspection

    public var size: Int {
        get throws(IDAError) {
            var out: Int = 0
            try checkStatus(idax_type_size(handle, &out), "type.size")
            return out
        }
    }

    public var typeString: String {
        get throws(IDAError) {
            try withStringOutput("type.toString") { idax_type_to_string(handle, $0) }
        }
    }

    public func clone() throws(IDAError) -> TypeHandle {
        var out: IdaxTypeHandle?
        try checkStatus(idax_type_clone(handle, &out), "type.clone")
        guard let out else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return TypeHandle(out)
    }

    // MARK: - Struct/Union members

    public func addMember(_ name: String, type: TypeHandle, byteOffset: Int = 0) throws(IDAError) {
        try checkStatus(
            name.withCString { idax_type_add_member(handle, $0, type.handle, byteOffset) },
            "type.addMember"
        )
    }

    // MARK: - Database operations

    public static func byName(_ name: String) throws(IDAError) -> TypeHandle {
        var out: IdaxTypeHandle?
        try checkStatus(name.withCString { idax_type_by_name($0, &out) }, "type.byName")
        guard let out else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return TypeHandle(out)
    }

    public static func fromDeclaration(_ decl: String) throws(IDAError) -> TypeHandle {
        var out: IdaxTypeHandle?
        try checkStatus(decl.withCString { idax_type_from_declaration($0, &out) }, "type.fromDeclaration")
        guard let out else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return TypeHandle(out)
    }

    public func apply(at address: Address) throws(IDAError) {
        try checkStatus(idax_type_apply(handle, address), "type.apply")
    }

    public func saveAs(_ name: String) throws(IDAError) {
        try checkStatus(name.withCString { idax_type_save_as(handle, $0) }, "type.saveAs")
    }

    public static func retrieve(at address: Address) throws(IDAError) -> TypeHandle {
        var out: IdaxTypeHandle?
        try checkStatus(idax_type_retrieve(address, &out), "type.retrieve")
        guard let out else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return TypeHandle(out)
    }
}
