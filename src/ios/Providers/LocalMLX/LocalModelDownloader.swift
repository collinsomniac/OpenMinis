import Foundation
import UIKit
import UserNotifications

// Downloading a multi-gigabyte model must survive the user leaving the app.
//
// [T-nabla-local-mlx-background-download] The first implementation downloaded through the Hugging Face
// hub client, which runs on a *default* URLSession — in-process, and therefore suspended the moment the
// app is backgrounded. Switching apps mid-download produced
// `NSURLErrorDomain -1005 "The network connection was lost"` (the screenshot showed a raw NSError dump
// for a transfer that had simply been paused by iOS). Staying in the app made it work, which is not a
// reasonable thing to ask of anyone downloading 5 GB.
//
// A **background** URLSession is the mechanism built for exactly this: the transfer is handed to
// `nsurlsessiond`, continues while the app is suspended (and across app termination), and relaunches the
// app to deliver completion. That requires doing the download ourselves rather than through the hub
// client — which is also a simplification, because we already know the file list and its sizes from the
// repository inspection, and writing files directly into the library removes any need for hub-cache
// symlink walking.

/// One file in an in-flight download.
struct ModelDownloadFile: Codable, Sendable, Hashable {
    var name: String
    var size: Int64
    var done: Bool = false
    /// Bytes of this file already on disk. Counts toward progress while the transfer is in flight, so a
    /// job made of one 3 GB file is not pinned at "0%" for ten minutes and then 100%.
    var written: Int64 = 0
}

/// A download the app is responsible for finishing, persisted so it can be completed after a relaunch.
struct ModelDownloadJob: Codable, Sendable, Identifiable {
    var id: String              // repo id
    var revision: String        // full commit sha, so a moved branch cannot change what we fetch
    var files: [ModelDownloadFile]
    var started: Date

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var doneBytes: Int64 {
        files.reduce(0) { $0 + ($1.done ? $1.size : min(max($1.written, 0), $1.size)) }
    }
    var fraction: Double { totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0 }
}

@MainActor
final class LocalModelDownloader: NSObject, ObservableObject {
    static let shared = LocalModelDownloader()

    @Published private(set) var jobs: [ModelDownloadJob] = []
    @Published var lastError: String?

    private var session: URLSession!
    private var completionHandler: (() -> Void)?
    /// Repos with a finalize in flight — one finalize per job, ever.
    private var finalizing: Set<String> = []
    private static let sessionIdentifier = "nabla.onDeviceModelDownload"
    private static let jobsKey = "nabla.modelDownloadJobs"

