import AVFoundation

/// Scroll-wheel detents for the slide control: one short click per step, synthesised in
/// the render callback (no sample files).  A click is a bright, few-millisecond tick (a
/// resonant burst around 3 kHz) over a small low "thunk", each with a little random
/// variation so a run of clicks does not sound machine-gunned.  Steps that arrive
/// together (the card reports every ~26 ms) are spread evenly over that interval, so a
/// fast slide becomes a fast, even ratchet.
final class WheelSound {
    /// Shared with the render thread.  Plain words, read and written whole.
    private final class Control {
        var gain: Float = 0.6
        var pending: Int32 = 0       // clicks waiting to be played
        var spacing: Int32 = 1200    // samples between them
    }

    private let engine = AVAudioEngine()
    private let ctl = Control()
    private var running = false
    private var idleStop: DispatchWorkItem?

    var volume: Float {
        get { ctl.gain }
        set { ctl.gain = max(0, min(1, newValue)) }
    }

    /// `count` detents passed during the last `interval` seconds.
    func clicks(_ count: Int, over interval: TimeInterval) {
        guard count > 0 else { return }
        if !running { start() }
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let n = min(count, 12)
        // spread over the reading interval, but never closer than 7 ms (a real wheel's limit)
        let gap = max(0.007, min(interval, 0.05) / Double(n))
        ctl.spacing = Int32(gap * (sr > 0 ? sr : 48000))
        ctl.pending = min(ctl.pending + Int32(n), 16)
        // let the engine sleep when the finger has been still for a while
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func stop() {
        ctl.pending = 0
        if running {
            engine.stop()
            running = false
        }
    }

    private func start() {
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        let sr = Float(fmt.sampleRate > 0 ? fmt.sampleRate : 48000)
        if engine.attachedNodes.count <= 2 {  // input/output nodes only
            let node = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 2)!,
                                         renderBlock: WheelSound.renderer(ctl, sr))
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
        }
        do {
            try engine.start()
            running = true
        } catch {
            running = false
        }
    }

    private static func renderer(_ ctl: Control, _ sr: Float) -> AVAudioSourceNodeRenderBlock {
        var seed: UInt32 = 0x2468_ACE1
        var since: Int32 = 1 << 20     // samples since the last click
        // the current click: tick resonator and body oscillator, each with its own decay
        var tickEnv: Float = 0, bodyEnv: Float = 0, noiseEnv: Float = 0
        var tickPhase: Float = 0, bodyPhase: Float = 0
        var tickFreq: Float = 3000, bodyFreq: Float = 160
        var level: Float = 1
        let tickDecay = expf(-1 / (0.0025 * sr))   // ~2.5 ms
        let bodyDecay = expf(-1 / (0.006 * sr))    // ~6 ms
        let noiseDecay = expf(-1 / (0.0006 * sr))  // the initial snap
        var hp: Float = 0, lastIn: Float = 0

        func rnd() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)   // 0 ..< 1
        }

        return { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let gain = ctl.gain
            for i in 0..<Int(frameCount) {
                since &+= 1
                if ctl.pending > 0 && since >= ctl.spacing {
                    ctl.pending -= 1
                    since = 0
                    tickEnv = 1
                    bodyEnv = 1
                    noiseEnv = 1
                    tickPhase = 0
                    bodyPhase = 0
                    tickFreq = 2700 + 700 * rnd()
                    bodyFreq = 140 + 50 * rnd()
                    level = 0.85 + 0.15 * rnd()
                }
                var out: Float = 0
                if tickEnv > 1e-4 || bodyEnv > 1e-4 {
                    tickPhase += tickFreq / sr
                    if tickPhase >= 1 { tickPhase -= 1 }
                    bodyPhase += bodyFreq / sr
                    if bodyPhase >= 1 { bodyPhase -= 1 }
                    let n = rnd() * 2 - 1
                    out = 0.55 * sinf(2 * .pi * tickPhase) * tickEnv
                        + 0.35 * sinf(2 * .pi * bodyPhase) * bodyEnv
                        + 0.5 * n * noiseEnv
                    out *= level
                    tickEnv *= tickDecay
                    bodyEnv *= bodyDecay
                    noiseEnv *= noiseDecay
                }
                // gentle high-pass so the body never thumps the speaker
                hp = 0.995 * (hp + out - lastIn)
                lastIn = out
                let s = tanhf(hp * 1.4 * gain) * 0.85
                for b in buffers {
                    b.mData!.assumingMemoryBound(to: Float.self)[i] = s
                }
            }
            return noErr
        }
    }
}
