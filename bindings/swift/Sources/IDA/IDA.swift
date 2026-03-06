// IDA — Swift bindings for the idax C++ IDA SDK wrapper.
//
// Module: IDA
// Backing C module: CIDA
//
// Usage:
//   import IDA
//   try Database.initialize()
//   try Database.open("firmware.i64")
//   try Analysis.wait()
//   for seg in try Segment.all() { print(seg.name) }