    // [T-nabla-local-mlx-download-move] `didFinishDownloadingTo` hands over a temp file that iOS deletes
    // the instant the delegate method returns, so the move has to happen *inside* it, synchronously. But
    // the delegate runs on a background queue while the job bookkeeping lives on the main actor, and the
    // original code hopped (`Task { @MainActor in … }`) before touching the file — so every move ran
    // against a file that no longer existed. Nothing ever landed in the staging directory. That single
    // defect caused both observed download failures: build 29 marked all twelve files done regardless and
    // finalised an empty folder (marker in the library, 3 GB orphaned in /tmp), and the size check added
    // in build 31 then reported it correctly as `vocab.json: expected 6722759 bytes, got 0`.
    //
    // This is the bridge: a plain routing table (task description → file name + expected size), written
    // on the main actor whenever the jobs change, read here under a lock. `nonisolated(unsafe)` is
    // accurate — the lock, not the actor, is what protects it.
    private nonisolated(unsafe) let routeLock = NSLock()
    private nonisolated(unsafe) var routeTable: [String: (name: String, size: Int64)] = [:]
    private nonisolated(unsafe) var lastReportedBytes: [Int: Int64] = [:]

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The user asked for this download; do not let the system defer it to save power.
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        jobs = Self.loadJobs()
        lastError = nil
        syncRoutes()
        resumeIfNeeded()
    }

    // MARK: Persistence

    private static func loadJobs() -> [ModelDownloadJob] {
        guard let d = UserDefaults.standard.data(forKey: jobsKey),
              let list = try? JSONDecoder().decode([ModelDownloadJob].self, from: d) else { return [] }
        return list
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(d, forKey: Self.jobsKey) }
        syncRoutes()
    }

    /// Publish the routing table for the delegate queue. Cheap (a dozen entries) and called from `persist`,
    /// which every mutation already goes through.
    private func syncRoutes() {
        var table: [String: (name: String, size: Int64)] = [:]
        for job in jobs {
            for (i, f) in job.files.enumerated() {
                table["\(job.id)\u{1F}\(i)"] = (f.name, f.size)
            }
        }
        routeLock.lock(); routeTable = table; routeLock.unlock()
    }

    /// Is `got` bytes an acceptable realisation of a file the Hub declared as `declared` bytes?
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

    nonisolated private func route(for description: String) -> (name: String, size: Int64)? {
        routeLock.lock(); defer { routeLock.unlock() }
        return routeTable[description]
    }

    nonisolated private static func stageDir(for repo: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModelDownloadStaging", isDirectory: true)
        return base.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    /// Reassociate any tasks nsurlsessiond still holds with their jobs (after a relaunch).
    func reattach() {
        guard !jobs.isEmpty else { return }
        session.getAllTasks { _ in }
    }

    func adopt(completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
        reattach()
    }

    // MARK: Start / cancel

    func start(repo: String, revision: String, files: [LocalModelFile]) {
        guard !jobs.contains(where: { $0.id == repo }) else { return }
        let job = ModelDownloadJob(id: repo, revision: revision,
                                   files: files.map { ModelDownloadFile(name: $0.name, size: $0.size) },
                                   started: Date())
        jobs.append(job)
        persist()
        lastError = nil
        enqueue(job)
    }

    private func enqueue(_ job: ModelDownloadJob) {
        syncRoutes()
        let dir = Self.stageDir(for: job.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, file) in job.files.enumerated() where !file.done {
            guard let url = Self.resolveURL(repo: job.id, revision: job.revision, file: file.name) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3600
            req.setValue("Nabla/1.0 (iOS; on-device inference)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: req)
            // taskDescription is the only channel that survives the relaunch, so it carries the routing.
            task.taskDescription = "\(job.id)\u{1F}\(index)"
            task.resume()
        }
    }

    /// The Hub's resolve endpoint, redirected to its CDN. Background sessions follow redirects.
    private static func resolveURL(repo: String, revision: String, file: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/\(repo)/resolve/\(revision)/\(file)"
        return comps.url
    }

    func cancel(repo: String) {
        session.getAllTasks { tasks in
            for t in tasks where (t.taskDescription ?? "").hasPrefix(repo + "\u{1F}") { t.cancel() }
        }
        jobs.removeAll { $0.id == repo }
        persist()
        try? FileManager.default.removeItem(at: Self.stageDir(for: repo))
    }

    func dismiss(repo: String) {
        jobs.removeAll { $0.id == repo }
        persist()
    }

    // MARK: Delegate callbacks (called on a background queue)

    /// What happened when a finished transfer was taken out of the system's temp directory.
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
            catch { return .unsupported("\(name): could not be saved (\(error.localizedDescription))") }
        }
        return .placed(name: name)
    }

    /// Apply a placement outcome to the job bookkeeping, on the main actor.
    fileprivate func record(description desc: String, outcome: PlaceOutcome) {
        let parts = desc.split(separator: "\u{1F}")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let repo = String(parts[0])
        guard let i = jobs.firstIndex(where: { $0.id == repo }), index < jobs[i].files.count else { return }
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo

        switch outcome {
        case .http(let code):
            lastError = "\(repoName): server returned HTTP \(code)"
        case .incomplete(let name, let expected, let got):
            lastError = "\(name): expected \(expected) bytes, got \(got)"
        case .unsupported(let why):
            lastError = why
        case .placed(let name):
            jobs[i].files[index].done = true
            jobs[i].files[index].written = jobs[i].files[index].size
            persist()
            if jobs[i].files.allSatisfy(\.done) { finalize(repo: repo) }
            _ = name
        }
    }

    fileprivate func failed(task: URLSessionTask, error: Error?) {
        guard let desc = task.taskDescription else { return }
        let repo = String(desc.split(separator: "\u{1F}").first ?? "")
        guard !repo.isEmpty, jobs.contains(where: { $0.id == repo }) else { return }
        let ns = error as NSError?
        // A cancelled task is the user's doing; anything else is worth surfacing in the UI.
        if ns?.code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.lastError = "\(repo): \(ns?.localizedDescription ?? "download failed")"
        }
    }

    fileprivate func progressed(description desc: String, written: Int64) {
        let parts = desc.split(separator: "\u{1F}")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        guard let i = jobs.firstIndex(where: { $0.id == String(parts[0]) }),
              index < jobs[i].files.count, !jobs[i].files[index].done else { return }
        jobs[i].files[index].written = written
        // Deliberately not persisted: this fires thousands of times per download, and the value is only a
        // progress readout. A relaunch restarts the count for a file that is still in flight, which is
        // honest — those bytes are in a temp file we cannot account for until the transfer is delivered.
    }

    fileprivate func eventsFinished() {
        let handler = completionHandler
        completionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    // MARK: Finalize

    /// All files are down: verify, then move the staged directory into the library.
    ///
    /// [T-nabla-local-mlx-finalize-verify] This used to move first and write the marker unconditionally.
    /// The failure it produced (seen on device): the marker landed in the library while the bytes were
    /// still in flight, leaving a model folder containing nothing but `.looplab.json` — the library then
    /// listed no model, and the transferred gigabytes sat in a URLSession temp file. Finalising is now
    /// gated on the *content* being present and complete, a repo can only finalise once per job, and a
    /// folder is never deleted before its replacement has been verified.
    private func finalize(repo: String) {
        guard let job = jobs.first(where: { $0.id == repo }) else { return }
        guard !finalizing.contains(repo) else { return }
        finalizing.insert(repo)
        defer { finalizing.remove(repo) }

        let staging = Self.stageDir(for: repo)
        let fm = FileManager.default

        // 1. Every expected file present at its expected size.
        var missing: [String] = []
        for f in job.files {
            let p = staging.appendingPathComponent(f.name).path
            let attrs = try? fm.attributesOfItem(atPath: p)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if !Self.sizeIsAcceptable(got: size, declared: f.size) {
                missing.append("\(f.name) (\(size)/\(f.size) bytes)")
            }
        }
        // 2. The two things that actually make a model loadable.
        let hasConfig = fm.fileExists(atPath: staging.appendingPathComponent("config.json").path)
        let hasWeights = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? [])
            .contains { $0.hasSuffix(".safetensors") }

        guard missing.isEmpty, hasConfig, hasWeights else {
            // Keep the job: the missing files can still arrive (or be retried). The UI keeps showing
            // progress, which is the truth.
            lastError = "\(repo.split(separator: "/").last.map(String.init) ?? repo): download incomplete — "
                + (hasWeights ? "" : "no weights yet; ") + (hasConfig ? "" : "no config.json yet; ")
                + "\(missing.count) file(s) not finished"
            return
        }

        let dest = LocalModelStore.dir(for: repo)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Replace the destination only once the source is known good. Move the old one aside rather
            // than deleting first, so a failed swap cannot destroy an existing working model.
            let aside = dest.appendingPathExtension("replaced")
            try? fm.removeItem(at: aside)
            if fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: dest, to: aside) }
            do {
                try fm.moveItem(at: staging, to: dest)
            } catch {
                // Cross-volume library (the user chose iCloud Drive or an external folder): copy, then
                // verify the copy before trusting it.
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                }
            }
            guard fm.fileExists(atPath: dest.appendingPathComponent("config.json").path),
                  LocalModelStore.isModelDir(dest) else {
                // Put the previous contents back; do not leave a broken folder in the library.
                if fm.fileExists(atPath: aside.path) {
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: aside, to: dest)
                }
                lastError = "\(repo): finished downloading but could not be placed in the library"
                return
            }
            try? fm.removeItem(at: aside)
            try? fm.removeItem(at: staging)

            let marker = try JSONSerialization.data(
                withJSONObject: ["id": repo, "source": "huggingface",
                                 "downloaded": ISO8601DateFormatter().string(from: Date()),
                                 "bytes": job.totalBytes],
                options: [.prettyPrinted])
            try? marker.write(to: dest.appendingPathComponent(".looplab.json"))
            LocalModelStore.invalidateInstalledCache()
            jobs.removeAll { $0.id == repo }
            persist()
            lastError = nil
            // The model list of every on-device provider follows the folder.
            Task { @MainActor in
                let store = ProviderConfigStore.shared
                for instance in store.instances where instance.providerType == .localMLX {
                    await store.refreshModels(for: instance)
                }
                Self.notifyDownloaded(repo)
            }
        } catch {
            lastError = "\(repo): downloaded, but could not be moved into the library — \(error.localizedDescription)"
        }
    }

    /// Re-queue the missing files of a persisted job.
    ///
    /// [T-nabla-local-mlx-download-resume] A background session that iOS has torn down does not redeliver
    /// its tasks, and anything already transferred sits in a `CFNetworkDownload_*.tmp` file that is no
    /// longer referenced. Without this, a job killed mid-flight stays at "2 of 12 files" forever.
    func resumeIfNeeded() {
        for job in jobs where session != nil {
            session.getAllTasks { tasks in
                let live = Set(tasks.compactMap { t -> String? in
                    guard let d = t.taskDescription else { return nil }
                    return String(d.split(separator: "\u{1F}").first ?? "")
                })
                guard !live.contains(job.id) else { return }
                Task { @MainActor in
                    let done = self.jobs.first(where: { $0.id == job.id })?.files.filter(\.done).count ?? 0
                    self.lastError = "\(job.id.split(separator: "/").last.map(String.init) ?? job.id): "
                        + "resuming (\(done)/\(job.files.count) files already here)"
                    self.enqueue(job)
                }
            }
        }
    }

    /// A download that finishes while the app is away should say so when the user looks at the phone.
    private static func notifyDownloaded(_ repo: String) {
        let centre = UNUserNotificationCenter.current()
        centre.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Model downloaded"
            content.body = repo.split(separator: "/").last.map(String.init) ?? repo
            let req = UNNotificationRequest(identifier: "nabla.model.\(repo)",
                                            content: content, trigger: nil)
            centre.add(req)
        }
    }
}

extension LocalModelDownloader: URLSessionDownloadDelegate {
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
        let repo = String(desc.split(separator: "\u{1F}").first ?? "")

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
