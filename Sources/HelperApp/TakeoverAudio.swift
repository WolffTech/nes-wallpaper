import AudioToolbox
import Foundation

// Audio for live play only: the wallpaper is silent, but a taken-over tile
// plays its game's sound. The emulation thread drains the core's per-frame
// samples into a ring; an AudioQueue pulls from it on its own thread.

/// Ring of 16-bit mono samples. Writer (emulation thread) drops the newest
/// samples on overrun; reader (AudioQueue callback) zero-fills on underrun,
/// so clock drift in either direction degrades to a brief glitch instead of
/// growing latency or blocking the emulation loop.
final class AudioRing {
    private var samples: [Int16]
    private var readIndex = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        samples = [Int16](repeating: 0, count: capacity)
    }

    func write(_ source: UnsafePointer<Int32>, count n: Int) {
        lock.lock(); defer { lock.unlock() }
        let capacity = samples.count
        let toWrite = min(n, capacity - count)
        var w = (readIndex + count) % capacity
        for i in 0..<toWrite {
            samples[w] = Int16(clamping: source[i])
            w = (w + 1) % capacity
        }
        count += toWrite
    }

    /// Fills all n samples, zero-padding whatever the ring cannot supply.
    func read(into out: UnsafeMutablePointer<Int16>, count n: Int) {
        lock.lock(); defer { lock.unlock() }
        let capacity = samples.count
        let toRead = min(n, count)
        for i in 0..<toRead {
            out[i] = samples[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        count -= toRead
        for i in toRead..<n { out[i] = 0 }
    }
}

private func takeoverAudioCallback(
    userData: UnsafeMutableRawPointer?, queue: AudioQueueRef,
    buffer: AudioQueueBufferRef
) {
    guard let userData else { return }
    Unmanaged<TakeoverAudio>.fromOpaque(userData)
        .takeUnretainedValue().fill(buffer, queue: queue)
}

/// Mono 44.1 kHz AudioQueue fed from an AudioRing. Fails soft: a nil init
/// means no audio output is available and the caller plays silently.
final class TakeoverAudio {
    static let sampleRate = 44100

    private let ring = AudioRing(capacity: TakeoverAudio.sampleRate / 4)
    private var queue: AudioQueueRef?

    /// ~1 NES frame of samples per buffer; three buffers in flight give a
    /// ~37ms cushion against 60.0988 fps emulation vs the audio clock.
    private static let samplesPerBuffer = 736
    private static let bufferCount = 3

    init?() {
        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger
                | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var created: AudioQueueRef?
        let userData = Unmanaged.passUnretained(self).toOpaque()
        guard AudioQueueNewOutput(&format, takeoverAudioCallback, userData,
                                  nil, nil, 0, &created) == noErr,
              let created else { return nil }
        queue = created

        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            let bytes = UInt32(Self.samplesPerBuffer * 2)
            guard AudioQueueAllocateBuffer(created, bytes, &buffer) == noErr,
                  let buffer else {
                AudioQueueDispose(created, true)
                queue = nil
                return nil
            }
            // Prime with silence; the callback refills from the ring.
            memset(buffer.pointee.mAudioData, 0, Int(bytes))
            buffer.pointee.mAudioDataByteSize = bytes
            AudioQueueEnqueueBuffer(created, buffer, 0, nil)
        }
        guard AudioQueueStart(created, nil) == noErr else {
            AudioQueueDispose(created, true)
            queue = nil
            return nil
        }
    }

    /// Emulation thread: hand over one frame's samples from the core.
    func append(_ samples: UnsafePointer<Int32>, count: Int) {
        ring.write(samples, count: count)
    }

    fileprivate func fill(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) {
        let n = Int(buffer.pointee.mAudioDataBytesCapacity) / 2
        ring.read(into: buffer.pointee.mAudioData
            .assumingMemoryBound(to: Int16.self), count: n)
        buffer.pointee.mAudioDataByteSize = UInt32(n * 2)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    /// Synchronous stop; safe to call once and required before release (the
    /// callback holds an unretained reference to self).
    func stop() {
        guard let queue else { return }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
    }
}
