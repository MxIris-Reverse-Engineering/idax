internal import CIDAX

/// Undo and redo points in the database.
///
/// A point is created *before* the change it should roll back, so the usual
/// shape is `createPoint` then mutate. IDA records the action name for its own
/// bookkeeping and shows the label in the user interface.
public enum Undo {

    /// Marks the current database state as a point that ``performUndo()`` can
    /// return to.
    ///
    /// - Returns: whether IDA accepted the point. It declines when undo is
    ///   disabled for the database, which is not an error.
    @discardableResult
    public static func createPoint(
        actionName: String,
        label: String
    ) throws(IDAError) -> Bool {
        try withOutput("undo.createPoint", Int32(0)) {
            idax_undo_create_point(actionName, label, $0)
        } != 0
    }

    /// Label of the action ``performUndo()`` would reverse, empty when there is
    /// nothing to undo.
    public static func undoActionLabel() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_undo_undo_action_label(&out), "undo.undoActionLabel")
        return takeCString(out)
    }

    /// Label of the action ``performRedo()`` would reapply, empty when there is
    /// nothing to redo.
    public static func redoActionLabel() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_undo_redo_action_label(&out), "undo.redoActionLabel")
        return takeCString(out)
    }

    /// Reverses the most recent undoable action.
    ///
    /// - Returns: whether anything was undone. `false` means the undo stack was
    ///   empty, which is not an error.
    @discardableResult
    public static func performUndo() throws(IDAError) -> Bool {
        try withOutput("undo.performUndo", Int32(0)) {
            idax_undo_perform_undo($0)
        } != 0
    }

    /// Reapplies the most recently undone action.
    ///
    /// - Returns: whether anything was redone. `false` means the redo stack was
    ///   empty, which is not an error.
    @discardableResult
    public static func performRedo() throws(IDAError) -> Bool {
        try withOutput("undo.performRedo", Int32(0)) {
            idax_undo_perform_redo($0)
        } != 0
    }
}
