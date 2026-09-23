import Foundation
import Orion
import MediaPlayer
import UIKit
import AVFoundation

// ── START OF AI GENERATED CODE ──
struct CanvasPublisherGroup: HookGroup {}

private var canvasObservedFileIDs: Set<String> = []
private let canvasObservedFileIDsLock = NSLock()

class CanvasMetadataFileIDHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "NSDictionary"

    func spt_metadata_canvasVideoFileID() -> NSObject? {
        let result = orig.spt_metadata_canvasVideoFileID()
        if let fileID = result as? String {
            canvasObservedFileIDsLock.lock()
            let isNew = canvasObservedFileIDs.insert(fileID).inserted
            canvasObservedFileIDsLock.unlock()
            if isNew {
                writeDebugLog("[CANVAS][META] observed canvas fileID=\(fileID)")
            }
        }
        return result
    }
}

// Runtime probe: captures where Spotify actually places canvas video files on
// disk. Static analysis (class dump + binary strings) could not pin the
// downloader's cacheDirectory, so we observe every file move/copy and every
// URLSession download completion that lands a video file and log the
// destination path. One test cycle reveals the true location.
private let canvasVideoExtensions: Set<String> = ["mp4", "m4v", "mov"]

private func logCanvasVideoPath(_ url: URL, source: String) {
    guard canvasVideoExtensions.contains(url.pathExtension.lowercased()) else { return }
    writeDebugLog("[CANVAS][PROBE] \(source) -> \(url.path)")
}

class CanvasDownloadTaskProbeHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "NSURLSession"

    func downloadTaskWithRequest(_ request: URLRequest) -> NSObject {
        let task = orig.downloadTaskWithRequest(request)
        if let url = request.url {
            writeDebugLog("[CANVAS][PROBE] download started: \(url.absoluteString)")
        }
        return task
    }

    func downloadTaskWithRequest(
        _ request: URLRequest,
        completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void
    ) -> NSObject {
        let wrapped: (URL?, URLResponse?, Error?) -> Void = { location, response, error in
            if let location = location {
                logCanvasVideoPath(location, source: "download completion")
            }
            completionHandler(location, response, error)
        }
        if let url = request.url {
            writeDebugLog("[CANVAS][PROBE] download(handler) started: \(url.absoluteString)")
        }
        return orig.downloadTaskWithRequest(request, completionHandler: wrapped)
    }
}

// NOTE: the old debug-only probe sweeper (a full recursive scan of tmp/caches/
// application-support every 4s for an hour, purely for logging) has been removed.
// It never contributed to resolving the canvas video and was competing for disk
// I/O with the real resolver below, which is the actual bottleneck path.

private let canvasKey3x4 = "MPNowPlayingInfoProperty3x4AnimatedArtwork"
private let canvasKey1x1 = "MPNowPlayingInfoProperty1x1AnimatedArtwork"

private let canvasAnimatedKey: String? = {
    guard MPNowPlayingInfoCenter.responds(to: Selector(("supportedAnimatedArtworkKeys"))) else { return nil }
    guard let keys = MPNowPlayingInfoCenter.perform(Selector(("supportedAnimatedArtworkKeys")))?.takeUnretainedValue()
        as? [String] else { return nil }
    if keys.contains(canvasKey3x4) { return canvasKey3x4 }
    if keys.contains(canvasKey1x1) { return canvasKey1x1 }
    return keys.first
}()

private let canvasVideoSupported: Bool = canvasAnimatedKey != nil

private var canvasAnimatedAspect: CGFloat {
    canvasAnimatedKey == canvasKey1x1 ? 1.0 : 0.75
}

// All mutable canvas state lives in one struct behind one NSLock. This replaces
// the previous design of one DispatchQueue.sync round-trip per property per
// access (a thread hop + scheduling overhead for every single read/write,
// happening dozens of times per resolve cycle and on every heartbeat tick).
// A plain lock over a struct is materially cheaper for this access pattern
// and behaviorally identical (still fully serialized/thread-safe).
private struct CanvasState {
    var uri: String?
    var videoURL: URL?
    var artworkBox: AnyObject?
    var previewImage: UIImage?
    var scanStart: Date?
    var resolving = false
    var lastScanAttempt: Date = .distantPast
    var resolvedSources: [String: URL] = [:]
}

