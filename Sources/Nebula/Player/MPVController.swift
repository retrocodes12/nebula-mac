import Foundation
import QuartzCore
import Libmpv
import NebulaCore

struct MediaTrack: Identifiable, Equatable {
    var id: Int
    var type: String          // video | audio | sub
    var lang: String
    var title: String
    var codec: String
    var selected: Bool
    var external: Bool
    var channels: Int
    var height: Int

    var label: String {
        var parts: [String] = []
        let name = Lang.name(lang)
        if !name.isEmpty { parts.append(name) }
        if !title.isEmpty && title.lowercased() != name.lowercased() { parts.append(title) }
        if parts.isEmpty { parts.append(type == "sub" ? "Track \(id)" : "Audio \(id)") }
        if type == "audio" && channels > 0 { parts.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : channels == 2 ? "Stereo" : "\(channels) ch") }
        return parts.joined(separator: " · ")
    }
}

/// The engine: libmpv behind a small observable surface. libmpv reads every container and codec
/// FFmpeg does, and decrypts protected DASH when handed the keys — none of which AVPlayer can do.
final class MPVController: ObservableObject {
    @Published var timePos: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var buffering = true
    @Published var loaded = false
    @Published var ended = false
    @Published var failure: String?
    @Published var tracks: [MediaTrack] = []
    @Published var volume: Double = 100
    @Published var muted = false
    @Published var speed: Double = 1
    @Published var cacheAhead: Double = 0
    @Published var seekable = true
    @Published var videoHeight = 0
    @Published var hwdec = ""

    /// A stream with no length is live: no resume point, no scrubbing past the edge.
    var isLive: Bool { loaded && duration <= 0 }
    /// How far behind the live edge the viewer's own steps back have put them. A step forward
    /// through a live stream only ever undoes those: past them is the edge, where a jump would
    /// only buffer. Main thread only (the chrome and the system's remote commands both are).
    @Published private(set) var liveLag: Double = 0
    /// Whether a step back or forward can go anywhere.
    var canStepBack: Bool { !isLive || seekable }
    var canStepForward: Bool { !isLive || (seekable && liveLag >= 1) }

