import Foundation
// non-sandboxed: create plain bookmarks (implicit scope) and write to files
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
try? fm.removeItem(at: dir); try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
let f = dir.appendingPathComponent("x.txt"); try! "x".write(to: f, atomically: false, encoding: .utf8)
let sub = dir.appendingPathComponent("sub"); try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
try! "y".write(to: sub.appendingPathComponent("y.txt"), atomically: false, encoding: .utf8)
try! fm.createDirectory(at: out, withIntermediateDirectories: true)
try! f.bookmarkData().write(to: out.appendingPathComponent("file.bm"))
try! dir.bookmarkData().write(to: out.appendingPathComponent("dir.bm"))
try! f.bookmarkData(options: [.withoutImplicitSecurityScope]).write(to: out.appendingPathComponent("file-noimp.bm"))
print("ok")