private let canvasStateLock = NSLock()
private var canvasState = CanvasState()

@discardableResult
private func withCanvasState<T>(_ body: (inout CanvasState) -> T) -> T {
    canvasStateLock.lock()
    defer { canvasStateLock.unlock() }
    return body(&canvasState)
}

private let canvasScanWindow: TimeInterval = 600
// Fix for slow first paint: previously the resolver could only attempt a scan
// once every 5s, so if the video wasn't ready on the first try you could wait
// up to ~5 extra seconds doing nothing. 0.4s keeps CPU/disk load negligible
// (a scan is only a few ms once probe-sweeping is gone) while making the
// artwork appear almost as soon as the file is actually stable on disk.
private let canvasScanThrottle: TimeInterval = 0.4

private var canvasURI: String? {
    get { withCanvasState { $0.uri } }
    set { withCanvasState { $0.uri = newValue } }
}
private var canvasVideoURL: URL? {
    get { withCanvasState { $0.videoURL } }
    set { withCanvasState { $0.videoURL = newValue } }
}
private var canvasArtworkBox: AnyObject? {
    get { withCanvasState { $0.artworkBox } }
    set { withCanvasState { $0.artworkBox = newValue } }
}
private var canvasPreviewImage: UIImage? {
    get { withCanvasState { $0.previewImage } }
    set { withCanvasState { $0.previewImage = newValue } }
}
private var canvasScanStart: Date? {
    get { withCanvasState { $0.scanStart } }
    set { withCanvasState { $0.scanStart = newValue } }
}
private var canvasRepushing = false
private var canvasResolving: Bool {
    get { withCanvasState { $0.resolving } }
    set { withCanvasState { $0.resolving = newValue } }
}
private var lastScanAttempt: Date {
    get { withCanvasState { $0.lastScanAttempt } }
    set { withCanvasState { $0.lastScanAttempt = newValue } }
}
private var canvasResolvedSources: [String: URL] {
    get { withCanvasState { $0.resolvedSources } }
    set { withCanvasState { $0.resolvedSources = newValue } }
}

private func findCanvasVideoFile(modifiedSince cutoff: Date, excluding pinnedPaths: Set<String>) -> URL? {
    let fm = FileManager.default
    var roots: [URL] = []
    roots.append(URL(fileURLWithPath: NSTemporaryDirectory()))
    roots.append(contentsOf: fm.urls(for: .cachesDirectory, in: .userDomainMask))
    roots.append(contentsOf: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask))

    let artistID = capturedArtistURI?.split(separator: ":").last.map(String.init)
    var fileIDMatch: (mod: Date, url: URL)?
    var artistMatch: (mod: Date, url: URL)?
    var newestRecent: (mod: Date, url: URL)?
    var inspected = 0
    for root in roots {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { continue }
        while let item = enumerator.nextObject() {
            inspected += 1
            if inspected > 30000 { break }
            guard let url = item as? URL else { continue }
            if url.lastPathComponent.hasPrefix("canvas_") { continue }
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard canvasVideoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // Skip files that were already pinned to a different (still-tracked) track.
            // Without this, a fast skip / gapless prefetch can make the adjacent track's
            // cache file look like "the newest one" for the track we're currently resolving.
            if pinnedPaths.contains(url.path) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let mod = values.contentModificationDate else { continue }
            // Skip files still being written by Spotify's own downloader. A file
            // that's mid-download keeps getting its mtime bumped, so "not modified
            // in the last ~120ms" is a reliable, single-stat, non-blocking way to
            // tell "finished" from "still writing" — no sleep required.
            guard isCanvasFileStable(mod: mod, size: values.fileSize ?? 0) else { continue }
            let name = url.lastPathComponent
            let isCanvasCache = name.contains("upload-artist-") || name.contains(".cnvs")
            let matchesArtist = artistID.map { name.contains("artist-\($0)") } ?? false
            var matchesFileID = false
            canvasObservedFileIDsLock.lock()
            for fileID in canvasObservedFileIDs where name.contains(fileID) {
                matchesFileID = true
                break
            }
            canvasObservedFileIDsLock.unlock()
            if matchesFileID {
                if fileIDMatch == nil || mod > fileIDMatch!.mod {
                    fileIDMatch = (mod, url)
                }
            } else if isCanvasCache && matchesArtist {
                if artistMatch == nil || mod > artistMatch!.mod {
                    artistMatch = (mod, url)
                }
            } else if isCanvasCache && mod > cutoff {
                if newestRecent == nil || mod > newestRecent!.mod {
                    newestRecent = (mod, url)
                }
            }
        }
    }
    return fileIDMatch?.url ?? artistMatch?.url ?? newestRecent?.url
}

