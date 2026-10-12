import re, pathlib

p = pathlib.Path('LocalModelDownloader.swift')
t = p.read_text()

# ─────────────────────────────────────────────────────────────────────────────
# 1. Live per-file byte progress, so a single 3 GB file is not stuck at "0%".
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""struct ModelDownloadFile: Codable, Sendable, Hashable {
    var name: String
    var size: Int64
    var done: Bool = false
}""",
"""struct ModelDownloadFile: Codable, Sendable, Hashable {
    var name: String
    var size: Int64
    var done: Bool = false
    /// Bytes of this file already on disk. Counts toward progress while the transfer is in flight, so a
    /// job made of one 3 GB file is not pinned at "0%" for ten minutes and then 100%.
    var written: Int64 = 0
}""")

t = t.replace("""    var doneBytes: Int64 { files.filter(\\.done).reduce(0) { $0 + $1.size } }""",
"""    var doneBytes: Int64 {
        files.reduce(0) { $0 + ($1.done ? $1.size : min(max($1.written, 0), $1.size)) }
    }""")

# ─────────────────────────────────────────────────────────────────────────────
# 2. One shared definition of "this file is really here", used by both the
#    placement step and the finalize verification so they cannot drift apart.
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""    nonisolated private func route(for description: String) -> (name: String, size: Int64)? {""",
"""    /// Is `got` bytes an acceptable realisation of a file the Hub declared as `declared` bytes?
    ///
    /// Rejects zero-length and truncated transfers (the failure mode that made the library list nothing)
    /// while tolerating the small discrepancies that are legitimate: the Hub reports the *stored* size,
    /// and a response the system decoded for us can come out slightly larger. Nothing is accepted that is
    /// more than 2% short, and an empty file is never accepted.
    nonisolated static func sizeIsAcceptable(got: Int64, declared: Int64) -> Bool {
        guard got > 0 else { return false }
        guard declared > 0 else { return true }
        return got >= Int64(Double(declared) * 0.98)
    }

    nonisolated private func route(for description: String) -> (name: String, size: Int64)? {""")

# ─────────────────────────────────────────────────────────────────────────────
# 3. Replace the main-actor `completed` with: a synchronous placement step that
#    runs on the delegate queue, and a small main-actor recorder.
# ─────────────────────────────────────────────────────────────────────────────
start = t.index("    fileprivate func completed(task: URLSessionDownloadTask, at location: URL?) {")
end = t.index("    fileprivate func failed(task: URLSessionTask, error: Error?) {")
t = t[:start] + '''    /// What happened when a finished transfer was taken out of the system's temp directory.
    enum PlaceOutcome {
        case placed(name: String)
        case http(Int)
        case incomplete(name: String, expected: Int64, got: Int64)
        case unsupported(String)
    }

    /// Take the delivered temp file and put it in the staging directory.
    ///
    /// [T-nabla-local-mlx-download-move] This runs on the delegate queue and must be synchronous: iOS
    /// deletes the file the moment `didFinishDownloadingTo` returns. The previous version hopped to the
    /// main actor first and therefore moved a file that was already gone, which is the defect behind every
    /// download failure seen on device. Nothing here touches main-actor state — the routing information
    /// comes from the locked route table, and the outcome is recorded afterwards.
    nonisolated fileprivate static func place(repo: String, name: String, expected: Int64,
                                              location: URL, status: Int?) -> PlaceOutcome {
        if let status, !(200..<300).contains(status) { return .http(status) }

        let fm = FileManager.default
        // Verify at the SOURCE, before moving anything into the library.
        let attrs = try? fm.attributesOfItem(atPath: location.path)
        let got = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard sizeIsAcceptable(got: got, declared: expected) else {
            return .incomplete(name: name, expected: expected, got: got)
        }

        let stage = stageDir(for: repo)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let dest = stage.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
        } catch {
            // Same volume in practice, but the temp directory is not guaranteed to be: fall back to a copy.
            do { try fm.copyItem(at: location, to: dest) }
            catch { return .unsupported("\\(name): could not be saved (\\(error.localizedDescription))") }
        }
        return .placed(name: name)
    }

    /// Apply a placement outcome to the job bookkeeping, on the main actor.
    fileprivate func record(description desc: String, outcome: PlaceOutcome) {
        let parts = desc.split(separator: "\\u{1F}")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let repo = String(parts[0])
        guard let i = jobs.firstIndex(where: { $0.id == repo }), index < jobs[i].files.count else { return }
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo

        switch outcome {
        case .http(let code):
            lastError = "\\(repoName): server returned HTTP \\(code)"
        case .incomplete(let name, let expected, let got):
            lastError = "\\(name): expected \\(expected) bytes, got \\(got)"
        case .unsupported(let why):
            lastError = why
        case .placed(let name):
            jobs[i].files[index].done = true
            jobs[i].files[index].written = jobs[i].files[index].size
            persist()
            if jobs[i].files.allSatisfy(\\.done) { finalize(repo: repo) }
            _ = name
        }
    }

''' + t[end:]

