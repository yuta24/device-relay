import AVFoundation
import CoreMediaIO
import Darwin
import Foundation

/// Recording a device's screen the way QuickTime Player does: with CoreMediaIO's
/// `kCMIOHardwarePropertyAllowScreenCaptureDevices` on, a device plugged in with USB shows up as a capture
/// device (`AVCaptureDevice`, muxed video and audio), whose frames go to an `AVAssetWriter` (H.264). Neither
/// simctl nor devicectl records a device. The capture device carries the device's name but not its UDID,
/// so it is found by the name devicectl reports (`match`).
///
/// macOS asks for camera access for this, on behalf of the app relay runs in (the terminal, for example):
/// the detached `relay record supervise` counts as that app too, so `record start` asks before it starts it.
enum DeviceCapture {
    /// How long the capture devices take to show up after they are allowed (about 0.3 s, up to about 4.3 s
    /// in a new process).
    static let discoveryTimeout: TimeInterval = 10
    /// How long the supervisor waits after its capture stops before it exits. A process that allows the
    /// capture devices within about 2.5 s after another one stopped capturing never sees the screen (no
    /// capture device at all, for as long as it runs; allowing again or exec does not help, a new process
    /// does), so `record stop`, which waits for the supervisor, returns after that.
    static let releaseDelay: TimeInterval = 3.5
    /// How long `record start` waits for an answer to the camera access dialog.
    static let accessTimeout: TimeInterval = 120
    /// The capture devices' model, as opposed to cameras plugged into the Mac.
    static let modelID = "iOS Device"
    /// How long without a frame before the supervisor notes it. A still screen keeps sending frames (40 to 60
    /// a second, at most about 0.08 s apart), so a gap this long means the capture stopped, a locked device
    /// for example.
    static let stallThreshold: TimeInterval = 5
    /// The supervisor's notes in the log when frames stop and when they come again (`FrameWatch`), which
    /// `record status` reads.
    static let stallMarker = "relay: no frame for "
    static let resumeMarker = "relay: frames came again "

    // MARK: - Pure helpers

    /// Why the device cannot be recorded as devicectl sees it, if it cannot: it must be connected, with USB.
    static func connectionProblem(_ device: Device) -> String? {
        let what = "\(device.name) (\(device.udid))"
        guard device.isAvailable else {
            return "the device \(what) is not connected (\(device.state)); recording a device needs it connected with a USB cable and unlocked"
        }
        if let transport = device.transport, transport != "wired" {
            return "the device \(what) is connected over the network only (\(transport)); recording a device needs a USB cable: "
                + "connect it with one, unlock it, and try again"
        }
        return nil
    }

    /// The camera access macOS has given the app relay runs in, as `AVAuthorizationStatus` says.
    enum Access: Equatable {
        case authorized
        case notDetermined
        case denied
        case restricted
    }

    /// Why recording cannot start with `access`, if it cannot. `notDetermined` is asked for first (`requestAccess`).
    static func accessProblem(_ access: Access) -> String? {
        let settings = "System Settings > Privacy & Security > Camera"
        switch access {
        case .authorized, .notDetermined:
            return nil
        case .denied:
            return "macOS denies camera access to the app relay runs in (the terminal or the IDE), which recording a device needs; "
                + "allow that app in \(settings), restart it, and try again"
        case .restricted:
            return "camera access is restricted on this Mac (a configuration profile or Screen Time), and recording a device needs it; "
                + "see \(settings)"
        }
    }

    /// A capture device as `match` sees it.
    struct Candidate: Equatable {
        var uniqueID: String
        var name: String
    }

    enum Match: Equatable {
        case found(uniqueID: String)
        case notFound
        /// Several capture devices have the name.
        case ambiguous(count: Int)
    }

    /// The capture device of the device named `name` (devicectl's name). The capture device's uniqueID is not
    /// the UDID and cannot be derived from it, so the name is all there is. Both come from the device, so an
    /// exact match comes first; without one, the names are compared again ignoring case, accents, and the
    /// kind of apostrophe or quote (’ and ', for example), in case one side spells them differently.
    static func match(name: String, candidates: [Candidate]) -> Match {
        var named = candidates.filter { $0.name == name }
        if named.isEmpty {
            let loose = loosened(name)
            named = candidates.filter { loosened($0.name) == loose }
        }
        switch named.count {
        case 0: return .notFound
        case 1: return .found(uniqueID: named[0].uniqueID)
        default: return .ambiguous(count: named.count)
        }
    }

