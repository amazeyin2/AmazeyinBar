import AudioToolbox
import Combine
import Darwin
import Foundation

private let audioPort: UInt16 = 49831
private let audioHeaderSize = 20

private struct LANAudioPacket {
    let sequence: UInt32
    let sampleRate: UInt32
    let frames: Int
    let pcm: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= audioHeaderSize,
              bytes[0...3].elementsEqual([76, 65, 66, 49]),
              bytes[4] == 1, bytes[5] == 2 else { return nil }
        func number(_ offset: Int, _ length: Int) -> UInt32 {
            bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let rate = number(12, 4)
        let frameCount = Int(number(16, 2))
        let length = Int(number(18, 2))
        guard (8000...96000).contains(rate), frameCount > 0,
              length == frameCount * 4, bytes.count == audioHeaderSize + length else { return nil }
        sequence = number(8, 4)
        sampleRate = rate
        frames = frameCount
        pcm = Array(bytes[audioHeaderSize...])
    }
}

private enum LANAudioFailure: Error {
    case audioQueue(OSStatus)
}

private final class LANAudioPlayer {
    private let lock = NSLock()
    private var packets: [[UInt8]] = []
    private var queue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef] = []
    private var expectedSequence: UInt32?
    private var lastArrival = Date.distantPast
    private var started = false
    private let packetBytes: Int
    private let startupPackets = 4
    private let maxPackets = 10

    init(rate: UInt32, frames: Int) throws {
        packetBytes = frames * 4
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let status = AudioQueueNewOutput(&format, { userData, audioQueue, buffer in
            guard let userData else { return }
            Unmanaged<LANAudioPlayer>.fromOpaque(userData).takeUnretainedValue().fill(audioQueue, buffer)
        }, Unmanaged.passUnretained(self).toOpaque(), nil, nil, 0, &queue)
        guard status == noErr, let queue else { throw LANAudioFailure.audioQueue(status) }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            let result = AudioQueueAllocateBuffer(queue, UInt32(packetBytes), &buffer)
            guard result == noErr, let buffer else { throw LANAudioFailure.audioQueue(result) }
            buffers.append(buffer)
        }
    }

    func receive(_ packet: LANAudioPacket) throws {
        lock.lock()
        if Date().timeIntervalSince(lastArrival) > 1 {
            expectedSequence = nil
            packets.removeAll(keepingCapacity: true)
        }
        lastArrival = Date()
        if let expectedSequence {
            let delta = Int32(bitPattern: packet.sequence &- expectedSequence)
            if delta < 0 { lock.unlock(); return }
            if delta > 0 && delta <= 3 {
                for _ in 0..<delta { packets.append([UInt8](repeating: 0, count: packetBytes)) }
            }
            if delta > 3 { packets.removeAll(keepingCapacity: true) }
        }
        expectedSequence = packet.sequence &+ 1
        packets.append(packet.pcm)
        if packets.count > maxPackets {
            packets.removeFirst(packets.count - maxPackets)
        }
        let shouldStart = !started && packets.count >= startupPackets
        if shouldStart { started = true }
        lock.unlock()

        if shouldStart, let queue {
            for buffer in buffers { fill(queue, buffer) }
            let result = AudioQueueStart(queue, nil)
            guard result == noErr else { throw LANAudioFailure.audioQueue(result) }
        }
    }

    private func fill(_ audioQueue: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
        lock.lock()
        let pcm = packets.isEmpty ? [UInt8](repeating: 0, count: packetBytes) : packets.removeFirst()
        lock.unlock()
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer.pointee.mAudioData, base, packetBytes) }
        }
        buffer.pointee.mAudioDataByteSize = UInt32(packetBytes)
        _ = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
    }

    deinit {
        if let queue { AudioQueueStop(queue, true); AudioQueueDispose(queue, true) }
    }
}

private final class LANAudioSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

@MainActor
final class LANAudioReceiver: ObservableObject {
    @Published private(set) var status = "已关闭"

    private let configStore: ConfigStore
    private let worker = DispatchQueue(label: "com.amazeyin.audio-receiver", qos: .userInitiated)
    private var session: LANAudioSession?
    private var configCancellable: AnyCancellable?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        configCancellable = configStore.$config.sink { [weak self] config in
            Task { @MainActor in self?.apply(enabled: config.allowAudioReceiving == true) }
        }
        apply(enabled: configStore.config.allowAudioReceiving == true)
    }

    private func apply(enabled: Bool) {
        if !enabled {
            session?.stop()
            session = nil
            status = "已关闭"
            return
        }
        guard session == nil else { return }
        let next = LANAudioSession()
        session = next
        status = "启动中"
        worker.async { [weak self] in
            guard let self else { return }
            Self.run(next) { message in
                Task { @MainActor in
                    guard self.session === next else { return }
                    self.status = message
                }
            }
        }
    }

    private nonisolated static func run(
        _ session: LANAudioSession,
        report: @escaping @Sendable (String) -> Void
    ) {
        guard !session.isStopped else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { report("无法创建 UDP：\(String(cString: strerror(errno)))"); return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = audioPort.bigEndian
        address.sin_addr = in_addr(s_addr: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            report(errno == EADDRINUSE ? "端口 49831 被占用" : "监听失败：\(String(cString: strerror(errno)))")
            return
        }
        report("等待 Windows 音频 · UDP 49831")
        var player: LANAudioPlayer?
        var streamRate: UInt32?
        var streamFrames: Int?
        var lastPacket = Date.distantPast
        var isPlaying = false
        var raw = [UInt8](repeating: 0, count: 16_384)
        while !session.isStopped {
            let count = raw.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    if isPlaying && Date().timeIntervalSince(lastPacket) > 1 {
                        player = nil
                        streamRate = nil
                        streamFrames = nil
                        isPlaying = false
                        report("等待 Windows 音频 · UDP 49831")
                    }
                    continue
                }
                report("接收失败：\(String(cString: strerror(errno)))")
                break
            }
            guard !session.isStopped, let packet = LANAudioPacket(Array(raw[..<count])) else { continue }
            lastPacket = Date()
            if player == nil {
                do {
                    player = try LANAudioPlayer(rate: packet.sampleRate, frames: packet.frames)
                    streamRate = packet.sampleRate
                    streamFrames = packet.frames
                } catch {
                    report("音频输出启动失败：\(error)")
                    break
                }
            }
            guard packet.sampleRate == streamRate, packet.frames == streamFrames else { continue }
            do {
                try player?.receive(packet)
                if !isPlaying {
                    isPlaying = true
                    report("正在传音 · \(packet.sampleRate) Hz")
                }
            } catch {
                report("音频播放失败：\(error)")
                break
            }
        }
    }
}
