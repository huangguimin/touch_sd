import AVFoundation

/// A cross-plane V8, synthesised sample by sample: no recordings, so the pitch follows the
/// revs without the warble of a resampled loop.  Each cylinder fires a short pressure pulse
/// into one of two exhaust banks.  The uneven order per bank is what makes the burble.
/// A pulse runs through the pipe (a comb filter) and the fixed resonances of the exhaust
/// (they do not move with the revs, which is why a real engine swells at certain speeds),
/// then the saturation of a loud exhaust.  Induction noise rises with revs and load; the
/// revs falling with the throttle shut gives overrun crackle.
final class EngineSynth {
    static let idle: Float = 1000, redline: Float = 8400

    /// Set from the main thread, read in render().  Plain words, read and written whole.
    var targetRPM: Float = EngineSynth.idle
    var on = false
    var gain: Float = 0.6

    private(set) var rpm: Float = EngineSynth.idle
    private let sr: Float
    private var master: Float = 0
    private var load: Float = 0
    private var phase: Float = 0
    private var interval: Float = 1          // of this firing slot, for the jitter
    private var slot = 0
    private var seed: UInt32 = 0x1357_9BDF
    private var popEnv: Float = 0
    private var popBank = 0
    private var tone: [Float] = [0, 0]
    private var intakeLP: Float = 0, intakeBP: Float = 0
    private var dcIn: [Float] = [0, 0], dcOut: [Float] = [0, 0]

    // firing order 1-8-4-3-6-5-7-2 by bank: two pulses in a row on one side
    private static let bank = [0, 1, 0, 1, 1, 0, 1, 0]
    private let trim: [Float] = [1.0, 0.91, 1.07, 0.96, 1.04, 0.93, 1.09, 0.98]

    private struct Biquad {
        var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        init(freq: Float, q: Float, sr: Float) {
            let w = 2 * Float.pi * freq / sr
            let alpha = sinf(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = -2 * cosf(w) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = -a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private struct Bank {
        var env: Float = 0
        var pipe: [Float]
        var at = 0
        var ret: Float = 0
        var body: Biquad, mid: Biquad, rasp: Biquad
    }

    private var banks: [Bank]
    private let pulseDecay: Float
    private let popDecay: Float

    init(sampleRate: Float) {
        sr = sampleRate
        pulseDecay = expf(-1 / (0.0028 * sampleRate))
        popDecay = expf(-1 / (0.007 * sampleRate))
        func bank(_ pipeSeconds: Float, _ f: Float) -> Bank {
            Bank(pipe: [Float](repeating: 0, count: Int(pipeSeconds * sampleRate)),
                 body: Biquad(freq: 105 * f, q: 1.6, sr: sampleRate),
                 mid: Biquad(freq: 255 * f, q: 1.4, sr: sampleRate),
                 rasp: Biquad(freq: 730 * f, q: 1.1, sr: sampleRate))
        }
        banks = [bank(0.0104, 1.0), bank(0.0113, 1.04)]  // the pipes are never quite equal
    }

    private func rnd() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24)
    }

    private func fire() {
        slot = (slot + 1) % 8
        let revs = rpm / EngineSynth.redline
        // a lumpy idle, smoother with the revs
        let rough = 0.28 * (1 - revs) + 0.06
        let amp = trim[slot] * (1 + rough * (rnd() - 0.5)) * (0.55 + 0.75 * load)
        banks[EngineSynth.bank[slot]].env += amp
        interval = 1 + 0.03 * (1 - revs) * (rnd() - 0.5)
    }