// Fix for "wrong/adjacent track" and "sometimes never loads": a candidate file whose
// size is still changing is either an in-progress download (grabbing it now can yield
// a partial/corrupt video, which silently fails to crop) or a file being overwritten
// for the next track (grabbing it now can attach the wrong track's canvas).
//
// The original check did a 150ms Thread.sleep + a second attributesOfItem read,
// *synchronously, per candidate file, inside the scan loop*. With several cached
// video files that alone added well over a second of blocking wait to every scan.
//
// A file that's still being written keeps its modification date moving forward,
// so "mtime is more than canvasStabilityAge old" — using data already fetched in
// the same directory-enumeration pass — gives the same guarantee with one stat
// call total and zero sleeping. A file that's still mid-write is simply skipped
// this round; the next scan (canvasScanThrottle later, now 0.4s) picks it up
// once it settles.
private let canvasStabilityAge: TimeInterval = 0.12

private func isCanvasFileStable(mod: Date, size: Int) -> Bool {
    size > 0 && Date().timeIntervalSince(mod) > canvasStabilityAge
}

private func canvasCleanupOldCrops() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    if let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
        for f in files where f.lastPathComponent.hasPrefix("canvas_") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// Was synchronous: blocked its background thread on a DispatchSemaphore with a
// 30s timeout while AVAssetExportSession worked. That's dead thread time doing
// nothing useful — the export is already asynchronous internally, so we now just
// forward its own completion instead of manufacturing a blocking wait around it.
private func canvasCropVideoAsync(_ source: URL, aspect: CGFloat, completion: @escaping (URL?) -> Void) {
    let asset = AVURLAsset(url: source)
    guard let track = asset.tracks(withMediaType: .video).first else {
        completion(nil)
        return
    }
    let size = track.naturalSize.applying(track.preferredTransform)
    let w = abs(size.width)
    let h = abs(size.height)
    guard w > 0, h > 0 else {
        completion(nil)
        return
    }
    let ratio = w / h
    if abs(ratio - aspect) < 0.05 {
        completion(source)
        return
    }

    let cropRect: CGRect
    if ratio > aspect {
        let newW = h * aspect
        cropRect = CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
    } else {
        let newH = w / aspect
        cropRect = CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
    }

    let composition = AVMutableVideoComposition()
    composition.renderSize = cropRect.size
    composition.frameDuration = CMTime(value: 1, timescale: 30)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layerInstruction.setTransform(
        track.preferredTransform.concatenating(CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)),
        at: .zero
    )
    instruction.layerInstructions = [layerInstruction]
    composition.instructions = [instruction]

    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("canvas_\(UUID().uuidString).mp4")
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        completion(nil)
        return
    }
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.videoComposition = composition
    session.shouldOptimizeForNetworkUse = false
    session.exportAsynchronously {
        completion(session.status == .completed ? outputURL : nil)
    }
}