    /// `name` for the second comparison of `match`: case and accents folded, and apostrophes and quotes made
    /// the ASCII ones.
    static func loosened(_ name: String) -> String {
        let apostrophes: Set<Character> = ["\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{02BC}", "\u{FF07}", "`", "\u{00B4}"]
        let quotes: Set<Character> = ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{FF02}"]
        let plain = String(name.map { apostrophes.contains($0) ? "'" : quotes.contains($0) ? "\"" : $0 })
        return plain.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The error when the device's screen is not among the capture devices, with what was there.
    static func notFoundMessage(name: String, candidates: [Candidate]) -> String {
        let seen = candidates.isEmpty ? "no device screen is available" : "the screens available are \(candidates.map { "\"\($0.name)\"" }.joined(separator: ", "))"
        return "the screen of \(name) did not show up as a capture device within \(Int(discoveryTimeout))s (\(seen)); "
            + "connect it with a USB cable (not only Wi-Fi), unlock it, tap Trust if it asks to trust this computer, and try again"
    }

    /// Whether the supervisor's log says no device screen showed up at all, which a process that started just
    /// after another capture stopped also sees; `record start` tries once more in a new process then.
    static func noScreenShowedUp(inLog text: String) -> Bool {
        text.split(separator: "\n").contains { $0.hasPrefix("relay: the screen of ") && $0.contains("(no device screen is available)") }
    }

    static func ambiguousMessage(name: String, count: Int) -> String {
        "\(count) connected devices are named \"\(name)\", and their screens cannot be told apart; "
            + "rename one in Settings > General > About, or unplug the others"
    }

    /// MP4 unless the path ends in .mov (or .m4v); the codec is H.264 either way.
    static func fileType(forPath path: String) -> AVFileType {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

    // MARK: - System

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    /// Asks macOS for camera access, which shows its dialog the first time, and waits for the answer.
    /// nil when no answer comes in `timeout`.
    static func requestAccess(timeout: TimeInterval = accessTimeout) -> Bool? {
        let answered = DispatchSemaphore(value: 0)
        let granted = InterruptFlag()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            if ok { granted.set() }
            answered.signal()
        }
        return answered.wait(timeout: .now() + timeout) == .timedOut ? nil : granted.isSet
    }

    /// Lets this process see the screens of devices plugged in with USB as capture devices.
    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// The device screens among the capture devices.
    static func screens() -> [AVCaptureDevice] {
        let type: AVCaptureDevice.DeviceType
        if #available(macOS 14.0, *) {
            type = .external
        } else {
            type = .externalUnknown
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .muxed, position: .unspecified).devices
            .filter { $0.modelID == modelID }
    }
}

/// Notes in the supervisor's log when frames stop coming and when they come again; the recording goes on
/// either way (the video holds the last frame meanwhile).
struct FrameWatch {
    /// When the last frame before the gap came, while frames have stopped.
    private(set) var stalledSince: Date?

    /// The note to log, if any, given when the last frame came (nil before the first one).
    mutating func check(lastFrame: Date?, now: Date, threshold: TimeInterval = DeviceCapture.stallThreshold) -> String? {
        guard let lastFrame else { return nil }
        if let since = stalledSince {
            guard lastFrame > since else { return nil }
            stalledSince = nil
            return "frames came again after \(Int(lastFrame.timeIntervalSince(since).rounded()))s without one"
        }
        guard now.timeIntervalSince(lastFrame) >= threshold else { return nil }
        stalledSince = lastFrame
        return "no frame for \(Int(threshold))s (the device may be locked, or the capture stalled); still recording, "
            + "and the video holds the last frame until frames come again"
    }
}

/// Writes the frames of a capture session to the video. The writer starts with the first frame, so its size
/// is the screen's and the video starts when the screen does.
private final class DeviceFrameWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let url: URL
    /// Set on the queue the frames come on.
    private(set) var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var frames = 0
    private(set) var size: (width: Int, height: Int)?
    private(set) var failure: String?
    /// When the last frame came, written or not (`FrameWatch`).
    private(set) var lastFrameAt: Date?
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, failure == nil, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameAt = Date()
        if writer == nil {
            let width = CVPixelBufferGetWidth(image)
            let height = CVPixelBufferGetHeight(image)
            do {
                // The check in record start allowed replacing it; AVAssetWriter does not.
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: DeviceCapture.fileType(forPath: url.path))
                // A rotated screen comes in another size; it is fitted into the first one.
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
                ])
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                guard writer.startWriting() else {
                    failure = "cannot write \(url.path): \(writer.error.map { "\($0)" } ?? "unknown error")"
                    return
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                self.writer = writer
                self.input = input
                size = (width, height)
            } catch {
                failure = "cannot write \(url.path): \(error)"
                return
            }
        }
        guard let input, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            frames += 1
            if frames == 1 {
                // What record start waits for, as simctl prints it.
                FileHandle.standardError.write(Data("\(Recording.startedMarker)\n".utf8))
            }
        } else if let writer, writer.status == .failed {
            failure = "writing the video failed: \(writer.error.map { "\($0)" } ?? "unknown error")"
        }
    }

    /// Ends the video; call on the frames' queue. Calls `done` once it is written (or there was nothing to write).
    func finish(_ done: @escaping @Sendable () -> Void) {
        finished = true
        guard let writer, writer.status == .writing else {
            done()
            return
        }
        input?.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}

