import CoreAudio
import Foundation

/// The Mac's output volume (default output device), for driving it from finger slides.
public enum SystemVolume {
    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr ? id : nil
    }

    /// Main element if the device has one, else the two stereo channels.
    private static func elements(_ dev: AudioDeviceID) -> [UInt32] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(dev, &addr) ? [kAudioObjectPropertyElementMain] : [1, 2]
    }

    /// 0...1, nil if the device has no settable volume.
    public static func get() -> Double? {
        guard let dev = device() else { return nil }
        var vals: [Float32] = []
        for el in elements(dev) {
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr {
                vals.append(v)
            }
        }
        return vals.isEmpty ? nil : Double(vals.reduce(0, +) / Float32(vals.count))
    }

    public static func set(_ value: Double) {
        guard let dev = device() else { return }
        var v = Float32(max(0, min(1, value)))
        for el in elements(dev) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }
}
