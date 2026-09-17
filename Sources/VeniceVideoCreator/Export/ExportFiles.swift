import CryptoKit
import Darwin
import Foundation

enum ExportFiles {
    static func lutSources(in timeline: Timeline) -> [String: URL] {
        var urls: [String: URL] = [:]
        for clip in timeline.tracks.flatMap(\.clips) {
            for effect in clip.effects ?? [] where effect.enabled && effect.type == "color.lut" {
                if let path = effect.params["path"]?.string, !path.isEmpty {
                    urls["lut:\(path)"] = URL(fileURLWithPath: path)
                }
            }
        }
        return urls
    }

    static func bindingCopiedLUTs(in timeline: Timeline, copies: [String: URL]) throws -> Timeline {
        var result = timeline
        for track in result.tracks.indices {
            for clip in result.tracks[track].clips.indices {
                guard var effects = result.tracks[track].clips[clip].effects else { continue }
                for index in effects.indices where effects[index].enabled && effects[index].type == "color.lut" {
                    guard let path = effects[index].params["path"]?.string, !path.isEmpty else { continue }
                    guard let copy = copies["lut:\(path)"],
                          LUTLoader.parse(try String(contentsOf: copy, encoding: .utf8)) != nil else {
                        throw ExportError.verification("Replace the missing or invalid LUT before exporting.")
                    }
                    effects[index].params["path"]?.string = copy.path
                }
                result.tracks[track].clips[clip].effects = effects
            }
        }
        return result
    }

    static func digests(_ urls: [String: URL]) async throws -> [String: String] {
        let task = Task.detached(priority: .utility) {
            try urls.mapValues { try digest($0) }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func copySources(_ urls: [String: URL], digests: [String: String], into directory: URL) async throws -> [String: URL] {
        let task = Task.detached(priority: .utility) {
            var copies: [String: URL] = [:]
            for (index, pair) in urls.sorted(by: { $0.key < $1.key }).enumerated() {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent("source-\(index)").appendingPathExtension(pair.value.pathExtension)
                try FileManager.default.copyItem(at: pair.value, to: destination)
                guard try digest(destination) == digests[pair.key] else {
                    throw ExportError.verification("Source changed after readiness: \(pair.value.lastPathComponent). Check readiness again.")
                }
                copies[pair.key] = destination
            }
            return copies
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func publish(_ source: URL, to destination: URL, overwrite: Bool) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                overwrite ? rename(sourcePath!, destinationPath!) : renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let a = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let b = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let deviceA = a[.systemNumber] as? NSNumber, let deviceB = b[.systemNumber] as? NSNumber,
              let inodeA = a[.systemFileNumber] as? NSNumber, let inodeB = b[.systemFileNumber] as? NSNumber else { return false }
        return deviceA == deviceB && inodeA == inodeB
    }
}