    let layer = MetalLayer()
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "nebula.mpv", qos: .userInitiated)
    private var lastErrorLines: [String] = []
    private var closed = false
    private let headless: Bool
    private let debug = ProcessInfo.processInfo.environment["NEBULA_MPV_DEBUG"] == "1"

    static let userAgent = "NebulaPlayer/\(AppInfo.version) (\(Platform.userAgentSystem)) libmpv"

    init(headless: Bool = false, hardwareDecoding: Bool = true) {
        self.headless = headless
        guard let h = mpv_create() else { failure = "The player could not start."; return }
        mpv = h
        check(mpv_request_log_messages(h, debug ? "v" : "warn"))
        if headless {
            set("vo", "null"); set("ao", "null")
        } else {
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            check(mpv_set_option(h, "wid", MPV_FORMAT_INT64, &wid))
            set("vo", "gpu-next"); set("gpu-api", "vulkan"); set("gpu-context", "moltenvk")
            set("hwdec", hardwareDecoding ? "auto-safe" : "no")
        }
        set("ytdl", "no")
        set("input-default-bindings", "no"); set("input-vo-keyboard", "no"); set("osc", "no"); set("osd-level", "0")
        set("input-media-keys", "no")
        set("keep-open", "yes")                       // the end is ours to act on, not a closed file
        set("idle", "yes")
        set("user-agent", MPVController.userAgent)
        set("network-timeout", "30")
        set("cache", "yes"); set("demuxer-max-bytes", "256MiB"); set("demuxer-readahead-secs", "120")
        set("sub-auto", "no"); set("sub-visibility", "yes")
        set("sub-font-size", "44"); set("sub-border-size", "2.4"); set("sub-shadow-offset", "0")
        set("audio-channels", "auto-safe")
        set("screenshot-directory", NSTemporaryDirectory())
        check(mpv_initialize(h))

        for (name, fmt) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
                            ("paused-for-cache", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
                            ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG), ("speed", MPV_FORMAT_DOUBLE),
                            ("demuxer-cache-duration", MPV_FORMAT_DOUBLE), ("seekable", MPV_FORMAT_FLAG),
                            ("track-list", MPV_FORMAT_NONE), ("video-params/h", MPV_FORMAT_INT64), ("hwdec-current", MPV_FORMAT_STRING)] {
            mpv_observe_property(h, 0, name, fmt)
        }
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx = ctx else { return }
            Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: commands

    /// Start a stream. Keys and headers apply to this file only.
    func load(url: String, startAt given: Double = 0, keys: [String: String] = [:], headers: [String: String] = [:]) {
        guard mpv != nil else { return }
        // a resume point is somebody else's number (the TV's, the sync server's): `Int(...)` of
        // an infinite or enormous one traps, so anything that is not a place in a film is 0
        let startAt = given.isFinite && given > 0 && given < 10_000_000 ? given : 0
        DispatchQueue.main.async { [self] in
            loaded = false; ended = false; failure = nil; buffering = true; timePos = startAt; duration = 0; tracks = []; liveLag = 0
        }
        // the error lines are appended on the engine's queue; clearing them from here raced it.
        // Queued before the load, this runs before any event of the new file is handled.
        queue.async { [weak self] in self?.lastErrorLines = [] }
        setProperty("demuxer-lavf-o", ClearKey.demuxerOptions(keys))
        var fields = ["X-Nebula-Client: \(Net.clientName)"]
        for (k, v) in headers where k.lowercased() != "user-agent" { fields.append("\(k): \(v.replacingOccurrences(of: ",", with: "\\,"))") }
        setProperty("http-header-fields", fields.joined(separator: ","))
        if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value { setProperty("user-agent", ua) }
        else { setProperty("user-agent", MPVController.userAgent) }
        setFlag("pause", false)
        var args = [url, "replace", "-1"]
        if startAt > 1 { args.append("start=\(Int(startAt))") }
        command("loadfile", args)
    }

    func togglePause() { setFlag("pause", !paused) }
    func setPaused(_ p: Bool) { setFlag("pause", p) }

    /// A step through a live stream stays inside what the engine can reach: back only where it
    /// says it can seek, forward only as far back as the viewer stepped — the edge, no further.
    func seek(by given: Double) {
        var secs = given
        if isLive {
            guard seekable else { return }
            if secs > 0 { secs = min(secs, liveLag) }
            guard abs(secs) >= 1 else { return }
            liveLag = max(0, liveLag - secs)
        }
        command("seek", [String(secs), "relative"])
    }

    func seek(to secs: Double) { command("seek", [String(max(0, secs)), "absolute"]) }

    func setVolume(_ v: Double) { setDouble("volume", min(130, max(0, v))) }
    func toggleMute() { setFlag("mute", !muted) }
    func setSpeed(_ s: Double) { setDouble("speed", s) }

    func selectTrack(_ type: String, id: Int?) {
        setProperty(type == "audio" ? "aid" : type == "video" ? "vid" : "sid", id.map(String.init) ?? "no")
    }

    /// A caption file from an add-on. Loaded without selecting unless asked. Asynchronous: each
    /// one is a download, and the synchronous call held the calling (main) thread until it was
    /// done — seconds of a frozen window with a few dozen languages.
    func addSubtitle(url: String, lang: String, title: String, select: Bool) {
        commandAsync("sub-add", [url, select ? "select" : "auto", title, lang])
    }

    func setSubDelay(_ secs: Double) { setDouble("sub-delay", secs) }

    /// Picture on or off, the sound untouched. A phone may not draw with the GPU while the app
    /// is in the background, and a video output left drawing there comes back black; taking the
    /// video track away while away and giving it back on return is the MPVKit demo's own cure.
    func setVideo(_ on: Bool) { setProperty("vid", on ? "auto" : "no") }

    func stop() { command("stop", []) }

    /// Let go of the engine. Destroying it waits for its threads, so that happens off the main
    /// thread; `then` runs on the main thread once it is gone — its sound output with it, which
    /// is when a phone can hand the audio session back.
    func close(then done: (@MainActor @Sendable () -> Void)? = nil) {
        guard let h = mpv, !closed else {
            if let done = done { Task { @MainActor in done() } }
            return
        }
        closed = true
        mpv_set_wakeup_callback(h, nil, nil)
        mpv = nil
        queue.async {
            mpv_terminate_destroy(h)
            if let done = done { Task { @MainActor in done() } }
        }
    }

    deinit { close() }

    // MARK: plumbing

    private func check(_ status: CInt) {
        if status < 0 && debug { FileHandle.standardError.write(Data("mpv: \(String(cString: mpv_error_string(status)))\n".utf8)) }
    }

    private func set(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        check(mpv_set_option_string(h, name, value))
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        check(mpv_set_property_string(h, name, value))
    }

    private func setFlag(_ name: String, _ on: Bool) {
        guard let h = mpv else { return }
        var v: CInt = on ? 1 : 0
        check(mpv_set_property(h, name, MPV_FORMAT_FLAG, &v))
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let h = mpv else { return }
        var v = value
        check(mpv_set_property(h, name, MPV_FORMAT_DOUBLE, &v))
    }

    func string(_ name: String) -> String {
        guard let h = mpv, let c = mpv_get_property_string(h, name) else { return "" }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    private func command(_ name: String, _ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p = p { free(UnsafeMutablePointer(mutating: p)) } } }
        check(mpv_command(h, &cargs))
    }

    /// Queue a command and return at once; the reply arrives as an event nobody needs. mpv
    /// parses (copies) the arguments before this returns, so they can be freed here.
    private func commandAsync(_ name: String, _ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs { if let p = p { free(UnsafeMutablePointer(mutating: p)) } } }
        check(mpv_command_async(h, 0, &cargs))
    }

    private func readTracks() -> [MediaTrack] {
        let n = Int(string("track-list/count")) ?? 0
        return (0..<n).map { i in
            let p = "track-list/\(i)/"
            return MediaTrack(id: Int(string(p + "id")) ?? 0, type: string(p + "type"), lang: string(p + "lang"), title: string(p + "title"),
                              codec: string(p + "codec"), selected: string(p + "selected") == "yes", external: string(p + "external") == "yes",
                              channels: Int(string(p + "demux-channel-count")) ?? 0, height: Int(string(p + "demux-h")) ?? 0)
        }
    }

    private func drain() {
        queue.async { [weak self] in
            guard let self = self else { return }
            while let h = self.mpv, !self.closed {
                guard let ev = mpv_wait_event(h, 0)?.pointee, ev.event_id != MPV_EVENT_NONE else { break }
                self.handle(ev)
            }
        }
    }

    private var lastPublishedPos: Double = -1

    private func handle(_ ev: mpv_event) {
        switch ev.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let p = ev.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { return }
            let name = String(cString: p.name)
            let double = p.format == MPV_FORMAT_DOUBLE ? p.data?.assumingMemoryBound(to: Double.self).pointee : nil
            let flag = p.format == MPV_FORMAT_FLAG ? p.data.map { $0.assumingMemoryBound(to: CInt.self).pointee != 0 } : nil
            switch name {
            case "time-pos":
                guard let t = double else { return }
                // the engine reports every frame; the chrome needs a few a second
                if abs(t - lastPublishedPos) < 0.25 { return }
                lastPublishedPos = t
                publish { $0.timePos = t }
            case "duration": publish { $0.duration = double ?? 0 }
            case "pause": if let f = flag { publish { $0.paused = f } }
            case "paused-for-cache", "seeking":
                let busy = string("paused-for-cache") == "yes" || string("seeking") == "yes"
                publish { $0.buffering = busy && !$0.ended }
            case "eof-reached": if flag == true { publish { $0.ended = true; $0.buffering = false } }
            case "volume": if let v = double { publish { $0.volume = v } }
            case "mute": if let f = flag { publish { $0.muted = f } }
            case "speed": if let v = double { publish { $0.speed = v } }
            case "demuxer-cache-duration": publish { $0.cacheAhead = double ?? 0 }
            case "seekable": if let f = flag { publish { $0.seekable = f } }
            case "track-list":
                let t = readTracks()
                publish { $0.tracks = t }
            case "video-params/h":
                let hgt = p.format == MPV_FORMAT_INT64 ? Int(p.data?.assumingMemoryBound(to: Int64.self).pointee ?? 0) : 0
                publish { $0.videoHeight = hgt }
            case "hwdec-current":
                let s = string("hwdec-current")
                publish { $0.hwdec = s }
            default: break
            }
        case MPV_EVENT_FILE_LOADED:
            let t = readTracks()
            publish { $0.loaded = true; $0.buffering = false; $0.tracks = t }
        case MPV_EVENT_END_FILE:
            guard let e = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return }
            if e.reason == MPV_END_FILE_REASON_ERROR {
                let code = String(cString: mpv_error_string(e.error))
                let detail = lastErrorLines.last ?? code
                publish { $0.failure = MPVController.sentence(code: code, detail: detail); $0.buffering = false }
            } else if e.reason == MPV_END_FILE_REASON_EOF {
                publish { $0.ended = true; $0.buffering = false }
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let m = ev.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee else { return }
            let level = String(cString: m.level), text = String(cString: m.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if debug { FileHandle.standardError.write(Data("[\(String(cString: m.prefix))] \(level): \(text)\n".utf8)) }
            if level == "error" || level == "fatal" {
                lastErrorLines.append(text)
                if lastErrorLines.count > 6 { lastErrorLines.removeFirst() }
            }
        default: break
        }
    }

    private func publish(_ change: @escaping (MPVController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.closed else { return }
            change(self)
        }
    }

    /// One sentence a viewer can act on, never an error code on its own.
    static func sentence(code: String, detail: String) -> String {
        let d = detail.lowercased()
        if d.contains("403") || d.contains("401") { return "The source refused this stream. Try another one." }
        if d.contains("404") || d.contains("410") { return "This stream is gone from its source. Try another one." }
        if d.contains("timed out") || d.contains("timeout") || d.contains("network") || d.contains("connection") { return "The source did not answer. Check the connection, or try another stream." }
        if code.contains("unrecognized file format") || d.contains("invalid data") { return "This stream is not something the player can read. Try another one." }
        if code.contains("no audio or video") { return "This stream has no picture or sound in it. Try another one." }
        return "This stream could not be played. Try another one."
    }
}

