import AVFoundation
import Foundation
import os

/// Speaks replies with the Hermes gateway's own TTS (`POST /api/audio/speak`), i.e. whatever
/// provider and voice are picked in Hermes Desktop › Settings › Voice › Text to speech.
///
/// The reply is cut into sentences; the first is requested right away and each next one is
/// fetched while the current one plays, so speech starts after one short synthesis and then
/// flows without gaps. `stop()` cancels everything at once (barge-in). If the gateway can't
/// synthesize (offline, signed out, provider error), the rest of the reply falls back to the
/// macOS system voice via `SystemVoiceSpeaker`.
final class GatewaySpeaker: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    private let auth: AuthManager?
    private let prefs = Preferences.shared
    private let fallback = SystemVoiceSpeaker()
    private let log = Logger(subsystem: "com.alexk.float", category: "tts")
    private var task: Task<Void, Never>?
    private var pending: [Task<Data?, Never>] = []
    private var player: AVAudioPlayer?
    private var playDone: CheckedContinuation<Bool, Never>?
    private var generation = 0

    init(auth: AuthManager?) {
        self.auth = auth
        super.init()
        fallback.onFinish = { [weak self] in self?.onFinish?() }
    }

    func speak(_ text: String, wordsPerMinute: Int) {
        stop()
        generation += 1
        let gen = generation
        let chunks = Self.chunks(text)
        guard !chunks.isEmpty else { onFinish?(); return }
        guard auth?.isSignedIn == true, prefs.baseURL != nil else {
            fallback.speak(text, wordsPerMinute: wordsPerMinute); return
        }
        task = Task { [weak self] in
            guard let self else { return }
            var next: Task<Data?, Never>? = self.fetch(chunks[0])
            for i in chunks.indices {
                guard let current = next else { break }
                let audio = await current.value
                guard !Task.isCancelled, gen == self.generation else { return }
                next = i + 1 < chunks.count ? self.fetch(chunks[i + 1]) : nil  // prefetch while playing
                let played: Bool
                if let audio { played = await self.play(audio) } else { played = false }
                guard !Task.isCancelled, gen == self.generation else { return }
                if !played {
                    next?.cancel()
                    self.log.notice("gateway TTS unavailable; falling back to system voice")
                    self.fallback.speak(chunks[i...].joined(separator: " "), wordsPerMinute: wordsPerMinute)
                    return
                }
            }
            self.player = nil
            self.onFinish?()
        }
    }

    /// Stops speech immediately; does not fire `onFinish`.
    func stop() {
        generation += 1
        task?.cancel(); task = nil
        pending.forEach { $0.cancel() }; pending.removeAll()
        player?.stop(); player = nil
        playDone?.resume(returning: false); playDone = nil
        fallback.stop()
    }

    // MARK: Synthesis

    private func fetch(_ text: String) -> Task<Data?, Never> {
        let t = Task<Data?, Never> { [weak self] in
            guard let self, let base = self.prefs.baseURL, let auth = self.auth else { return nil }
            do {
                var req = URLRequest(url: base.appending(path: "api/audio/speak"))
                req.httpMethod = "POST"
                req.timeoutInterval = 30
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let url = json["data_url"] as? String, let comma = url.firstIndex(of: ",")
                else {
                    self.log.error("speak failed: HTTP \(status)")
                    return nil
                }
                return Data(base64Encoded: String(url[url.index(after: comma)...]))
            } catch {
                if !Task.isCancelled { self.log.error("speak failed: \(error.localizedDescription, privacy: .public)") }
                return nil
            }
        }
        pending.append(t)
        return t
    }

    // MARK: Playback

    private func play(_ audio: Data) async -> Bool {
        guard let p = try? AVAudioPlayer(data: audio) else { return false }
        p.delegate = self
        player = p
        return await withCheckedContinuation { cont in
            playDone = cont
            if !p.play() { playDone = nil; cont.resume(returning: false) }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully ok: Bool) {
        Task { @MainActor in self.finished(p, ok) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished(p, false) }
    }

    private func finished(_ p: AVAudioPlayer, _ ok: Bool) {
        guard p === player else { return }
        playDone?.resume(returning: ok); playDone = nil
    }

    // MARK: Sentences

    /// Sentences, with short ones merged so each request carries a natural phrase. The first chunk
    /// stays a single sentence so the first word comes as soon as possible.
    static func chunks(_ text: String, minLength: Int = 80) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [t]
        }
        var out = [sentences.removeFirst()]
        var buf = ""
        for s in sentences {
            buf = buf.isEmpty ? s : buf + " " + s
            if buf.count >= minLength { out.append(buf); buf = "" }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }
}
