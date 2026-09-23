import Foundation
let r = (URL(fileURLWithPath: "/etc/hosts") as NSURL).fileReferenceURL()
print(type(of: r), r?.absoluteString ?? "nil", (r as NSURL?)?.isFileReferenceURL() ?? false)
let raw = NSURL(fileURLWithPath: "/etc/hosts").perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL
print("raw NSURL:", raw?.absoluteString ?? "nil", raw?.isFileReferenceURL() ?? false)