/// The video surface. A MoltenVK quirk sets the drawable to 1×1 to force a present, which
/// flickers and can stick — refuse that size (mpv-player/mpv#13651).
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }

    // turning extended range on only takes effect from the main thread. The engine sets it
    // from its render thread; waiting there for the main thread (main.sync) deadlocks the
    // moment the main thread is itself waiting on the engine, so the change is posted instead.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.async { [weak self] in self?.setExtendedRange(newValue) } }
        }
    }

    private func setExtendedRange(_ on: Bool) { super.wantsExtendedDynamicRangeContent = on }
}

enum Lang {
    static let names: [String: String] = [
        "eng": "English", "en": "English", "spa": "Spanish", "es": "Spanish", "fre": "French", "fra": "French", "fr": "French",
        "ger": "German", "deu": "German", "de": "German", "ita": "Italian", "it": "Italian", "por": "Portuguese", "pt": "Portuguese",
        "pob": "Portuguese (Brazil)", "rus": "Russian", "ru": "Russian", "jpn": "Japanese", "ja": "Japanese", "kor": "Korean", "ko": "Korean",
        "chi": "Chinese", "zho": "Chinese", "zh": "Chinese", "hin": "Hindi", "hi": "Hindi", "tam": "Tamil", "ta": "Tamil", "tel": "Telugu",
        "te": "Telugu", "mal": "Malayalam", "ml": "Malayalam", "kan": "Kannada", "kn": "Kannada", "ara": "Arabic", "ar": "Arabic",
        "tur": "Turkish", "tr": "Turkish", "dut": "Dutch", "nld": "Dutch", "nl": "Dutch", "pol": "Polish", "pl": "Polish",
        "swe": "Swedish", "sv": "Swedish", "dan": "Danish", "da": "Danish", "nor": "Norwegian", "no": "Norwegian", "fin": "Finnish", "fi": "Finnish",
        "gre": "Greek", "ell": "Greek", "el": "Greek", "heb": "Hebrew", "he": "Hebrew", "hun": "Hungarian", "hu": "Hungarian",
        "cze": "Czech", "ces": "Czech", "cs": "Czech", "rum": "Romanian", "ron": "Romanian", "ro": "Romanian", "tha": "Thai", "th": "Thai",
        "vie": "Vietnamese", "vi": "Vietnamese", "ind": "Indonesian", "id": "Indonesian", "ukr": "Ukrainian", "uk": "Ukrainian",
        "ben": "Bengali", "bn": "Bengali", "urd": "Urdu", "ur": "Urdu", "per": "Persian", "fas": "Persian", "fa": "Persian",
        "bul": "Bulgarian", "bg": "Bulgarian", "hrv": "Croatian", "hr": "Croatian", "srp": "Serbian", "sr": "Serbian", "may": "Malay", "msa": "Malay", "ms": "Malay",
    ]

    /// A language the viewer can read; a code nobody knows comes back as it is, never as "Unknown".
    static func name(_ code: String) -> String {
        let c = code.lowercased()
        if c.isEmpty || c == "und" { return "" }
        if let n = names[c] { return n }
        if let n = Locale(identifier: "en").localizedString(forLanguageCode: c), n.lowercased() != c { return n }
        return code
    }
}
