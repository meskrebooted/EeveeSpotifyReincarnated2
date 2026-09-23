import Foundation
import ObjectiveC
import UIKit

// ── DIAGNOSTIC / TEMPORARY — remove once the real Canvas class names are known ──
//
// Purpose: the class/method names circulating online for Spotify's internal
// Canvas UI (SPTNowPlayingCanvasVideoViewController, SPTNowPlayingCanvasModel,
// etc.) are unverified — most likely invented by an AI search summary rather
// than pulled from an actual class-dump. Hooking a class name that doesn't
// exist silently does nothing (no crash, no error), so building on them
// without checking first just wastes time.
//
// This scans every Objective-C class currently loaded in the process, finds
// the ones whose name contains "canvas" (case-insensitive), and dumps their
// instance/class method names. Since there's no way to see device logs here,
// the report is written straight to the clipboard instead — open any text
// field (Notes, Messages, this chat) and paste to read it.

private var canvasScanKnownClasses: Set<String> = []
private let canvasScanLock = NSLock()
private var canvasScanReport =
    "[CanvasScan] Nessuna classe con 'canvas' nel nome trovata finora.\n" +
    "Apri Spotify, fai partire un brano, apri la schermata Now Playing A SCHERMO INTERO " +
    "(quella con l'artwork grande) e lasciala aperta qualche secondo: è quel momento che " +
    "carica le classi del Canvas in memoria. Poi vai in un'app qualsiasi e incolla (il " +
    "resoconto viene aggiornato automaticamente negli appunti ogni volta che trova qualcosa di nuovo)."

private func canvasScanDump(_ cls: AnyClass) -> String {
    var out = "\n=== \(NSStringFromClass(cls)) ===\n"
    if let superCls = class_getSuperclass(cls) {
        out += "superclass: \(NSStringFromClass(superCls))\n"
    }

    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(cls, &methodCount) {
        for i in 0..<Int(methodCount) {
            out += "- \(sel_getName(method_getName(methods[i])))\n"
        }
        free(methods)
    }

    if let metaCls = object_getClass(cls) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaCls, &classMethodCount) {
            for i in 0..<Int(classMethodCount) {
                out += "+ \(sel_getName(method_getName(classMethods[i])))\n"
            }
            free(classMethods)
        }
    }

    var propCount: UInt32 = 0
    if let props = class_copyPropertyList(cls, &propCount) {
        for i in 0..<Int(propCount) {
            out += "@property \(String(cString: property_getName(props[i])))\n"
        }
        free(props)
    }

    return out
}

private func canvasScanOnce() {
    var count: UInt32 = 0
    guard let classList = objc_copyClassList(&count) else { return }
    defer { free(UnsafeMutableRawPointer(classList)) }

    var newlyFound: [AnyClass] = []
    canvasScanLock.lock()
    for i in 0..<Int(count) {
        let cls: AnyClass = classList[i]
        let name = NSStringFromClass(cls)
        guard name.lowercased().contains("canvas") else { continue }
        if canvasScanKnownClasses.insert(name).inserted {
            newlyFound.append(cls)
        }
    }
    canvasScanLock.unlock()

    guard !newlyFound.isEmpty else { return }

    var addition = ""
    for cls in newlyFound {
        addition += canvasScanDump(cls)
    }

    canvasScanLock.lock()
    if canvasScanReport.hasPrefix("[CanvasScan] Nessuna classe") {
        canvasScanReport = "[CanvasScan] risultati:\n"
    }
    canvasScanReport += addition
    let snapshot = canvasScanReport
    canvasScanLock.unlock()

    DispatchQueue.main.async {
        UIPasteboard.general.string = snapshot
        writeDebugLog("[CANVAS][SCAN] \(newlyFound.count) nuova/e classe/i con 'canvas', copiate negli appunti (\(snapshot.count) caratteri)")
    }
}

private var canvasScanStarted = false
private let canvasScanQueue = DispatchQueue(label: "com.eeveespotify.canvas.classscan")

// Call this once (e.g. right next to activateCanvasArtworkPublisher()). It
// keeps re-scanning for 10 minutes so you have time to navigate to the
// fullscreen Now Playing view — that's what lazily loads these classes.
func activateCanvasClassScanner() {
    guard !canvasScanStarted else { return }
    canvasScanStarted = true
    canvasScanQueue.async {
        let deadline = Date(timeIntervalSinceNow: 600)
        while Date() < deadline {
            autoreleasepool { canvasScanOnce() }
            Thread.sleep(forTimeInterval: 2)
        }
        DispatchQueue.main.async {
            UIPasteboard.general.string = canvasScanReport
            writeDebugLog("[CANVAS][SCAN] finito, ultimo resoconto copiato negli appunti")
        }
    }
}
// ── END DIAGNOSTIC ──
