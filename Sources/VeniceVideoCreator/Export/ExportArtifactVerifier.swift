import AVFoundation

enum ExportArtifactVerifier {
    static func verify(_ url: URL, timeline: Timeline, size: CGSize, format: ExportFormat? = nil) async throws -> VideoExportJob.Artifact {
        let task = Task.detached(priority: .utility) { try await decode(url, timeline: timeline, size: size, format: format) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func decode(_ url: URL, timeline: Timeline, size: CGSize, format: ExportFormat?) async throws -> VideoExportJob.Artifact {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let expected = Double(timeline.totalFrames) / Double(timeline.fps)
        let tolerance = max(2 / Double(timeline.fps), 0.05)
        guard duration.isFinite, abs(duration - expected) <= tolerance else {
            throw ExportError.verification("Export duration does not match the checked timeline.")
        }
        let video = try await asset.loadTracks(withMediaType: .video)
        guard video.count == 1, let track = video.first else { throw ExportError.verification("Export must contain one decodable video track.") }
        if let format {
            let codec: FourCharCode = switch format {
            case .h264: kCMVideoCodecType_H264
            case .h265, .hevcHDR: kCMVideoCodecType_HEVC
            case .prores: kCMVideoCodecType_AppleProRes422
            case .xml, .fcpxml: throw ExportError.invalidFormat
            }
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == codec }) else {
                throw ExportError.verification("Encoded video codec does not match the requested format.")
            }
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let actual = naturalSize.applying(transform)
        guard Int(abs(actual.width)) == Int(size.width), Int(abs(actual.height)) == Int(size.height) else {
            throw ExportError.verification("Encoded dimensions do not match the requested export size.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.verification("Cannot decode the exported video.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.verification("Cannot read the exported video.") }
        defer { reader.cancelReading() }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard CMSampleBufferGetImageBuffer(sample) != nil, time.isFinite,
                  abs(time - Double(frames) / Double(timeline.fps)) <= 0.5 / Double(timeline.fps) else {
                throw ExportError.verification("Export contains an undecodable frame or a frame-timing gap.")
            }
            frames += 1
        }
        guard reader.status == .completed, frames == timeline.totalFrames else {
            throw reader.error ?? ExportError.verification("Decoded video does not cover every timeline frame.")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let expectsAudio = timeline.tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
        guard !expectsAudio || !audio.isEmpty else { throw ExportError.verification("Export is missing the timeline's audio track.") }
        var audioSamples = 0
        var audioRanges: [(start: Double, end: Double)] = []
        for track in audio {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ExportError.verification("Cannot decode exported audio.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ExportError.verification("Cannot read exported audio.") }
            defer { reader.cancelReading() }
            var samples = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferGetDataBuffer(sample) != nil else { throw ExportError.verification("Export contains undecodable audio.") }
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let duration = CMSampleBufferGetDuration(sample).seconds
                guard start.isFinite, duration.isFinite, duration > 0 else { throw ExportError.verification("Export contains invalid audio timing.") }
                audioRanges.append((start, start + duration))
                samples += CMSampleBufferGetNumSamples(sample)
            }
            guard reader.status == .completed, samples > 0 else { throw reader.error ?? ExportError.verification("Exported audio is empty or truncated.") }
            audioSamples += samples
        }
        audioRanges.sort { $0.start < $1.start }
        for clip in timeline.tracks.filter({ $0.type == .audio }).flatMap(\.clips) {
            var cursor = Double(clip.startFrame) / Double(timeline.fps)
            let end = Double(clip.endFrame) / Double(timeline.fps)
            for range in audioRanges {
                if range.end < cursor { continue }
                if range.start > cursor + tolerance { break }
                cursor = max(cursor, range.end)
                if cursor + tolerance >= end { break }
            }
            guard cursor + tolerance >= end else { throw ExportError.verification("Decoded audio does not cover the timeline's audio clips.") }
        }
        let hash = try await ExportFiles.digests(["output": url])
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, let digest = hash["output"] else { throw ExportError.verification("Export is empty.") }
        return .init(width: Int(size.width), height: Int(size.height), fps: timeline.fps, durationSeconds: duration,
                     videoFrames: frames, audioTracks: audio.count, decodedAudioSamples: audioSamples, bytes: bytes, sha256: digest)
    }
}