/// `relay record supervise --device-name`: what `RecordSupervisor` does for a device. This process records
/// itself (there is no simctl), so its own pid is the one in the state, and SIGINT to it ends the video.
enum DeviceRecordSupervisor {
    static func run(name: String, output: String, maxDuration: TimeInterval) -> Int32 {
        log("recording the device in pid \(getpid())")
        // Signals stop the recording from here on.
        let stop = InterruptFlag()
        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { stop.set() }
            source.resume()
            sources.append(source)
        }

        if let problem = DeviceCapture.accessProblem(DeviceCapture.access) {
            log(problem)
            return 1
        }
        DeviceCapture.allowScreenCaptureDevices()
        let deadline = Date().addingTimeInterval(DeviceCapture.discoveryTimeout)
        var device: AVCaptureDevice?
        var candidates: [DeviceCapture.Candidate] = []
        while device == nil {
            let screens = DeviceCapture.screens()
            candidates = screens.map { DeviceCapture.Candidate(uniqueID: $0.uniqueID, name: $0.localizedName) }
            switch DeviceCapture.match(name: name, candidates: candidates) {
            case .found(let uniqueID):
                device = screens.first { $0.uniqueID == uniqueID }
            case .ambiguous(let count):
                log(DeviceCapture.ambiguousMessage(name: name, count: count))
                return 1
            case .notFound:
                guard Date() < deadline, !stop.isSet else {
                    log(DeviceCapture.notFoundMessage(name: name, candidates: candidates))
                    return 1
                }
                // The capture devices arrive through the run loop.
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        guard let device else { return 1 }

        let session = AVCaptureSession()
        let frameOutput = AVCaptureVideoDataOutput()
        let writer = DeviceFrameWriter(url: URL(fileURLWithPath: output))
        let queue = DispatchQueue(label: "relay.record.frames")
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(frameOutput) else {
                log("cannot capture the screen of \(name)")
                return 1
            }
            session.addInput(input)
            frameOutput.setSampleBufferDelegate(writer, queue: queue)
            session.addOutput(frameOutput)
        } catch {
            log("cannot capture the screen of \(name): \(error)")
            return 1
        }
        let ended = InterruptFlag()
        let endReason = Locked<String?>(nil)
        var observers: [NSObjectProtocol] = []
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
            endReason.set("the device was disconnected")
            ended.set()
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { note in
            let error = note.userInfo?[AVCaptureSessionErrorKey].map { "\($0)" } ?? "unknown error"
            endReason.set("the capture failed: \(error)")
            ended.set()
        })
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        session.startRunning()

        let started = Date()
        var watch = FrameWatch()
        while !stop.isSet, !ended.isSet, Date().timeIntervalSince(started) < maxDuration, queue.sync(execute: { writer.failure }) == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let note = watch.check(lastFrame: queue.sync(execute: { writer.lastFrameAt }), now: Date()) {
                log(note)
            }
        }
        if let failure = queue.sync(execute: { writer.failure }) {
            log(failure)
        } else if let reason = endReason.value {
            log("\(reason); stopped the recording")
        } else {
            log(stop.isSet ? "stopping the recording" : "reached --max-duration of \(Int(maxDuration))s; stopped the recording")
        }

        let written = DispatchSemaphore(value: 0)
        queue.sync { writer.finish { written.signal() } }
        let finishedInTime = written.wait(timeout: .now() + Recording.stopTimeout) == .success
        session.stopRunning()
        // The next recording's process would not see the screen right away (`releaseDelay`).
        Thread.sleep(forTimeInterval: DeviceCapture.releaseDelay)
        let (frames, size, status) = queue.sync { (writer.frames, writer.size, writer.writer?.status) }
        guard finishedInTime else {
            log("the video was not written within \(Int(Recording.stopTimeout))s")
            return 1
        }
        guard frames > 0, status == .completed else {
            log(frames == 0 ? "no frame came from the screen of \(name)" : "the video was not written (\(writer.writer?.error.map { "\($0)" } ?? "unknown error"))")
            return 1
        }
        log("wrote \(frames) frames (\(size.map { "\($0.width)x\($0.height)" } ?? "?")) to \(output)")
        return 0
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }
}

/// A value set from a notification and read by the waiting loop.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
