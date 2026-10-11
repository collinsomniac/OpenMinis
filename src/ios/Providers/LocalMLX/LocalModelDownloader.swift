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
}

/// A download the app is responsible for finishing, persisted so it can be completed after a relaunch.
struct ModelDownloadJob: Codable, Sendable, Identifiable {
    var id: String              // repo id
    var revision: String        // full commit sha, so a moved branch cannot change what we fetch
    var files: [ModelDownloadFile]
    var started: Date

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var doneBytes: Int64 { files.filter(\.done).reduce(0) { $0 + $1.size } }
    var fraction: Double { totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : 0 }
}

@MainActor
final class LocalModelDownloader: NSObject, ObservableObject {
    static let shared = LocalModelDownloader()

    @Published private(set) var jobs: [ModelDownloadJob] = []
    @Published var lastError: String?

    private var session: URLSession!
    private var completionHandler: (() -> Void)?
    private static let sessionIdentifier = "nabla.onDeviceModelDownload"
    private static let jobsKey = "nabla.modelDownloadJobs"

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
    }

    // MARK: Persistence

    private static func loadJobs() -> [ModelDownloadJob] {
        guard let d = UserDefaults.standard.data(forKey: jobsKey),
              let list = try? JSONDecoder().decode([ModelDownloadJob].self, from: d) else { return [] }
        return list
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(d, forKey: Self.jobsKey) }
    }

    private func stageDir(for repo: String) -> URL {
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
        let dir = stageDir(for: job.id)
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
        try? FileManager.default.removeItem(at: stageDir(for: repo))
    }

    func dismiss(repo: String) {
        jobs.removeAll { $0.id == repo }
        persist()
    }

    // MARK: Delegate callbacks (called on a background queue)

    fileprivate func completed(task: URLSessionDownloadTask, at location: URL?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "\u{1F}")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let repo = String(parts[0])

        // Move the file synchronously — the system deletes `location` the moment this returns.
        if let location,
           let jobIndex = jobs.firstIndex(where: { $0.id == repo }),
           index < jobs[jobIndex].files.count {
            let name = jobs[jobIndex].files[index].name
            let dest = stageDir(for: repo).appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) }
            catch { try? FileManager.default.copyItem(at: location, to: dest) }
            Task { @MainActor in
                self.jobs[jobIndex].files[index].done = true
                self.persist()
                if self.jobs[jobIndex].files.allSatisfy(\.done) { self.finalize(repo: repo) }
            }
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

    fileprivate func progressed(task: URLSessionDownloadTask, written: Int64, expected: Int64) {
        // Per-file progress is not needed at UI precision; the job's completed-files fraction is
        // enough to answer "is it moving", and this keeps main-actor traffic at zero during transfers.
    }

    fileprivate func eventsFinished() {
        let handler = completionHandler
        completionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    // MARK: Finalize

    /// All files are down: move the staged directory into the library and clean up.
    private func finalize(repo: String) {
        let staging = stageDir(for: repo)
        let dest = LocalModelStore.dir(for: repo)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            // Directory move keeps this O(1) inside the container; a cross-volume library (the user
            // chose iCloud Drive or an external folder) needs the copy fallback.
            do { try fm.moveItem(at: staging, to: dest) }
            catch {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.moveItem(at: f, to: dest.appendingPathComponent(f.lastPathComponent))
                }
                try? fm.removeItem(at: staging)
            }
            let marker = try JSONSerialization.data(
                withJSONObject: ["id": repo, "source": "huggingface",
                                 "downloaded": ISO8601DateFormatter().string(from: Date())],
                options: [.prettyPrinted])
            try? marker.write(to: dest.appendingPathComponent(".looplab.json"))
            LocalModelStore.invalidateInstalledCache()
            jobs.removeAll { $0.id == repo }
            persist()
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
        Task { @MainActor in self.completed(task: downloadTask, at: location) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.failed(task: task, error: error) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.progressed(task: downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.eventsFinished() }
    }
}