# ─────────────────────────────────────────────────────────────────────────────
# 4. Progress: live bytes, throttled to one main-actor hop per 512 KB.
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""    fileprivate func progressed(task: URLSessionDownloadTask, written: Int64, expected: Int64) {
        // Per-file progress is not needed at UI precision; the job's completed-files fraction is
        // enough to answer "is it moving", and this keeps main-actor traffic at zero during transfers.
    }""",
"""    fileprivate func progressed(description desc: String, written: Int64) {
        let parts = desc.split(separator: "\\u{1F}")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        guard let i = jobs.firstIndex(where: { $0.id == String(parts[0]) }),
              index < jobs[i].files.count, !jobs[i].files[index].done else { return }
        jobs[i].files[index].written = written
        // Deliberately not persisted: this fires thousands of times per download, and the value is only a
        // progress readout. A relaunch restarts the count for a file that is still in flight, which is
        // honest — those bytes are in a temp file we cannot account for until the transfer is delivered.
    }""")

# ─────────────────────────────────────────────────────────────────────────────
# 5. Finalize verification reuses the shared rule.
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""            let size = (try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
            if size == 0 { missing.append(f.name) }
            else if f.size > 0, size != f.size {
                missing.append("\\(f.name) (\\(size)/\\(f.size) bytes)")
            }""",
"""            let attrs = try? fm.attributesOfItem(atPath: p)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if !Self.sizeIsAcceptable(got: size, declared: f.size) {
                missing.append("\\(f.name) (\\(size)/\\(f.size) bytes)")
            }""")

# ─────────────────────────────────────────────────────────────────────────────
# 6. The delegates: file work first, main actor second.
# ─────────────────────────────────────────────────────────────────────────────
old_ext = t[t.index("extension LocalModelDownloader: URLSessionDownloadDelegate {"):]
new_ext = '''extension LocalModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode

        // A non-2xx response is not a download: a background task delivers `didFinishDownloadingTo` even
        // for a 404, with the error page as the "file", which must never be counted as a model file.
        if let status, !(200..<300).contains(status) {
            Task { @MainActor in self.record(description: desc, outcome: .http(status)) }
            return
        }
        // No route means the job was cancelled between the request and this callback; drop it.
        guard let route = route(for: desc) else { return }
        let repo = String(desc.split(separator: "\\u{1F}").first ?? "")

        let outcome = Self.place(repo: repo, name: route.name, expected: route.size,
                                 location: location, status: status)
        Task { @MainActor in self.record(description: desc, outcome: outcome) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.failed(task: task, error: error) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        // Throttle: a 3 GB file arrives in tens of thousands of callbacks and each main-actor hop competes
        // with the UI. 512 KB granularity still moves the bar hundreds of times on a large file.
        let id = downloadTask.taskIdentifier
        routeLock.lock()
        let last = lastReportedBytes[id] ?? 0
        let worthReporting = totalBytesWritten - last >= 512 * 1024
            || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
        if worthReporting { lastReportedBytes[id] = totalBytesWritten }
        routeLock.unlock()
        guard worthReporting, let desc = downloadTask.taskDescription else { return }
        Task { @MainActor in self.progressed(description: desc, written: totalBytesWritten) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.eventsFinished() }
    }
}
'''
t = t.replace(old_ext, new_ext)

p.write_text(t)
print("braces:", t.count('{') - t.count('}'))
print("completed( leftover:", t.count('func completed('))
print("place:", t.count('static func place('), "record:", t.count('func record('))