private func canvasPreviewFrame(_ url: URL, aspect: CGFloat) -> UIImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 640)
    let time = CMTime(value: 0, timescale: 600)
    guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
    let image = UIImage(cgImage: cg)
    let w = image.size.width
    let h = image.size.height
    guard w > 0, h > 0 else { return nil }
    let rect: CGRect
    if w / h > aspect {
        let newW = h * aspect
        rect = CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
    } else {
        let newH = w / aspect
        rect = CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
    }
    guard let cropped = image.cgImage?.cropping(to: rect) else { return nil }
    return UIImage(cgImage: cropped)
}

@available(iOS 19.0, *)
private func makeCanvasArtwork(
    uri: String,
    url: URL,
    staticArtwork: MPMediaItemArtwork?
) -> MPMediaItemAnimatedArtwork {
    MPMediaItemAnimatedArtwork(
        artworkID: uri,
        previewImageRequestHandler: { size in
            if let preview = canvasPreviewImage { return preview }
            return staticArtwork?.image(at: size)
        },
        videoAssetFileURLRequestHandler: { _ in
            url
        }
    )
}

private func rebuildCanvasArtwork(for uri: String) {
    guard canvasVideoSupported, let url = canvasVideoURL else { return }
    var staticArtwork: MPMediaItemArtwork?
    if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
       let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
        staticArtwork = art
    }
    if #available(iOS 19.0, *) {
        canvasArtworkBox = makeCanvasArtwork(uri: uri, url: url, staticArtwork: staticArtwork)
        canvasURI = uri
        writeDebugLog("[CANVAS][PUB] built animated artwork uri=\(uri) video=\(url.path) preview=\(canvasPreviewImage != nil)")
        if let key = canvasAnimatedKey,
           let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork,
           var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           info[key] == nil {
            info[key] = artwork
            canvasRepushing = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            canvasRepushing = false
            writeDebugLog("[CANVAS][PUB] re-pushed nowPlayingInfo with animated artwork")
        }
    }
}

private func ensureCanvasArtwork(for uri: String) {
    guard canvasVideoSupported else { return }
    if uri != canvasURI {
        canvasURI = uri
        canvasVideoURL = nil
        canvasArtworkBox = nil
        canvasPreviewImage = nil
        canvasScanStart = Date()
        canvasResolving = false
        // Fix for slow lock screen artwork: previously a track change inherited the
        // previous track's throttle timer, so the first scan for the *new* track could
        // be delayed up to canvasScanThrottle seconds for no reason. A track change is
        // always worth scanning for immediately.
        lastScanAttempt = .distantPast
        canvasCleanupOldCrops()
        writeDebugLog("[CANVAS][PUB] new track uri=\(uri)")
    }
    if canvasArtworkBox != nil { return }
    if let url = canvasVideoURL {
        rebuildCanvasArtwork(for: uri)
        return
    }
    if let pinned = canvasResolvedSources[uri] {
        canvasVideoURL = pinned
        rebuildCanvasArtwork(for: uri)
        return
    }
    guard let scanStart = canvasScanStart else { return }
    let now = Date()
    guard now.timeIntervalSince(scanStart) < canvasScanWindow else { return }
    guard now.timeIntervalSince(lastScanAttempt) > canvasScanThrottle else { return }
    guard !canvasResolving else { return }
    lastScanAttempt = now
    canvasResolving = true
    let pinnedPaths = Set(canvasResolvedSources.values.map { $0.path })
    DispatchQueue.global(qos: .utility).async {
        let found = findCanvasVideoFile(modifiedSince: scanStart, excluding: pinnedPaths)
        guard let found = found else {
            DispatchQueue.main.async {
                canvasResolving = false
                guard uri == canvasURI else { return }
                if canvasArtworkBox == nil {
                    rebuildCanvasArtwork(for: uri)
                }
            }
            return
        }
        canvasCropVideoAsync(found, aspect: canvasAnimatedAspect) { cropped in
            let preview = cropped.flatMap { canvasPreviewFrame($0, aspect: canvasAnimatedAspect) }
            DispatchQueue.main.async {
                canvasResolving = false
                guard uri == canvasURI else { return }
                if let cropped = cropped {
                    canvasVideoURL = cropped
                    canvasPreviewImage = preview
                    canvasResolvedSources[uri] = found
                    writeDebugLog("[CANVAS][PUB] resolved video \(found.path) cropped=\(cropped.path) pinned=\(found.lastPathComponent)")
                } else {
                    writeDebugLog("[CANVAS][PUB] crop failed for \(found.path), skipping")
                }
                if canvasArtworkBox == nil {
                    rebuildCanvasArtwork(for: uri)
                }
            }
        }
    }
}

class CanvasNowPlayingInfoCenterHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "MPNowPlayingInfoCenter"

    func setNowPlayingInfo(_ info: [String: Any]?) {
        if #available(iOS 19.0, *) {
            if canvasRepushing {
                orig.setNowPlayingInfo(info)
                return
            }
            if canvasVideoSupported {
                let dictURI = (info?["MPNowPlayingInfoPropertyExternalContentIdentifier"] as? String)
                    .flatMap { $0.hasPrefix("spotify:") ? $0 : nil }
                let resolvedURI = dictURI ?? capturedTrackURI
                if let resolvedURI = resolvedURI {
                    if dictURI != nil {
                        writeDebugLog("[CANVAS][NPIC] dictURI=\(dictURI!) captured=\(capturedTrackURI ?? "nil")")
                    }
                    ensureCanvasArtwork(for: resolvedURI)
                }
                // Fix for "loads once then disappears": MPNowPlayingInfoCenter fully
                // replaces its dictionary on every set, it never merges. Spotify calls
                // setNowPlayingInfo constantly for things like elapsed-time updates, and
                // many of those calls don't include the external content identifier, so
                // `resolvedURI` comes back nil. The old code required a freshly resolved
                // uri to attach the animated key, so it silently forwarded those calls
                // bare — each one wiped out the canvas that had just been shown.
                //
                // A nil resolvedURI here isn't evidence the track changed, so as long as
                // we still have a tracked canvasURI with a ready artwork, and this call
                // isn't clearly about a *different* track, keep attaching it.
                if let uri = canvasURI,
                   resolvedURI == nil || resolvedURI == uri,
                   let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork,
                   let key = canvasAnimatedKey {
                    var merged = info ?? [:]
                    merged[key] = artwork
                    orig.setNowPlayingInfo(merged)
                    return
                }
            }
        }
        orig.setNowPlayingInfo(info)
    }
}

private var canvasHeartbeatStarted = false
private let canvasHeartbeatQueue = DispatchQueue(label: "com.eeveespotify.canvas.heartbeat")

private func canvasStartHeartbeat() {
    guard !canvasHeartbeatStarted else { return }
    canvasHeartbeatStarted = true
    canvasHeartbeatQueue.async {
        while true {
            Thread.sleep(forTimeInterval: 3)
            autoreleasepool {
                if #available(iOS 19.0, *) {
                    guard let key = canvasAnimatedKey else { return }
                    guard let uri = canvasURI else { return }
                    if canvasArtworkBox as? MPMediaItemAnimatedArtwork == nil {
                        ensureCanvasArtwork(for: uri)
                        return
                    }
                    guard let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    if info[key] == nil {
                        info[key] = artwork
                        canvasRepushing = true
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                        canvasRepushing = false
                        writeDebugLog("[CANVAS][PUB] heartbeat re-injected animated artwork")
                    }
                }
            }
        }
    }
}

func activateCanvasArtworkPublisher() {
    guard canvasVideoSupported else {
        writeDebugLog("[CANVAS][PUB] disabled: supportedAnimatedArtworkKeys unavailable (iOS < 26)")
        return
    }
    canvasStartHeartbeat()
    CanvasPublisherGroup().activate()
    writeDebugLog("[CANVAS][PUB] activated (iOS 26 animated artwork publisher) key=\(canvasAnimatedKey ?? "nil")")
}
// ── END OF AI GENERATED CODE ──
