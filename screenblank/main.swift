// screenblank: set every active display's gamma to black and hold it until
// the process is killed. The display itself stays powered on, so macOS never
// treats it as asleep and the "require password after display off" lock does
// not trigger. When this process exits, WindowServer restores gamma on its
// own; the signal handler restores ColorSync settings explicitly as well.
//
// Build: swiftc -O -framework CoreGraphics -o build/screenblank screenblank/main.swift
import CoreGraphics
import Foundation

let maxDisplays: UInt32 = 16
var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
var count: UInt32 = 0

let listErr = CGGetActiveDisplayList(maxDisplays, &ids, &count)
if listErr != .success {
    FileHandle.standardError.write("screenblank: CGGetActiveDisplayList error \(listErr.rawValue)\n".data(using: .utf8)!)
    exit(1)
}

for i in 0..<Int(count) {
    // min 0, max 0, gamma 1 for red, green and blue: every value maps to black.
    let err = CGSetDisplayTransferByFormula(ids[i], 0, 0, 1, 0, 0, 1, 0, 0, 1)
    if err != .success {
        FileHandle.standardError.write("screenblank: display \(ids[i]) error \(err.rawValue)\n".data(using: .utf8)!)
    }
}

func restoreAndExit(_ sig: Int32) {
    CGDisplayRestoreColorSyncSettings()
    exit(0)
}
signal(SIGTERM, restoreAndExit)
signal(SIGINT, restoreAndExit)

dispatchMain()