    func render(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        let target = targetRPM, gain = self.gain, on = self.on
        let up = 1 - expf(-1 / (0.09 * sr)), down = 1 - expf(-1 / (0.42 * sr))
        let attack = 1 - expf(-1 / (0.05 * sr)), release = 1 - expf(-1 / (0.55 * sr))
        let loadSpeed = 1 - expf(-1 / (0.05 * sr))
        let intakeC = 2 * sinf(.pi * 2300 / sr)
        var out = [Float](repeating: 0, count: 2)
        for i in 0..<frames {
            let gap = target - rpm
            rpm += gap * (gap > 0 ? up : down)
            let wanted = max(0, min(1, gap / 1400))
            load += (wanted - load) * loadSpeed
            master += ((on ? 1 : 0) - master) * (on ? attack : release)

            phase += rpm / 15 / sr          // 8 cylinders, 4 strokes: rpm / 15 firings a second
            if phase >= interval {
                phase -= interval
                fire()
            }

            let revs = rpm / EngineSynth.redline
            // fuel in a hot exhaust with the throttle shut
            let overrun = max(0, min(1, -gap / 2500)) * revs
            if popEnv < 0.02, rnd() < overrun * 26 / sr {
                popEnv = 0.6 + 0.6 * rnd()
                popBank = rnd() < 0.5 ? 0 : 1
            }
            let noise = rnd() * 2 - 1
            let pop = popEnv * noise
            popEnv *= popDecay

            let drive = 1.4 + 2.6 * load + 0.8 * revs
            let cutoff = 900 + 6200 * revs * sqrtf(revs) * (0.6 + 0.4 * load)
            let toneC = 1 - expf(-2 * .pi * cutoff / sr)

            // induction: a band of noise that breathes with the firing pulses
            intakeLP += intakeC * intakeBP
            intakeBP += intakeC * (noise - intakeLP - 0.35 * intakeBP)
            let breath = banks[0].env + banks[1].env
            let intake = intakeBP * (0.04 + 0.3 * load) * revs * revs * (0.5 + 0.5 * min(1, breath))

            for b in 0..<2 {
                let e = banks[b].env * (0.75 + 0.5 * noise) + (popBank == b ? pop : 0)
                banks[b].env *= pulseDecay
                // the pipe: what comes back from the open end, duller each trip
                let at = banks[b].at
                let back = banks[b].pipe[at]
                banks[b].ret += (back - banks[b].ret) * 0.35
                let x = e + 0.52 * banks[b].ret
                banks[b].pipe[at] = x
                banks[b].at = at + 1 == banks[b].pipe.count ? 0 : at + 1
                let shaped = 1.5 * banks[b].body.run(x) + 1.25 * banks[b].mid.run(x)
                    + 0.8 * banks[b].rasp.run(x) + 0.16 * x
                let sat = tanhf(shaped * drive)
                tone[b] += (sat - tone[b]) * toneC
                // no DC into the speaker
                dcOut[b] = 0.998 * (dcOut[b] + tone[b] - dcIn[b])
                dcIn[b] = tone[b]
                out[b] = dcOut[b] + intake
            }
            // laptop speakers lose the fundamental at low revs: more level to reach them
            let level = 1.7 * master * gain * (0.5 + 0.5 * revs)
            left[i] = tanhf((0.82 * out[0] + 0.38 * out[1]) * level)
            right[i] = tanhf((0.38 * out[0] + 0.82 * out[1]) * level)
        }
    }
}

/// The synth on the audio output: runs while a slide is on, sleeps after it.
final class EngineSound {
    private let engine = AVAudioEngine()
    private var synth: EngineSynth?
    private var running = false
    private var sliding = false
    private var idleStop: DispatchWorkItem?
    private var wantedGain: Float = 0.6

    var volume: Float {
        get { wantedGain }
        set {
            wantedGain = max(0, min(1, newValue))
            synth?.gain = wantedGain
        }
    }

    /// `speed` in sensor rows a second: a slow slide ~150, a fast one ~2500.  A touch only
    /// starts the engine once it moves: a press to unlock stays silent.
    func update(speed: Double, touching: Bool) {
        if touching && (sliding || speed > 70) {
            sliding = true
            if !running { start() }
            let x = Float(log(1 + min(speed, 2600) / 120) / log(1 + 2600.0 / 120))
            synth?.targetRPM = EngineSynth.idle + (EngineSynth.redline - EngineSynth.idle) * x
            synth?.on = true
            idleStop?.cancel()
        } else if sliding && !touching {
            sliding = false
            synth?.targetRPM = EngineSynth.idle
            synth?.on = false
            let w = DispatchWorkItem { [weak self] in self?.stop() }
            idleStop = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
        }
    }

    func stop() {
        sliding = false
        idleStop?.cancel()
        synth?.on = false
        if running {
            engine.stop()
            running = false
        }
    }

    private func start() {
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        let sr = fmt.sampleRate > 0 ? fmt.sampleRate : 48000
        if synth == nil {
            let s = EngineSynth(sampleRate: Float(sr))
            s.gain = wantedGain
            synth = s
            let node = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!) { _, _, frames, abl in
                let b = UnsafeMutableAudioBufferListPointer(abl)
                s.render(b[0].mData!.assumingMemoryBound(to: Float.self),
                         b[1].mData!.assumingMemoryBound(to: Float.self), Int(frames))
                return noErr
            }
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
}
