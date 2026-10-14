# Embedding Integration: App Intents, arbitrary-file embedding, and a model-agnostic embedder

**Scope.** An iOS 27 app (`/var/minis/workspace/openminis`, Swift/SwiftUI, sideloaded, ~300k LOC) runs LLMs
on-device through MLX Swift (`swift-transformers`, `mlx-swift`, `mlx-swift-lm` — all present as SPM
dependencies in `src/ios/Minis.xcodeproj/project.pbxproj` lines 3980–4006). We are adding **embedding
models** as a second kind of local model, and the report answers four hard requirements: **(a)** many
embedding models, text **and multimodal**, with zero per-model code; **(b)** usable from Apple Shortcuts;
**(c)** able to embed arbitrary on-device files; **(d)** coexisting with a 3–4B chat model in phone memory.

Everything below is written against the real code in this repo. File paths are relative to
`/var/minis/workspace/openminis/src/ios/` unless stated otherwise. Claims I could not verify against
primary documentation or source carry **[unverified]**.

---

## 1. App Intents as the mechanism (iOS 26/27 API surface)

### 1.1 The pieces

| Piece | Role | Doc |
|---|---|---|
| `AppIntent` | the action; `perform()` returns an `IntentResult` | https://developer.apple.com/documentation/appintents/appintent |
| `AppShortcutsProvider` | pre-registers shortcuts + Siri phrases with zero user setup | https://developer.apple.com/documentation/appintents/appshortcutsprovider |
| `AppEntity` + `EntityQuery` | typed values Shortcuts can pass around and pick | https://developer.apple.com/documentation/appintents/appentity · https://developer.apple.com/documentation/appintents/entityquery |
| `IntentFile` / `FileEntity` | file-typed parameter / file-backed entity | https://developer.apple.com/documentation/appintents/intentfile · https://developer.apple.com/documentation/appintents/fileentity |
| `LongRunningIntent` | escapes the ~30 s background limit | https://developer.apple.com/documentation/appintents/longrunningintent |
| `IntentModes` (`supportedModes`) | background vs foreground execution | https://developer.apple.com/documentation/appintents/intentmodes |
| `IndexedEntity` | puts entities in the Spotlight/App-Entity index so Siri can find them | https://developer.apple.com/documentation/appintents/indexedentity |

### 1.2 Background execution and time limits — the precise current rules

* The **baseline background budget is 30 s**. Apple's own words in `LongRunningIntent`: *"When a task runs
  in the background, the system traditionally gives it up to 30 seconds to finish its task… file
  operations, data synchronization, machine learning inference, and data processing tasks can take
  longer."* (`https://developer.apple.com/documentation/appintents/longrunningintent`).
* **`LongRunningIntent`** is the documented escape hatch. Conform and put the work inside
  `performBackgroundTask(options:operation:)` (options: `LongRunningTaskOptions`). The contract
  is explicit: *"the system requires you to report progress regularly… If you don't update this property
  regularly, the system can cancel the background runtime extension and end your task prematurely."*
  The progress property is `ProgressReportingIntent.progress`
  (`https://developer.apple.com/documentation/appintents/progressreportingintent`). **This is the single
  most important API for us**: embedding a 40-page PDF, transcribing a 20-minute audio file, or
  re-indexing a folder all exceed 30 s and all are running "ML inference / data processing".
* **`openAppWhenRun` is deprecated in iOS 26.** The replacement is
  `static var supportedModes: IntentModes` with `.background`, `.foreground`, and
  `.foreground(.dynamic)` (`IntentModes.ForegroundMode`,
  https://developer.apple.com/documentation/appintents/intentmodes). `ForegroundContinuableIntent` is
  **deprecated** in favour of `.foreground(.dynamic)` — Apple's doc says literally: *"This protocol is
  deprecated, please include `.foreground(.dynamic)` in the `supportedModes` of your app intent
  instead."* (`https://developer.apple.com/documentation/appintents/foregroundcontinuableintent`).
  Our existing intents still use the deprecated `openAppWhenRun` — see §2.
* `allowedExecutionTargets` / `IntentExecutionTargets` (`ExecutionTargets`) further restrict *where* an
  intent may run (e.g. iPhone-only, never on a paired HomePod / remote Apple Intelligence surface). Docs
  list them under "Specifying the intent's allowed target" on the `AppIntent` page. An intent that must
  touch the phone's vector index should declare the phone as its only target.
* Nothing in the App Intents framework gives an intent a *guaranteed* long window. `LongRunningIntent`
  is cooperative: the system may still end it. **Design consequence: every embedding job must be
  resumable** (chunk-level progress persisted), so an interrupted shortcut leaves the index consistent
  rather than half-written.

### 1.3 What a Shortcut passes in, and what comes back

**Inbound file → `IntentFile`.** The docs describe two construction paths and five members:

* `init(data:filename:type:)`, `init(fileURL:filename:type:)`
* properties `filename`, `fileURL` ("URL to the file on disk, if any. If the file isn't stored on disk,
  access the contents using the `data` property"), `type` (UTI), `data` ("The contents of the file. If
  the file was created with a URL, accessing this property will **memory map** the file contents"), and
  `removedOnCompletion` (default `false`: the system deletes the file when the Shortcut finishes unless
  the producer set it false).
* Methods: `data(contentType:)`, `file(contentType:destinationDirectory:)`,
  `withFile(contentType:allowOpenInPlace:fileHandler:)`, plus `availableContentTypes` and
  `IntentFileError`.
  (`https://developer.apple.com/documentation/appintents/intentfile` and
  …/intentfile/data · …/intentfile/fileurl)

**So it is both, and the difference matters.** When a Shortcut hands our intent an `IntentFile` produced
by an upstream action (Photos picker, "Get File", "Convert File"), the system **materialises the bytes
into a container the app can reach** and exposes a `fileURL`; `data` is available and memory-mapped. When
the file came from the app itself, `data` may be the only option. Practical rules:

```swift
// A 2 MB PDF: mmap is free, but converting to Data is not. Prefer text extraction off the URL.
if let url = file.fileURL {           // fast path: read/extract in place, no copy
    try await indexer.ingest(fileURL: url, filename: file.filename, uti: file.type)
} else {                              // no on-disk representation: we must take the bytes
    let data = try await file.data(contentType: .data)
    try await indexer.ingest(data: data, filename: file.filename, uti: file.type)
}
```

* Never `file.data` a video or a 200 MB PDF just to hash it — stream from `fileURL`, or use
  `withFile(contentType:allowOpenInPlace:)` which the docs describe as *"Requests an IntentFile
  representation as a file url"* with a handler, and `allowOpenInPlace` lets the system avoid a copy.
* `file(contentType:destinationDirectory:)` is the overload to use when you need a *lifetime you control*
  (e.g. you want to hand the URL to `AVAssetReader` on a background queue after `perform()` returns).
* Check `file.type` first: the UTI is what tells you whether to send it to PDFKit, Vision, or ASR.
  `IntentFile.availableContentTypes` tells you what conversions the system can perform for you.
* **Never rely on the URL surviving past `perform()`** — the container is torn down with the intent.
  Copy anything you intend to keep into the app's own storage and record a bookmark (§3.7).

**`FileEntity` is the other half.** `IntentFile` is a *parameter* (something passed to us). `FileEntity`
is an *entity* (something the system can resolve to a file the app already owns) —
`https://developer.apple.com/documentation/appintents/fileentity`. It declares
`static var supportedContentTypes: [UTType]` (default `public.item`), and its value type is
`FileEntityIdentifier`. Wrapping our indexed documents as `FileEntity` is what makes "search my notes" →
"open that document" work inside Siri and inside App-Entity search, and it is what makes a returned
search hit *actionable* rather than a dead string. `IndexedEntity`
(`https://developer.apple.com/documentation/appintents/indexedentity`) is how the same rows get into the
system index in the first place.

**Result types.** `perform()` returns `some IntentResult` composed from these protocols:

* `ReturnsValue<T>` — the value becomes the Shortcuts action's output and can be chained into the next
  action. `T` must be `IntentValueConvertible`: `String`, `Int`, `Double`, `Bool`, `Date`, `URL`,
  `Measurement`, `[T]`, `AppEntity`, `IntentFile`, and the `AppEnum`/`AppEntity` families.
* `ProvidesDialog` — supplies the string Siri speaks.
* `ShowsSnippetView` (iOS 17+) — a SwiftUI view rendered inside the Shortcuts result.
* `IntentItemCollection<T>` / `ResultsCollectionConvertible` — **iOS 26's multi-result shape.** This repo
  already uses it: `ModelSelectionEntityQuery` declares
  `typealias Result = IntentItemCollection<ModelSelectionEntity>` (`Agent/Intents/ModelSelectionEntity.swift`).
  Use the same for search results so the picker renders rows rather than one comment-like blob.

Entities returned from an `EntityQuery` become the picker's options, and any parameter marked
`inputConnectionBehavior: .connectToPreviousIntentResult` accepts the previous action's output — that is
exactly how `SendPromptIntent.files` already chains (`Agent/Intents/SendPromptIntent.swift`).

### 1.4 `EntityQuery` requirements (and the one that bites)

Implement `entities(for identifiers:)`. Implement `suggestedEntities()` to fill the picker without a
keystroke. If you want *free-text* lookup ("find my notes about the boat"), implement `EntityStringQuery`
instead — this repo already does, in `ModelSelectionEntityQuery`.

**The trap:** Apple's doc on `AppEntity` states *"The system requires the `AppEntity` identifier to be
unique and persistent because the system may save it in a shortcut."*
(`https://developer.apple.com/documentation/appintents/appentity`). A Shortcut parameter that stored our
entity can be re-run months later. Therefore **search-hit entity IDs must be derived from the document's
identity (path or bookmark hash + chunk sequence), never from a SQLite `rowid`** — rowids change the
moment the file is re-indexed, and a saved shortcut would silently point at the wrong chunk. See §4.

### 1.5 Sideloaded vs App Store — what actually differs

**Nothing in the App Intents framework is gated on distribution channel.** `AppShortcutsProvider`,
`AppIntent`, `AppEntity`, `LongRunningIntent`, background execution, and the 30 s budget are identical for
a sideloaded binary and a store binary. The App-Intents metadata extractor runs at build time in both
cases. Concretely:

1. **Entitlements.** A sideloaded build signed with a paid-developer or enterprise profile can carry
   entitlements a store review would scrutinise. The relevant one is
   `com.apple.developer.kernel.increased-memory-limit`
   (`https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit`),
   which raises the usable-Jetsam ceiling from ~3.25 GB to ~6 GB [magnitudes from this repo's own comment
   in `Providers/LocalMLX/LocalModelHost.swift` line ~22]. **This repo already treats it as a build-time
   fact**: `Views/Settings/LocalInferenceSettingsView.swift` reads
   `ents["com.apple.developer.kernel.n"]` (the repo's redacted spelling of the entitlement) and reports
   whether the signed build carries it. This is the difference that matters most for us: a multimodal
   embedder resident next to a 3–4B chat model is an entitlement question before it is an algorithm
   question.
2. **App Review guidelines.** A store app must survive review; 2.5.2 (no downloaded executable code) does
   **not** apply to model weights — safetensors/GGUF are data, not code — but reviewers can and do ask
   about multi-GB downloads and background processing. A sideloaded app simply never faces that
   conversation. [unverified whether a store app would actually be rejected for this; no evidence found
   of a rejection on this basis.]
3. **Private/unstable API risk.** Same for both; sideloading does not exempt you from App Intents'
   runtime contracts (the AppShortcut-null-init crash documented at length in
   `Agent/Intents/MinisShortcutsProvider.swift` is a *platform* bug that hit store and sideloaded builds
   alike).
4. **Nothing about Shortcuts is special-cased.** Shortcuts actions appear for any installed app that
   declares a provider, sideloaded or not.
5. **Background modes.** `UIBackgroundModes` and `BGTaskSchedulerPermittedIdentifiers` are entitlements
   from the profile in both cases (this app declares `audio, fetch, location, remote-notification` in
   `Info.plist` lines 241–247, plus `io.github.collinsomniac.nabla.liveactivity-refresh`). So the *same*
   background machinery that the chat agent already leans on is available to the embedding path.

**Bottom line for §1:** design as if the platform rules are exactly the documented ones, and treat the
memory entitlement as the only genuinely channel-dependent lever.

---

## 2. Driving this app specifically

### 2.1 What is already wired

All of it lives in `Agent/Intents/` (14 files, 2,611 lines) plus one provider:

| File | What it is |
|---|---|
| `Agent/Intents/MinisShortcutsProvider.swift` | `struct MinisShortcutsProvider: AppShortcutsProvider`. 124 lines. Registers **8** `AppShortcut`s: Ask, Quick Task, Send Prompt, Session Status, List Sessions, Follow Up, Open Session (+ a removed Open WebApp). Phrases use the `"\(.applicationName)"` token; localized phrase tables are `src/ios/<locale>.lproj/AppShortcuts.strings` (legacy `.strings`, not `.xcstrings`, because the deployment target is iOS 16). Contains a long, load-bearing comment about an iOS 16 crash from a weak-linked iOS 17 `AppShortcut.init`. **Adding a new shortcut = adding one `AppShortcut(...)` entry here + a key in every `AppShortcuts.strings`.** |
| `Agent/Intents/SendPromptIntent.swift` | 539 lines. The full pattern: `static var openAppWhenRun = false`, `@Parameter prompt: String` with `requestValueDialog` **and** `inputConnectionBehavior: .connectToPreviousIntentResult`, `@Parameter files: [IntentFile]?` with `supportedTypeIdentifiers: ["public.image", "public.movie", "public.data"]`, `@Parameter session: SessionEntity?`, `@Parameter model: ModelSelectionEntity?`, `@Parameter waitForResult: Bool`, `@Parameter sendCompletionNotification: Bool`. `@MainActor func perform() async throws -> some IntentResult & ReturnsValue<SendPromptResult> & ProvidesDialog`. |
| `Agent/Intents/AskMinisIntent.swift` | 94 lines. Same pipeline, `openAppWhenRun = true` — the Siri path that foregrounds. |
| `Agent/Intents/QuickTaskIntent.swift` | 294 lines. `enum QuickTask: AppEnum` + prompt templates + `files: [IntentFile]?`. This is the app's existing "run a canned local task" intent. |
| `Agent/Intents/SendPromptResult.swift` | The result entity: `AppEntity`, `@Property sessionId/modelName/status/isNewSession/prompt/responseText`, and an intentionally empty `SendPromptResultQuery` ("result entities are ephemeral, not persisted"). **Copy this shape for the embed result.** |
| `Agent/Intents/SessionEntity.swift` + `SessionEntityQuery` | Entity backed by `ChatStore.shared.getSession(id)`; `suggestedEntities()` = `listSessions().filter{!$0.isChild}.prefix(100)`. **Copy this shape for the collection entity.** |
| `Agent/Intents/ModelSelectionEntity.swift` | 211 lines. `AppEntity` + `EntityQuery, EntityStringQuery` over model groups/entries, `IntentItemCollection` result type, and a filter for disabled providers. |
| `Agent/Intents/UserMessageEntity.swift` | Wraps a chat message. |
| `Agent/Intents/GetSessionStatusIntent.swift` | The polling pattern: the long job runs in the app, the Shortcut gets a handle and polls. |
| `Agent/Intents/ShortcutRunTracker.swift` | 454 lines. `markPending(intent:sessionId:waitForResult:eagerKeepAliveArmed:eagerKeepAliveSkippedReason:) -> String`, `logPerformEntry(...)`, plus completion bookkeeping. **Any new long-running intent must register here** or the app's own diagnostics and Live Activity will not know a job is alive. |
| `Agent/Background/BackgroundKeepAliveManager.swift` | `armEagerlyForShortcut(sessionId:caller:)`, `BackgroundKeepAliveManager.shared.setup()`. Every intent calls it *before its first `await`*. |
| `Shared/AudioTogglePlaybackIntent.swift` | The pattern for an intent with no `@MainActor` UI at all. |

Also relevant, not in `Intents/`: `ShareExtension/ShareViewController.swift` +
`ShareExtension/ShareViewModel.swift` + `ShareExtension/Info.plist` (§3.7), and
`Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift`.

### 2.2 (a) "Embed File" — the concrete shape

```swift
// Agent/Intents/EmbedFileIntent.swift
import AppIntents
import UniformTypeIdentifiers

/// Long-running: an embed job over a 40-page PDF or a folder will exceed the 30 s background budget.
struct EmbedFileIntent: AppIntent, LongRunningIntent, ProgressReportingIntent {
    static var title: LocalizedStringResource = "Embed File"
    static var description = IntentDescription(
        "Adds files to an on-device search collection. Runs entirely on this iPhone.")

    // iOS 26 API. `.background` = never foregrounds the app. Do NOT keep using
    // `openAppWhenRun = false` — deprecated in iOS 26 (see §1.2).
    static var supportedModes: IntentModes = .background
    // Phone-only: the vector index and the model weights are here, not on a paired device.
    static var allowedExecutionTargets: IntentExecutionTargets = .mainDevice   // [unverified exact member]

    @Parameter(title: "File",
               supportedTypeIdentifiers: ["public.item"],           // accept anything; we dispatch on UTType
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Collection") var collection: CollectionEntity?   // nil ⇒ default collection
    @Parameter(title: "Embedder")   var embedder: EmbeddingModelEntity? // nil ⇒ the app default

    static var parameterSummary: some ParameterSummary {
        Summary("Embed \(\.$files) into \(\.$collection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<EmbedResult> & ProvidesDialog {
        BackgroundKeepAliveManager.shared.setup()

        let trackerId = ShortcutRunTracker.markPending(
            intent: "EmbedFileIntent", sessionId: "embed:\(UUID().uuidString)",
            waitForResult: false, eagerKeepAliveArmed: false, eagerKeepAliveSkippedReason: nil)

        let batch = try await EmbeddingCoordinator.shared.begin(
            files: files.map { EmbeddingInput(filename: $0.filename, uti: $0.type,
                                              url: $0.fileURL,
                                              inlineData: $0.fileURL == nil ? try await $0.data(contentType: .data) : nil) },
            collectionId: collection?.id,
            embedderKey: embedder?.key,
            progress: { done, total in
                self.progress.totalUnitCount = Int64(total)      // ProgressReportingIntent
                self.progress.completedUnitCount = Int64(done)
                ShortcutRunTracker.noteProgress(trackerId, done: done, total: total)
            })

        ShortcutRunTracker.complete(trackerId)
        return .result(
            value: EmbedResult(collectionId: batch.collectionId, modelKey: batch.modelKey,
                               chunks: batch.chunkCount, dim: batch.dim,
                               skipped: batch.skippedFilenames),
            dialog: "Embedded \(batch.chunkCount) passages from \(batch.fileCount) files.")
    }
}
```

`EmbedResult` is a straight copy of `SendPromptResult`'s shape — an `AppEntity` with `@Property`
fields and a query that returns `[]`. Shortcuts will show `chunks`, `dim`, `modelKey` as separate
output variables, which is what makes the action chainable into a "Log" or "Show Result" step.

Three non-obvious points, all of them forced by the platform:

1. **`progress` must actually advance.** Apple: *"If you don't update this property regularly, the system
   can cancel the background runtime extension."* Update per *chunk*, not per file, and accept that a
   500-chunk PDF needs ≥500 progress ticks.
2. **A `[IntentFile]` of 200 photos is legal and will kill you.** Cap it (`files.prefix(n)`) and stream:
   `EmbeddingCoordinator` must consume one file at a time, never `map { $0.data }` over the array.
3. **The job must be idempotent and resumable.** Shortcuts can re-run an action; the widget can retry.
   Keying by content hash (§4.4) makes a re-run a no-op and an interrupted run a partial success.

### 2.3 (b) "Semantic Search" — an intent that queries the index and returns `AppEntity`s

```swift
// Agent/Intents/SemanticSearchIntent.swift
struct SemanticSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search My Files"
    static var description = IntentDescription("Semantic search over files embedded on this iPhone.")
    static var supportedModes: IntentModes = .background

    @Parameter(title: "Query") var query: String
    @Parameter(title: "Collection") var collection: CollectionEntity?
    @Parameter(title: "Max Results", default: 10) var limit: Int
    @Parameter(title: "Minimum Score", default: 0.0) var minScore: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$collection) for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SearchHitEntity]> & ProvidesDialog {
        // Time budget: the intent gets ~30 s in the background. Spend at most ~8 s on retrieval and
        // degrade to what we have, rather than throwing and returning nothing.
        let engine = VectorIndex.shared
        let hits = try await engine.search(
            text: query, collectionId: collection?.id, limit: limit,
            minScore: minScore,
            deadline: .now + .seconds(8),
            embedderKey: try await EmbeddingCoordinator.shared.pinnedKey(for: collection?.id))
        return .result(value: hits.map(SearchHitEntity.init(from:)),
                       dialog: hits.isEmpty ? "Nothing matched." : "Found \(hits.count) matches.")
    }
}

/// The hit is an entity, not a string, so Shortcuts can show it, pass it on, and open it.
struct SearchHitEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Search Result")
    static var defaultQuery = SearchHitEntityQuery()

    var id: String                 // STABLE: "\(docKey)#\(chunkSeq)" — never a rowid (see §1.4)
    var text: String               // the passage
    var score: Double
    var documentName: String
    var documentURL: URL           // for "Open File" chaining / FileEntity bridging

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(documentName)",
            subtitle: "\(String(format: "%.3f", score)) · \(text.prefix(60))")
    }
}

struct SearchHitEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SearchHitEntity] {
        await VectorIndex.shared.hits(forStableIds: identifiers)   // one SELECT ... WHERE stable_id IN (...)
    }
    func suggestedEntities() async throws -> [SearchHitEntity] {
        await VectorIndex.shared.recentHits(limit: 20)             // fills the picker without a keystroke
    }
}
```

Why this is the right shape and not a `String` output: `AppEntity` results render as rows with a title
and subtitle, can be passed to another action, and are what the system stores when the user picks one in
a `@Parameter` picker. Returning `[String]` would throw away the document identity and make
"search → open the file" impossible.

### 2.4 (c) A Shortcuts action that runs a *local* model

This already exists in a form worth copying. `LocalModelHost.shared` is the app's single resident-model
gate; `stream(modelId:system:history:maxTokens:temperature:thinking:)` is the entry point used by
`Providers/LocalMLX/LocalMLXProvider.swift`. An intent can reach it directly:

```swift
struct RunLocalModelIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Local Model"
    static var supportedModes: IntentModes = .background
    @Parameter(title: "Prompt") var prompt: String
    @Parameter(title: "Model") var model: ModelSelectionEntity?   // reuse the existing entity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let id = model?.resolvedLocalModelId ?? LocalModelHost.shared.residentModelId
        guard let id else { throw EmbeddingError.noLocalModel }
        var out = ""
        try await LocalModelHost.shared.stream(
            modelId: id, system: nil, history: [.init(role: "user", text: prompt)],
            maxTokens: 512, temperature: 0.6, thinking: false) { ev in
            if case .text(let t) = ev { out += t }
        }
        return .result(value: out, dialog: String(out.prefix(200)))
    }
}
```

Two of this app's existing patterns apply verbatim: (i) `SendPromptIntent`/`QuickTaskIntent` return
*immediately* with a session handle and let a `GetSessionStatusIntent` poll, because a full agent turn is
minutes, not seconds; (ii) `waitForResult: true` is the opt-in path when the user wants to chain. An
embedding job is closer to a single model call than to an agent turn, so it should use
`LongRunningIntent` + `progress` rather than the handle-and-poll dance — but it should still call
`ShortcutRunTracker.markPending` so the home-screen spinner and Live Activity stay honest.

### 2.5 Registration

Add to `MinisShortcutsProvider.appShortcuts` (keeping the iOS 16-safe overload discipline documented at
the top of that file):

```swift
AppShortcut(intent: EmbedFileIntent(),
            phrases: ["Embed a file with \(.applicationName)", "Add a file to \(.applicationName)"],
            shortTitle: "Embed File", systemImageName: "square.and.arrow.down")
AppShortcut(intent: SemanticSearchIntent(),
            phrases: ["Search \(.applicationName)", "Find in \(.applicationName)"],
            shortTitle: "Search Files", systemImageName: "magnifyingglass")
```

and add the same keys to every `src/ios/<locale>.lproj/AppShortcuts.strings` with
`${applicationName}` as the placeholder. Note the file's warning that a type-level `@available(iOS 17,*)`
must **not** be added here, and that mixing an `IntentModes`-based `supportedModes` (iOS 26) into this
provider is fine — that is on the intent, not the shortcut entry.

---

## 3. Embedding arbitrary files on iOS

### 3.1 The dispatch table

Everything hinges on `IntentFile.type` (a UTI). One dispatcher, one protocol:

```swift
protocol FileExtractor {
    static var supportedTypes: [UTType] { get }
    /// Cheap, cancellable, memory-bounded. Returns text spans + optional native modality payloads.
    func extract(url: URL, progress: (Double) -> Void) async throws -> ExtractedDocument
}
struct ExtractedDocument {
    var text: String?                    // for a text embedder
    var chunks: [TextChunk]              // pre-split, byte-offset tagged, for incremental re-embed
    var images: [CGImage]                // for an image embedder (keyframes / PDF pages)
    var audioSegments: [AudioSegment]    // for an ASR pass or an audio tower
    var quality: ExtractionQuality       // .exact | .lossy(reason:) | .ocr(reason:)
}
```

| Type (UTI) | Extraction | Feed to | Gotchas |
|---|---|---|---|
| `public.plain-text`, `.md`, `.csv`, `.json`, `.yaml` | `String(contentsOf:url, encoding:.utf8)`, fall back to detection then `String(decoding:as:UTF8.self)` | text embedder | Unknown encodings (GB18030, Shift-JIS) silently produce mojibake with `String(decoding:)`. Try UTF-8 → UTF-16 BOM → `NSString.stringEncoding(for:...)` probe. |
| `public.source-code`, `.swift`, `.py`, … | read as text | text embedder | Chunk on **board-level boundaries** (blank line / top-level decl) not fixed windows; a 4-line function split in half embeds badly. Comment-strip optional. |
| `com.adobe.pdf` | `PDFDocument(url:)` → for each `PDFPage`: `page.string` | text embedder | **This is the big one** — see §3.2. |
| `public.image` | `VNRecognizeTextRequest` → text; and/or `VNGenerateImageFeaturePrintRequest` → vector | text embedder, or image embedder | Two *incompatible* vector spaces; see §3.3. |
| `public.audio` / `.mp3` / `.m4a` | `AVAudioFile`/`AVAssetReader` → on-device ASR → transcript | text embedder (via ASR), or audio tower | ASR quality dominates; never feed raw PCM to a text embedder. See §3.4. |
| `public.movie` | `AVAssetImageGenerator` keyframes → image path; audio track → ASR path | image + text embedders | Multi-vector per file. See §3.5. |
| `org.openxmlformats.*` (docx/xlsx/pptx), `.epub`, `.rtf` | unzip + XML, or `NSAttributedString` | text embedder | No public extraction API for OOXML on iOS. See §3.6. |
| anything else | thumbnail + filename + metadata; declare `.lossy` | text embedder (metadata only) | Never silently produce an empty embedding. |

### 3.2 PDF — extraction quality and the OCR fallback

`PDFDocument` / `PDFPage.string` (`https://developer.apple.com/documentation/pdfkit/pdfdocument`,
`https://developer.apple.com/documentation/pdfkit/pdfpage/string`) walks the content stream and returns
the text operators' operands. It is **fast** (a 200-page PDF in well under a second) and **exact** when
the PDF has real text. It fails, silently, in four common cases:

1. **Scanned pages** — the page is one big image; `page.string` is `""` or `"\n"`.
2. **Subsetted/obfuscated fonts** (common in LaTeX and some print pipelines) — `.string` returns
   plausible-looking garbage because the ToUnicode CMap is missing. Detection: a high ratio of
   `U+FFFD`/control characters, or a wordlist hit-rate near zero.
3. **Encrypted PDFs** — `PDFDocument.isEncrypted`, and `isLocked` until unlocked with a password.
   `PDFDocument.allowsCopying` gates whether extraction is permitted at all; honour it.
4. **Column/table layout** — `.string` concatenates in stream order, which interleaves two columns.

**Fallback rule (concrete, cheap to implement):**

```swift
let text = page.string ?? ""
let suspicious = text.count < 40
    || Double(text.unicodeScalars.filter { $0.properties.isDefaultIgnorableCodePoint }.count) > 0.15 * Double(max(1,text.count))
if suspicious {
    let image = page.thumbnail(of: CGSize(width: page.bounds(for: .mediaBox).width * 2,
                                          height: page.bounds(for: .mediaBox).height * 2),
                              for: .mediaBox)          // or PDFPage.draw(with:to:) for full control
    let ocr = try await OCR.recognize(cgImage: image)   // VNRecognizeTextRequest, .accurate
    used = ocr
    quality = .ocr(reason: "page had no extractable text")
}
```

* Render at **2×** the media-box size: below ~150 DPI `VNRecognizeTextRequest` degrades sharply on body
  text; above ~2× you pay for nothing.
* Use `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, and set
  `recognitionLanguages` from the document's dominant script (auto-detecting per page is wasteful; sample
  page 1 and stick with it). `.fast` is 3–5× quicker and unusable for small text.
* **Cost:** accurate OCR is ~0.3–1.5 s per page on a modern iPhone [unverified on this exact device].
  A 300-page scan is 2–8 minutes → this is *why* the intent must be `LongRunningIntent` and resumable, and
  why OCR should be opt-in per collection ("Text only" vs "Text + scans").
* Per-page results should be stored so a re-run skips pages already OCR'd (`emb_chunks` keyed per page).
* Image-only PDFs also deserve an **image** path if the user picked a multimodal embedder: render pages
  and feed them to the vision tower instead of OCR — better for diagrams and screenshots, worse for
  exact-text recall.

### 3.3 Images — two incompatible spaces, choose deliberately

**Space A: text.** `VNRecognizeTextRequest` on the `CGImage`, then the text embedder.
Good for screenshots, receipts, whiteboards. Loses everything visual.

**Space B: Apple's own image feature print.** `VNGenerateImageFeaturePrintRequest` →
`VNFeaturePrintObservation` (`https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest`,
`https://developer.apple.com/documentation/vision/vnfeatureprintobservation`). Free, on-device, no
download, no model file. You compare two observations with
`observation.computeDistance(&distance, to: other)`. The vector is exposed as
`observation.data` (Float array) with `observation.elementCount` telling you the length — the *dimension
is not a documented constant* and can change with the request revision; read `elementCount` at runtime and
never hardcode. Numbers I have seen quoted: 2048 floats for the default revision [unverified].
**Critical property: this is a different embedding space from every text model.** You can do image↔image
similarity and nothing else. Do not store these vectors in the same table-and-model-slot as text vectors
without a distinct `model_key` (§4.2 does exactly that).

**Space C: a real multimodal embedder (CLIP/SigLIP).** Image and text land in one space, so
"find photos of a boat" becomes a text→image query. MLX conversions exist and are small:
`mlx-community/clip-vit-base-patch32`, `mlx-community/clip-vit-base-patch16` (512/768-d),
`mlx-community/siglip2-so400m-patch16-384`, `mlx-community/siglip2-base-patch16-224-8bit`
(verified via the HF search API). This is the path that satisfies the "multimodal is a priority"
requirement. Note that `jkrukowski/swift-embeddings` supports CLIP **text-encoding only** ("only text
encoding is supported for now") — it is not the multimodal answer.

Recommendation: **Space C for the image collection, Space A as a text-augmentation of the same image**
(store OCR text as a *separate* text vector for the same document). Space B only as a zero-download
fallback when no multimodal model is installed.

### 3.4 Audio — ASR first, audio tower later

There is no Apple audio-embedding API (SoundAnalysis is classification, not embeddings). So:

1. **ASR → text embedder** (the pragmatic path). `SFSpeechRecognizer`
   (`https://developer.apple.com/documentation/speech/sfspeechrecognizer`): set
   `requiresOnDeviceRecognition = true` and check `supportsOnDeviceRecognition` for the locale — the
   on-device path is the only acceptable one here (no network, no 1-minute server cap). Feed a file with
   `SFSpeechURLRecognitionRequest` for short clips, or `SFSpeechAudioBufferRecognitionRequest` fed from
   `AVAudioFile`/`AVAssetReader` in chunks for long ones, because a single request over an hour of audio
   will be cut off and you cannot resume it. Needs `SFSpeechRecognizer.requestAuthorization` and the
   `NSSpeechRecognitionUsageDescription` key.
2. **`SpeechAnalyzer` (iOS 26)** — `https://developer.apple.com/documentation/speech/speechanalyzer`,
   with `SpeechTranscriber` and the `AssetInventory` API for downloading on-device models, is the modern
   replacement for long-form transcription and handles asset management and multi-minute inputs far
   better. Use it for anything over ~60 s [unverified: exact per-request limits of the new API].
3. **Audio tower** (a true audio-text embedding space, e.g. CLAP: `laion/clap-htsat-unfused`,
   512-d audio-text space, verified to exist on HF with `preprocessor_config.json` +
   `pytorch_model.bin`). **There is no MLX conversion of CLAP on the Hub as of this research** (HF search
   for "mlx clap" returns nothing), so using it means converting the PyTorch weights ourselves —
   a real project, explicitly *not* phase-1 work. It buys: music/sound-effect search ("find the clip with
   the dog barking") that ASR cannot do.
4. **Video audio** is the same path; extract with `AVAssetReader` + an `AVAssetReaderTrackOutput` on the
   audio track, or `AVAssetExportSession` to m4a first.

### 3.5 Video — be honest about what a phone can do

A phone cannot embed video end-to-end. The realistic pipeline, in order of value per CPU-second:

1. **Keyframes.** `AVAssetImageGenerator`
   (`https://developer.apple.com/documentation/avfoundation/avassetimagegenerator`) with
   `requestedTimeToleranceBefore/After = .zero`, `appliesPreferredTrackTransform = true`, sampling at
   ≥1 s intervals capped at N frames (start with 24), plus a scene-change pass
   (`AVAssetImageGenerator` has no scene detection; compute per-frame histogram deltas on downscaled
   copies, or just trust a fixed sampling and accept near-duplicates). Downscale to the tower's input
   (`preprocessor_config.json` says the size; SigLIP-so400m is 384², CLIP-B/32 is 224²).
2. **Audio track** → §3.4. For most talking-head video, ASR is 90 % of the retrievable meaning.
3. **Storage:** either (a) one mean-pooled vector per video (cheap, loses moments) or (b) a **multi-vector
   row per keyframe**, which turns retrieval into late-interaction MaxSim — exactly what `MLXEmbedders`
   already implements for ColBERT (`Libraries/MLXEmbedders/Models/LFM2Bidirectional.swift`,
   `mlx-community/LFM2.5-ColBERT-350M-*`, "per-token 128-d multi-vectors (MaxSim late interaction)").
   Option (b) is the correct one and the framework already has the machinery.
4. **Cost:** decoding + one ViT forward per keyframe is ~0.1–0.4 s/frame [unverified]; a 2-minute video
   at 1 fps is ~15–30 s — inside `LongRunningIntent`, outside a quick action.
5. Store the frame timestamps: it is what makes "jump to 1:42" possible, and it costs 8 bytes.

### 3.6 Office docs, code, and everything else

* **OOXML (`.docx/.xlsx/.pptx`)** are ZIP containers of XML. There is **no public iOS API** to extract their
  text (QuickLook's `QLThumbnailGenerator` gives an image; `NSAttributedString(url:options:documentAttributes:)`
  supports `.rtf`/`.html`/`.doc`-format on iOS only partially [unverified]). Do it ourselves with a small
  ZIP reader: `word/document.xml` (paragraph text, `<w:t>` runs, `<w:p>` paragraph breaks),
  `xl/sharedStrings.xml` + `xl/worksheets/*.xml` (rows), `ppt/slides/slideN.xml` (+ `notesSlides`).
  Strip tags, insert newlines at paragraph/row boundaries, and **do not** keep the file's own XML in the
  index. This is ~200 lines and covers the overwhelming majority of real documents.
* **`.rtf`** — `NSAttributedString` → `.string`, works on iOS and preserves text exactly.
* **`.epub`** — a ZIP of XHTML; reuse the ZIP reader, parse with a tag-stripper, keep chapter boundaries as
  chunk boundaries (a chapter is the natural retrieval unit).
* **HTML** — strip `<script>/<style>` before stripping tags; keep `<h1..h6>` as chunk boundaries.
* **Legacy `.doc`/`.xls`/`.ppt`** — no public path; declare `.lossy(reason:"legacy format")` and index the
  filename + the QuickLook thumbnail only.
* **Images with no text** (pure photos) with no multimodal model installed: index only the filename,
  capture date, and EXIF. That is still useful for "the photo I took in Lisbon", and it costs nothing.

### 3.7 The iOS file-access model (how files get *to* us at all)

Four entry points, and the embedding feature needs all four:

| Entry | Mechanism | Note for embedding |
|---|---|---|
| **Files.app / document picker** | `UIDocumentPickerViewController` or SwiftUI `.fileImporter`; the URL is security-scoped | Must `startAccessingSecurityScopedResource()` around every read, and persist a **bookmark** for later re-indexing. |
| **Security-scoped bookmarks** | `try url.bookmarkData()` + `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` | This app already does this well and we should copy it verbatim: `Providers/LocalMLX/LocalModelStore.swift` persists the user's model folder as a bookmark in `UserDefaults` under `nabla.onDeviceModelsFolder`, re-claims access on every lookup, and handles the stale case. Note: iOS has **no** `.withSecurityScope` bookmark option (that is macOS); on iOS the plain bookmark is what re-grants access. |
| **External mounts** | `/var/minis/mounts/<name>/` — see `Views/Settings/MountedFoldersManager.swift` | The repo already resolves these and waits for them before agent work (see the long `[T-headless-mount-activation]` comment in `SendPromptIntent.swift` — a **headless intent never runs `.onAppear`**, so mounts were empty on a cold launch until they fixed it with a bounded 12 s concurrent resolve). **The embed intent must call the same mount-activation path or an "embed my Obsidian vault" shortcut will see an empty folder.** This is the single most likely bug in this feature. |
| **Share Sheet** | `ShareExtension/` | Second entry point, parallel to Shortcuts — see below. |

**Share Extension as the sibling entry point.** The repo already has one:
`ShareExtension/ShareViewController.swift` + `ShareViewModel.swift` + `Info.plist`
(`NSExtensionActivationRule` allows 10 images, 5 movies, 5 files, 1 web URL, text).
`ShareViewModel.processExtensionItems` writes into the App Group container through
`SharedContainerStore.savePendingShare` / `sharedFileDirectory`, with a **300 s staleness window and a
merge-not-overwrite policy** (a rapid second share appends to the unconsumed first one).
What to add: a second activation — "Embed in Minis" — that writes a `PendingShare` with
`intent: .embed` and lets the **main app** do the work. A share extension gets a much smaller memory
budget than the app and cannot reliably host a 300 MB vision tower; so the extension should be a
*queue writer*, and the app's launch/foreground `.task` (or a `BGProcessingTask`) drains it. This also
gives the feature a natural retry path: the queue is durable, so an interrupted embed resumes.

---

## 4. The vector index, and how a Shortcut queries it

### 4.1 Where it should live

`Agent/Chat/ChatStore.swift` (8,611 lines) is a hand-rolled SQLite store: `sqlite3_open` (line 665),
`PRAGMA journal_mode=WAL` (line 670), then one big `CREATE TABLE IF NOT EXISTS` block for ~20 tables
(`sessions` 676, `messages` 686, `compact_markers` 841, `sync_dirty_records` 884, `deleted_*_tombstones`,
`folders`, `remote_*`, `webapp_shortcuts`), with per-row decoding by column index throughout.
**There is no FTS table and no vector extension anywhere in it** (grep for `fts`, `vec0`, `vector` returns
nothing). So we are adding the first non-relational access pattern to this app.

**Recommendation: a sibling database file (`Embeddings.sqlite`), same `sqlite3` C API, same WAL
setting, opened by a new `VectorIndex` actor.** Reasons, in order:

1. `ChatStore`'s DDL block carries a documented footgun ("the add-column wipe trap", line ~768): columns
   that must exist are *not* in the `CREATE TABLE` and are added by later `ALTER`/backfill passes. Adding
   embedding tables into that same exec block means every future change to it risks the chat data.
2. The chat DB participates in **CloudKit sync** (tombstone tables, `sync_dirty_records`). Vectors are
   derived data: they are large (768 × 4 B = 3 KB per chunk), they must **not** sync, and they are
   reproducible from the source file. Keeping them in another file is the clean way to say "this is a
   cache".
3. A separate file can be deleted wholesale ("rebuild index"), excluded from backup
   (`URLResourceValues.isExcludedFromBackup = true`, exactly as `LocalModelStore.defaultRoot` already does
   for weights), and vacuumed independently.

The only real cost is that you cannot `JOIN` a vector row to a `message` row in one statement. Mitigate by
storing the *source identity* in both: `emb_blobs.source_kind` (`file` / `chat_message` / `note`) plus
`source_ref` (a path or a `sessionId:messageId` string). Then a two-step lookup (vector hit → fetch the
row from `ChatStore`) gives the same result with one extra query. That is worth it.

### 4.2 Schema

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- One row per embedding *configuration* actually used. This is the anti-drift table (see §5.6).
CREATE TABLE IF NOT EXISTS emb_models (
  model_key      TEXT PRIMARY KEY,   -- "\(repo)@\(revShort):\(specHash8)" — stable, human-checkable
  repo           TEXT NOT NULL,
  revision       TEXT,               -- branch/tag as requested
  revision_sha   TEXT,               -- FULL commit sha (LocalModelCatalog already returns it: LocalModelInspection.revision)
  architecture   TEXT,               -- config.json model_type
  dim            INTEGER NOT NULL,   -- the dim actually produced (post-truncation)
  native_dim     INTEGER,
  matryoshka     TEXT,               -- JSON array of valid truncations, e.g. "[768,512,256,128,64]"
  dtype          TEXT NOT NULL,      -- "fp16" | "bf16" | "q4" | "q8" — NOT interchangeable, see §5.6
  pooling        TEXT NOT NULL,      -- "mean"|"cls"|"last"|"max"|"first"|"none"|"colbert"
  normalize      INTEGER NOT NULL,   -- 0/1 — cosine on unnormalised vectors is a different number
  max_tokens     INTEGER,
  query_prefix   TEXT, document_prefix TEXT, instruction_template TEXT,
  prefix_policy  TEXT,               -- "required"|"forbidden"|"optional"
  modalities     TEXT,               -- JSON: ["text","image"] etc.
  spec           TEXT NOT NULL,      -- the full EmbeddingSpec JSON (the sidecar, verbatim)
  spec_hash      TEXT NOT NULL,      -- sha256(spec) — cheap drift check
  created_at     REAL NOT NULL
);

-- One row per *document version*. content_hash is the key that makes re-indexing incremental.
CREATE TABLE IF NOT EXISTS emb_blobs (
  id             INTEGER PRIMARY KEY,
  source_kind    TEXT NOT NULL,      -- 'file' | 'chat_message' | 'note'
  source_path    TEXT,               -- for files: the path as opened
  bookmark       BLOB,               -- security-scoped bookmark, so we can re-open later (§3.7)
  display_name   TEXT NOT NULL,
  uti            TEXT,
  bytes          INTEGER,
  mtime          REAL,
  content_hash   TEXT NOT NULL,      -- sha256 of the bytes (or of the normalised text for messages)
  extractor      TEXT,               -- which extractor ran: "pdf","pdf+ocr","asr","clip-image",...
  quality        TEXT,               -- 'exact' | 'ocr' | 'lossy'
  chunk_count    INTEGER NOT NULL DEFAULT 0,
  indexed_at     REAL NOT NULL,
  UNIQUE(source_kind, source_path, content_hash)
);
CREATE INDEX IF NOT EXISTS emb_blobs_path ON emb_blobs(source_path);

CREATE TABLE IF NOT EXISTS emb_chunks (
  id             INTEGER PRIMARY KEY,
  blob_id        INTEGER NOT NULL REFERENCES emb_blobs(id) ON DELETE CASCADE,
  seq            INTEGER NOT NULL,   -- 0-based position in the document
  stable_id      TEXT NOT NULL,      -- "\(blobKey)#\(seq)" — THE id we hand to Shortcuts (§1.4)
  text           TEXT,               -- the passage (may be an ASR/OCR transcript)
  start_byte     INTEGER, end_byte INTEGER,
  page           INTEGER,            -- for PDFs
  t_start        REAL, t_end REAL,   -- for audio/video, seconds
  token_count    INTEGER,
  chunk_hash     TEXT NOT NULL,      -- sha256(text) — re-embed only changed chunks
  UNIQUE(blob_id, seq)
);
CREATE INDEX IF NOT EXISTS emb_chunks_stable ON emb_chunks(stable_id);

-- One row per (chunk, model). A second model = a second row, not a replacement.
CREATE TABLE IF NOT EXISTS emb_vectors (
  chunk_id       INTEGER NOT NULL REFERENCES emb_chunks(id) ON DELETE CASCADE,
  model_key      TEXT NOT NULL REFERENCES emb_models(model_key),
  dim            INTEGER NOT NULL,
  vec            BLOB NOT NULL,      -- float32 little-endian, dim*4 bytes, tightly packed
  norm           REAL NOT NULL,      -- precomputed L2 norm: cosine == dot / (norm*queryNorm)
  PRIMARY KEY (chunk_id, model_key)
) WITHOUT ROWID;

-- Collections are what the Shortcut parameter picks (a CollectionEntity).
CREATE TABLE IF NOT EXISTS emb_collections (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, model_key TEXT NOT NULL,
  roots TEXT,                        -- JSON array of bookmarked roots
  rules  TEXT,                       -- JSON: extensions, max file size, OCR on/off, ASR on/off
  created_at REAL NOT NULL, updated_at REAL NOT NULL
);
```

Notes that matter:

* **`vec` as a `BLOB` of float32, not a `TEXT` of JSON, not a `vector` column.** SQLite has no vector
  type; a blob is 1:1 with the Metal buffer layout, so a query is one `memcpy` per row, and `dim` is
  `length(vec)/4`.
* **`WITHOUT ROWID`** on `emb_vectors` because the primary key is the natural access path and it saves a
  level of indirection per row.
* **`norm` precomputed.** Cosine similarity requires dividing by the query norm once and the row norm per
  row; storing the row norm turns each comparison into a dot product plus one multiply. On 100 k rows that
  is the difference between a tight loop and a transcendental-free one.
* Add `INTEGER PRIMARY KEY` rowids *and* a `stable_id`; only `stable_id` ever leaves the app.
* **Index size reality check:** 10,000 documents × 30 chunks × 768 dims × 4 B = **0.92 GB of vectors**.
  A 384-d model (MiniLM/bge-small) makes the same corpus 460 MB. That arithmetic — not model quality — is
  the argument for a small default text embedder and Matryoshka truncation to 256 d for the bulk index.

### 4.3 Querying from a Shortcut, with a time budget

`SemanticSearchIntent` gets ~30 s in the background and the user is staring at a Shortcut progress bar, so
budget explicitly:

```swift
actor VectorIndex {
    func search(text: String, collectionId: String?, limit: Int, minScore: Double,
                deadline: ContinuousClock.Instant, embedderKey: String) async throws -> [Hit] {
        // 1. Warm path only: if the resident embedder is not the one this collection was built with,
        //    DO NOT load a model inside the intent — return .embedderNotLoaded and let the app do it.
        guard let embedder = await EmbeddingCoordinator.shared.residentEmbedder(matching: embedderKey) else {
            throw EmbeddingError.embedderNotLoaded(modelKey: embedderKey)
        }
        // 2. Embed the query. Role matters: query_prefix != document_prefix (§5.4).
        let t0 = ContinuousClock.now
        let q = try await embedder.embed([text], role: .query)[0]
        let embedMs = t0.duration(to: .now)
        // 3. Brute force, with a hard deadline and cooperative cancellation.
        return try await bruteForce(query: q, collection: collectionId, limit: limit,
                                    minScore: minScore, deadline: deadline,
                                    reserve: embedMs > .milliseconds(500) ? .seconds(1) : .seconds(4))
    }
}
```

The brute-force loop is the whole implementation, and it is fine:

```swift
var scored: [(chunkId: Int64, score: Double)] = []
scored.reserveCapacity(4096)
var tick = 0
while let row = stmt.next() {
    tick += 1
    if tick & 0xFF == 0 {                                  // every 256 rows
        try Task.checkCancellation()                       // Shortcuts can cancel
        if ContinuousClock.now >= deadline { partial = true; break }
    }
    var dot: Float = 0
    row.vec.withUnsafeBytes { p in
        let v = p.bindMemory(to: Float.self)
        for i in 0..<dim { dot += v[i] * q[i] }
    }
    let score = Double(dot) / (row.norm * qNorm)
    if score >= minScore { scored.append((row.chunkId, score)) }
}
// Top-k with a bounded heap, not a full sort: O(n log k), k ≤ 50.
```

Where the time actually goes: a 768-d dot over 100 k vectors is 77 M multiply-adds ≈ well under 50 ms of
pure compute — but the **BLOB reads are the cost**, because each row lives in a different page. Expect a
cold query over 100 k rows to be dominated by page-cache misses: budget 200–800 ms warm, seconds cold
[unverified; measure on-device]. Hence:

* Cap `limit` (≤ 50) and `minScore` (default 0.25 for cosine).
* Keep a **query embedding LRU** so a repeated Shortcut run is instant.
* Optionally add a `vec0` virtual table. `sqlite-vec` (https://github.com/asg017/sqlite-vec) is a
  loadable **and** embeddable extension; on iOS you must **compile it into the binary** (`sqlite3_vec_init`
  linked directly) because `dlopen` of a `.dylib` inside an app container is blocked. There is a Swift
  wrapper, `https://github.com/jkrukowski/SQLiteVec`, by the `swift-embeddings` author. **Defer this**:
  brute force with a blob column is correct and fast enough at the sizes this app will see first, and
  swapping in `vec0` later changes only the query, not the schema contract (chunk_id + vec blob).
* If a query deadline is hit, **return the partial result and say so** in the dialog
  (`"Found 7 matches (partial scan)"`). A Shortcut that returns 7 real hits beats one that times out.

### 4.4 Keeping the index fresh

Three levels, cheapest first:

1. **Gate (O(1) per file).** A directory scan comparing `(mtime, size)` against `emb_blobs.mtime/bytes`.
   Unchanged → skip without reading a byte. This is what makes a re-run over a 5,000-file vault cheap.
   Use the same enumeration pattern the repo already uses in
   `LocalModelStore.weightBytes(in:)` (`FileManager.enumerator(at:includingPropertiesForKeys:)`).
2. **Hash (O(bytes)).** Only for files whose gate tripped: `sha256` streamed off the file. Store it. If the
   hash matches an existing row → nothing to do (touch `indexed_at`). If it matches a *different* path →
   the file was moved/copied: **relink** the existing blobs/chunks/vectors to the new path and re-embed
   nothing. (This is the single biggest win for photo libraries and duplicated folders.)
3. **Chunk-level re-embed.** If the hash changed, re-extract, then compare **chunk hashes** positionally
   (prefix/suffix match, or an LCS over `chunk_hash`). Re-embed only chunks whose hash is new. For a
   300-chunk PDF with one changed paragraph, that is 1 embed instead of 300.

**Triggers:**
* Launch/foreground sweep over each collection's bookmarked roots — bounded (e.g. 5 s, or 200 files) so it
  never blocks the UI.
* `BGProcessingTask` for the long tail (this app already declares
  `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`). Embedding is a textbook `BGProcessingTask`
  workload (`requiresExternalPower` optional).
* `NSFilePresenter` / `NSFileCoordinator` for files the app currently holds open — catches in-place edits
  the sweep would only see later.
* The repo's `FileProvider/AppGroupChangeWatcher.swift` pattern for App-Group-mediated changes.
* The **Share-Extension queue** (§3.7) as an explicit "index this now" trigger.

**Deletions and moves:** delete `emb_blobs` rows and let `ON DELETE CASCADE` take chunks and vectors
(`PRAGMA foreign_keys=ON` is required — SQLite defaults it off). Do **not** keep orphan vectors; at 3 KB a
row, a deleted 10 k-file photo library is 900 MB of garbage.

### 4.5 Model changes

Because every vector row names its `model_key`, a model change is not a migration:

* Adding a model → new `emb_vectors` rows with a new `model_key`; the old ones remain queryable.
* Changing the default model for a collection → update `emb_collections.model_key`; queries pin the
  collection's key; a background job backfills the new model's rows (or lazily on first query miss).
* Re-quantising the *same* repo (fp16 → q4) → **must** be a different `model_key`. Same dim, different
  numbers. The `dtype`/`spec_hash` columns exist precisely so this cannot be confused.
* Queries must never mix: `WHERE model_key = ?` is not an optimisation, it is correctness.

---

## 5. A model-agnostic embedder design

### 5.1 What `mlx-swift-lm` actually gives us (studied from source; cloned to `/tmp/mlxslm` at HEAD)

`Libraries/MLXEmbedders/` contains:

| File | Facts that matter |
|---|---|
| `ModelFactory.swift` | `public enum EmbedderTypeRegistry { public static let shared: ModelTypeRegistry<EmbeddingModel> = .init(creators: ["bert": createBertCompatibleModel, "roberta": …, "xlm-roberta": …, "distilbert": …, "nomic_bert": …, "qwen3": …, "lfm2": …, "gemma3": …, "gemma3_text": …, "gemma3n": …]) }` — i.e. **10 `model_type` keys mapped onto 5 concrete Swift types**. Plus `EmbedderRegistry` (`AbstractModelRegistry`) with ~22 ready-made `ModelConfiguration`s (bge-micro/gte-tiny/MiniLM L6+L12/snowflake arctic xs+lg/bge small/base/large/m3/multilingual-e5-small/nomic v1+v1.5/mxbai-large/Qwen3-Embedding-0.6B-4bit-DWQ/LFM2.5-Embedding-350M×3/LFM2.5-ColBERT-350M×3) and `EmbedderModelFactory.shared.loadContainer(from:using:configuration:progressHandler:)`. |
| `EmbeddingModel.swift` | `public protocol EmbeddingModel: BaseLanguageModel { var vocabularySize: Int; var poolingStrategy: Pooling.Strategy?; var maxPositionEmbeddings: Int?; func callAsFunction(_ inputs: MLXArray, positionIds:, tokenTypeIds:, attentionMask:) -> EmbeddingModelOutput }`; `EmbeddingModelOutput { hiddenStates: MLXArray?, pooledOutput: MLXArray? }`. |
| `Pooling.swift` | `Pooling.Strategy = { mean, cls, first, last, max, none }`. `loadPooling(modelDirectory:model:)` reads **`1_Pooling/config.json`**, decodes `word_embedding_dimension` + four `pooling_mode_*` flags, and maps with priority **CLS > Mean > Max > Last > first**; fallback to `model.poolingStrategy`; fallback `.none`. `Pooling.callAsFunction(_:mask:normalize:applyLayerNorm:)` supports **`dimension` truncation (Matryoshka)** and `l2Normalized()`. |
| `Reranker.swift` | `protocol RerankerModel: EmbeddingModel` for sequence-classification encoders; `EncoderRerankerScorePolicy = { singleLogit(transform:), classLogit(index:transform:), binaryMargin(positive:negative:transform:), softmaxProbability(classIndex:) }`; `BERTRerankerInputProcessor` / `XLMRobertaRerankerInputProcessor`; `EmbedderModelContainer.rerankerScores(query:documents:options:)` with micro-batching and `Task.checkCancellation()`. Separate `MLXRerankers` library. |
| `EmbedderModelContainer.swift` | `SerialAccessContainer<EmbedderModelContext>`; `perform { ctx in … }` **serialises all model access**; exposes `configuration`, `tokenizer`, `poolingStrategy`, `modelDirectory`. |
| `Models/*.swift` | `Bert`, `NomicBert`, `Qwen3`, `Gemma3` (`EmbeddingGemma`), `LFM2Bidirectional` (with a ColBERT head). |

`ModelTypeRegistry` itself is in `Libraries/MLXLMCommon/Registries/ModelTypeRegistry.swift`:

```swift
public actor ModelTypeRegistry<T> {
    public func registerModelType(_ type: String, creator: @escaping (Data) throws -> T)
    public func registerModelType(_ type: String, matches: @escaping (Data) -> Bool,
                                  creator: @escaping (Data) throws -> T)
    public func createModel(configuration: Data, modelType: String) throws -> sending T
    public func contains(_ modelType: String) -> Bool
}
```

**Consequences, stated plainly:**

* **Runtime registration already exists.** `EmbedderTypeRegistry.shared` is a `public static let` actor, so
  the app can call `await EmbedderTypeRegistry.shared.registerModelType("my-arch") { data in … }` at
  launch or when a model is downloaded. **No enum case per family is needed** — the registry *is* the
  extension point.
* **But the argument is a closure, i.e. compiled code.** `(Data) throws -> any EmbeddingModel` means a new
  *architecture* still needs a Swift type in the binary. Runtime registration removes the *enum*, not the
  *compiler*. Honest statement of the limit: **"download any Hugging Face embedding repo without changing
  app code" is achievable for every architecture the binary can build; "any repo at all" is not, on any
  platform, without a JIT or an interpreted-graph runtime.** [unverified: whether MLX could load a
  serialised mlx-graph from disk — no evidence found.]
* Therefore the lever is **coverage of architectures**, and the data is everything else (pooling, prefixes,
  dims, dtype, truncation, normalisation, max length). §5.2 splits those two responsibilities.

### 5.2 Three layers: registry (code) → spec (data) → sidecar (files on disk)

```swift
// LAYER 1 — code. One factory per *architecture family*, registered at runtime, no enum.
enum EmbedderFactories {
    static func registerAll() async {
        let r = EmbedderTypeRegistry.shared
        await r.registerModelType("bert_embed",  creator: makeBERTEmbedding)
        await r.registerModelType("nomic_bert",  creator: makeNomicEmbedding)
        await r.registerModelType("qwen3",       creator: makeQwen3LastToken)
        await r.registerModelType("gemma3_text", creator: makeEmbeddingGemma)
        await r.registerModelType("lfm2",        creator: makeLFM2Bidirectional)
        await r.registerModelType("clip",        creator: makeCLIP)             // text tower
        await r.registerModelType("clip_vision", creator: makeCLIPVision)       // image tower
        await r.registerModelType("siglip",      creator: makeSigLIP)
        await r.registerModelType("siglip_vision", creator: makeSigLIPVision)
    }
    /// Support check BEFORE a multi-GB download — the registry already offers this.
    static func canRun(_ modelType: String) async -> Bool {
        await EmbedderTypeRegistry.shared.contains(modelType)
    }
}
```

```swift
// LAYER 2 — data. Everything per-model that is not architecture. This is the sidecar, and it is also
// the runtime descriptor. Nothing here is a switch statement.
struct EmbeddingSpec: Codable, Hashable {
    var schemaVersion = 1
    var repo: String                  // "BAAI/bge-small-en-v1.5"
    var revision: String?             // requested ref
    var revisionSha: String           // FULL sha — LocalModelInspection.revision already has it
    var architecture: String          // config.json model_type, e.g. "bert"
    var factoryKey: String            // which registered creator builds it (usually == architecture)

    var modality: [Modality]          // [.text], [.text,.image], [.text,.audio]
    var dim: Int                      // output dim actually produced
    var nativeDim: Int?
    var matryoshkaDims: [Int]?        // [1024,768,512,256,128,64] for nomic v1.5 / EmbeddingGemma
    var dtype: String                 // "fp16"|"bf16"|"q4"|"q8"
    var pooling: PoolingKind          // .mean .cls .last .max .first .noneMul .colbert
    var normalize: Bool
    var maxTokens: Int                // min(model max, sentence_bert_config.max_seq_length)
    var maxPositionEmbeddings: Int?   // from EmbeddingModel.maxPositionEmbeddings

    var prefixPolicy: PrefixPolicy    // .required | .forbidden | .optional
    var queryPrefix: String?          // "search_query: "
    var documentPrefix: String?       // "search_document: "
    var instructionTemplate: String?  // "Instruct: {task}\nQuery: {query}"
    var defaultInstruction: String?

    var projection: Projection?       // .linear(path:), .mlp(path:) — for CLIP-style towers
    var provenance: [String: String]  // field -> "1_Pooling/config.json" | "model card" | "app default"
    var raw: [String: String]         // verbatim copies of the small config files, for audit
    var specHash: String              // sha256 of the canonical JSON (self-excluding)
}
```

```swift
// LAYER 3 — the write path. LocalModelStore.adopt(from:id:) already writes `.looplab.json`
// ({"id":…,"source":"huggingface","adopted":…}) into the model dir. It writes `.minis-embed.json`
// beside it, at the same moment, so the model is never loadable-but-unspecced.
extension LocalModelStore {
    static func writeEmbeddingSidecar(in dir: URL, spec: EmbeddingSpec) throws {
        try JSONEncoder.pretty.encode(spec)
            .write(to: dir.appendingPathComponent(".minis-embed.json"))
    }
}
```

The model library already has the hooks this needs: `LocalModelCatalog.inspect(_:)` returns
`files/totalBytes/weightBytes/hasConfig/hasWeights/revision` (the commit sha included), and
`LocalModelStore.adopt(from:id:)` moves the snapshot in and writes a marker. Adding
`kind: .embedding` to `LocalModelKind` (`Providers/LocalMLX/LocalModelStore.swift`) plus an
`embedderTypes: Set<String>` allow-list (parallel to the existing `vlmTypes`) is a ~15-line change that
makes embedding models first-class in the existing library UI, downloader, and delete path. **This is the
cheapest high-value change in the whole plan.**

### 5.3 Pooling per model — read it, don't switch on it

The app must derive pooling from files, in this order:

1. **`modules.json`** — the sentence-transformers pipeline. Verified real content
   (`sentence-transformers/all-MiniLM-L6-v2`, `BAAI/bge-m3`, `BAAI/bge-small-en-v1.5` all ship it):
   ```json
   [{"idx":0,"name":"0","path":"","type":"sentence_transformers.models.Transformer"},
    {"idx":1,"name":"1","path":"1_Pooling","type":"sentence_transformers.models.Pooling"},
    {"idx":2,"name":"2","path":"2_Normalize","type":"sentence_transformers.models.Normalize"}]
   ```
   Two facts fall out that `1_Pooling/config.json` alone cannot give you:
   **the presence of a `2_Normalize` module ⇒ `normalize = true`**, and the pooling module's `path`
   (usually `1_Pooling`, but the path is data, not a constant).
2. **`<path>/config.json`** — verified real content for MiniLM:
   `{"word_embedding_dimension":384,"pooling_mode_cls_token":false,"pooling_mode_mean_tokens":true,
   "pooling_mode_max_tokens":false,"pooling_mode_mean_sqrt_len_tokens":false}`; bge-small: same file with
   `pooling_mode_cls_token:true, pooling_mode_mean_tokens:false` (384-d); bge-m3: `cls_token:true`, 1024-d.
   Note two things mlx-swift-lm's decoder does **not** handle: the key set includes
   `pooling_mode_mean_sqrt_len_tokens` (ignored) and **omits `pooling_mode_lasttoken`** (its
   `PoolingConfiguration` decodes that key with `?? false`, which is safe). Also:
   `word_embedding_dimension` is the *pooled* dim, which is what you store.
3. **`sentence_bert_config.json`** — verified: MiniLM `{"max_seq_length":256,"do_lower_case":false}`,
   bge-small `{512,true}`, bge-m3 `{8192,false}`. **This is the field to use for chunking, and it is not
   `max_position_embeddings` from `config.json`** — MiniLM's model supports 512 positions but was trained
   at 256, and embedding beyond the training length degrades quietly.
4. **`config_sentence_transformers.json`** — in the three models checked it contains only a `__version__`
   block, **no `prompts`**. Do not rely on it for prefixes; it is a git-history artifact for most repos.
5. **Model card / app default** — for anything not shipped in files (CLIP/SigLIP ship neither
   `1_Pooling` nor `modules.json`; `jinaai/jina-clip-v2` ships `modules.json` but **no `1_Pooling`**,
   verified). Those get an app-side default keyed by `architecture`, and the default is written into the
   sidecar with `provenance["pooling"] = "app default for siglip"` so the assumption is auditable.

**Verified pooling examples to encode as fixtures in tests:** MiniLM-L6-v2 → mean, 384-d, max 256;
bge-small-en-v1.5 → cls, 384-d, max 512; bge-m3 → cls, 1024-d, max 8192;
Qwen3-Embedding-0.6B → last-token (mlx-swift-lm's `Qwen3Model`; `swift-embeddings`' README says
"decoder-only embedding models that use last-token pooling"); LFM2.5-Embedding → CLS, 1024-d;
LFM2.5-ColBERT → per-token 128-d multi-vectors; CLIP/SigLIP → the model's own pooled output
(`EmbeddingModelOutput.pooledOutput`), 512/768 or 1152-d.

### 5.4 Mandatory task prefixes — encode as three-valued metadata

This is the requirement's "some require them, others forbid them" problem. The encoding:

```swift
enum PrefixPolicy: String, Codable { case required, forbidden, optional }
struct Role { static let query = Role(); static let document = Role() }
func prepare(_ text: String, role: Role, task: String? = nil) -> String {
    switch spec.prefixPolicy {
    case .forbidden: return text                                  // CLIP/SigLIP text tower: raw text
    case .required, .optional:
        if let t = spec.instructionTemplate {                     // Qwen3-Embedding style
            return t.replacingOccurrences(of: "{task}", with: task ?? spec.defaultInstruction ?? "")
                    .replacingOccurrences(of: "{query}", with: text)
        }
        let p = (role === Role.query) ? spec.queryPrefix : spec.documentPrefix
        return (p ?? "") + text
    }
}
```

Documented prefix conventions to seed the sidecar with (**the sidecar is the source of truth; these are
just the values it gets populated with**):

| Family | Prefix / instruction | Policy |
|---|---|---|
| `intfloat/*-e5-*` (incl. `multilingual-e5-small`) | `"query: "` / `"passage: "` | required |
| `BAAI/bge-*-v1.5` | query-only instruction `"Represent this sentence for searching relevant passages: "` | required for queries |
| `nomic-ai/nomic-embed-text-v1(.5)` | `"search_query: "` / `"search_document: "` (+ `classification:`, `clustering:`) | required |
| `Qwen/Qwen3-Embedding-*` | `"Instruct: {task}\nQuery: {query}"` | optional-but-recommended (queries) |
| `google/embeddinggemma-*` | task prompts (`"task: search result \| query: {content}"` family) [unverified exact strings] | optional |
| CLIP / SigLIP text towers | none | **forbidden** |

The important design point is not the table — it is that **`prefix_policy` and the two templates live on
the `emb_models` row**, so a query performed against a collection built with a `.required` model can never
be served by a bare string, and an image tower is never handed `"search_query: "`.

### 5.5 Matryoshka, max length, normalisation

* **Matryoshka (MRL).** Nomic v1.5, EmbeddingGemma and modern bge/e5 checkpoints are trained so the first
  *d* dims of the vector are themselves a usable embedding. `Pooling.dimension` implements exactly this
  (`pooled = pooled[0..., 0..<dimension]` **before** `l2Normalized()`), so truncation must always be
  followed by re-normalisation — and mlx-swift-lm's `Pooling` does, in that order. Store
  `matryoshkaDims` in the spec, pick a truncation per collection (`emb_collections`), and store the
  **truncated** `dim` on the vector row so two sizes can never be compared by accident.
  Practical rule: index at 256 d for a large corpus, re-rank the top-100 at full dim. That is a 3× storage
  saving with almost no recall loss [unverified magnitude; measure].
* **Max sequence length.** Effective limit = `min(spec.maxTokens, model.maxPositionEmbeddings)`.
  `EmbeddingModel.maxPositionEmbeddings` is `nil` for RoPE models (arbitrary length) — mlx-swift-lm
  truncates internally *"with a warning"* above the limit, which for us is a silent quality bug, so we
  must pre-chunk to the spec's limit and never rely on the internal truncation.
* **Normalisation.** `normalize` must be stored and honoured. Two collections of the same model, one
  normalised and one not, produce cosine scores that differ by a constant factor per row — a "drift" that
  looks like a quality regression and is actually a flag. Cosine always; never L2-distance, because a
  model's similarity function is documented in its card (`similarity_fn_name: cosine` for ST models) and
  dot-product models (some Qwen3 setups) require normalisation to behave.

### 5.6 Recording the exact configuration on every vector

Three things, and all three are needed:

1. **`emb_models` row per configuration** with the full spec JSON + `spec_hash` (already in §4.2).
2. **`model_key` on every `emb_vectors` row** — `"\(repo)@\(revisionSha.prefix(8)):\(specHash.prefix(8))"`.
   Stable, sortable, and it names the two things that can change underneath you: the weights and the spec.
3. **A hard guard at query time:**

```swift
func assertCompatible(_ spec: EmbeddingSpec, with row: VectorRow) throws {
    guard row.modelKey == spec.key else {
        throw EmbeddingError.modelMismatch(stored: row.modelKey, live: spec.key)
    }
    guard row.dim == spec.dim else {
        throw EmbeddingError.dimMismatch(stored: row.dim, live: spec.dim)
    }
}
```

**The trap this exists to catch:** re-quantising `Qwen3-Embedding-0.6B` from bf16 to 4-bit-DWQ (both
1024-d, both last-token, both same repo) yields vectors that are *close but not identical*. They are not
interchangeable — cosine scores drop noticeably and, worse, they drop *non-uniformly*, so a mixed index
looks like it works until it silently ranks badly. `dtype` in the spec and in `model_key` is the fix.
Ditto for a different `revision_sha` off the same branch: `LocalModelCatalog` already pins the sha for the
resolve URL, so record it.

Also record, on the *blob*, which **extractor** produced the text (`emb_blobs.extractor` / `.quality`).
This matters more than it sounds: if you later change the PDF chunker or turn OCR on, the vectors are stale
even though the file's `content_hash` is unchanged. Treat `(content_hash, extractor_version)` as the blob
key, not `content_hash` alone.

---

## 6. Coexistence and memory: a multimodal embedder next to a 3–4B chat model

### 6.1 The existing invariant, and its numbers

`Providers/LocalMLX/LocalModelHost.swift` already enforces a single-slot policy: *"Nothing else may load
one, and loading is refused unless the model can actually fit."* Concretely:

* `load(modelId:)` calls `await unload()` **first**, then measures `os_proc_available_memory()` (line ~193),
  and refuses with a readable `LocalModelError.outOfMemory(needBytes:haveBytes:model:)` if
  `LocalModelStore.runCost(for:contextTokens:kvBits:)` doesn't fit.
* `runCost = weights + kvBytesPerToken × contextTokens × (kvBits/16) + 320 MB working`.
* `Memory.cacheLimit = 64 * 1024 * 1024` (line ~207) — a deliberately small MLX buffer cache (the file
  cites a measured 164 tok/s on Qwen3-0.6B with 64 MB vs no benefit from a bigger pool).
* `LocalInferenceSettingsView` reports whether the signed build carries the increased-memory-limit
  entitlement (~6 GB instead of ~3.25 GB).

An **embedder's** cost profile is different and the same formula must not be reused blindly:
`weights + activation_scratch`, **no KV term** (an encoder has no growing cache). For a text encoder the
scratch is small (a few MB at batch 16, 512 tokens). For a **vision tower** the scratch is the risk: a
ViT at 384² with patch 14 is 729 tokens per image, and a batch of 16 images is 11,664 tokens of
activations *per layer* held for the forward pass. Batch images in **1–4**, not 16 [unverified magnitude;
this needs the same empirical treatment `runCost` got for the LLM path].

Sizes for planning (4-bit unless noted, from HF repos verified in §3/§5):
* Text embedder, always-resident candidate: MiniLM-L6 (22 M params, ~22 MB 4-bit), bge-small (33 M, ~33 MB),
  gte-tiny (<20 MB), nomic-embed-v1.5 (137 M, ~137 MB fp16 / ~70 MB 4-bit).
* Text embedder, on-demand: Qwen3-Embedding-0.6B (0.6 B, ~350–400 MB 4-bit).
* Multimodal: CLIP-ViT-B/32 (~150 M, ~150–300 MB), SigLIP-so400m (~880 M, ~450 MB fp16 / ~**1.1 GB** at
  4-bit scaled by the usual ~2× for a 4-bit-with-scales layout — the number the task quotes; the exact
  figure depends on the quantisation scheme [unverified]).
* Chat model for comparison: Qwen3-4B 4-bit ≈ 2.3 GB weights, plus KV (this repo's own comment gives the
  Qwen3-0.6B KV arithmetic: 28 layers × 2 × 8 heads × 128 dim × 2 B = 112 KB/context-token, i.e. 0.74 GB at
  6.6 k context). A 4B model at 8 k context is comfortably 3 GB+.

### 6.2 The policy I recommend

**Three tiers, decided by size and by who needs to be warm:**

1. **Tier 0 — always resident, ≤ ~40 MB: one small text embedder.** MiniLM-L6 or bge-small, 4-bit, 384-d.
   This is the *only* model the Shortcuts search path needs on the hot path, and it is small enough that
   keeping it permanently loaded costs less than the working memory of a single PDF page render. It also
   gives chat the ability to do RAG without a model load.
2. **Tier 1 — on-demand, evictable: the multimodal embedder** (SigLIP/CLIP). Loaded when an "Embed
   Photos" / "Embed Video" job starts or when a collection's `model_key` demands it; unloaded at the end
   of the job (or after N minutes idle) so the chat model can be admitted.
3. **Tier 2 — the chat model**, which keeps the current exclusive-slot behaviour.

Concretely: change `LocalModelHost`'s single slot into a **slotted residency manager** with two kinds of
slot — `generative` (exclusive, one at a time — unchanged) and `embedding` (≤ 2, budgeted separately).
The admission check for an embedding load is `weights + scratch`; the check for a generative load becomes
`weights + kv + working + Σ(resident embedding weights)` so that chat admission *accounts for* the tiny
embedder rather than pretending it is free. That single arithmetic change is what makes the two coexist
instead of fighting.

**The "separate mode" the requirement anticipates is Tier 1's eviction policy**: a user-visible
**"Media indexing mode"** switch that (a) permits the multimodal embedder to be resident, (b) permits
background indexing of photos/video, and (c) warns that generation will be slower while it is on. Default
off. This is better than heuristics because the phone cannot know whether the user is about to chat.

**Eviction triggers, in order of reliability:**
* End of job (explicit unload) — always correct, always cheapest to reason about.
* `UIApplication.didReceiveMemoryWarningNotification` → unload Tier 1 immediately.
* A generative load that does not fit with Tier 1 resident → unload Tier 1, then retry once.
* Idle timer (5 min with no embed job) → unload Tier 1.

### 6.3 Not starving generation on the shared Metal queue

MLX on iOS runs on one `MTLDevice`/command queue per process; `Memory.cacheLimit` is process-global, and
`Stream`/compile caches are shared. So a 4-second embedding batch *does* stall token generation. The app
already has the right primitive: `EmbedderModelContainer.perform` guards with a
`SerialAccessContainer`, and `LocalModelHost` is an actor — but serialised access is not *fair*
scheduling. Add an explicit scheduler:

* **Batch small** (text: 8–32; images: 1–4). Between batches: `try Task.checkCancellation()` **and**
  `await Task.yield()` (or a 10–20 ms sleep) so an in-flight generation stream can enqueue.
* **Priority inversion guard:** if a generation is streaming (the app knows: `LocalModelHost` publishes
  `residentModelId` + the VM's `$isProcessing`), an embed job reduces its batch size and inserts a longer
  yield. A Shortcut-triggered embed is *never* more urgent than a live response the user is reading.
* **Never evolve a shared `Memory.cacheLimit` at runtime.** The 64 MB value is a measured tuning decision
  in this codebase; an embed path that raises it for its own benefit regresses chat throughput.
* **`LongRunningIntent`'s progress ticks are also our scheduling heartbeat** — the same loop that reports
  progress can yield. One mechanism, two purposes.

### 6.4 Core ML/ANE as the neighbour: the honest tradeoff

A Core ML (or MLTensor) embedder and an MLX chat model **do not share the bottleneck**: Core ML dispatches
to the Neural Engine (and to GPU/CPU as fallback), while MLX owns the Metal GPU path. So an ANE embedder:

* **does not evict** the chat model (different memory pool, much smaller Jetsam contribution),
* **does not contend** for the Metal queue or `Memory.cacheLimit`,
* is better on **power** and on **latency at batch 1** (an ANE is very strong at a single small encoder
  forward pass),
* has a **fixed, predictable** footprint (Core ML serialises shapes at compile time).

And it costs:

* **A conversion step.** Every new model needs `coremltools` conversion on a Mac/CI — i.e. the
  "download any HF repo and it just works" requirement is *violated* for the ANE path unless you convert on
  the fly, which you cannot. This is the decisive argument: **the ANE path can never satisfy requirement
  (a); the MLX path can.**
* **fp16-only on the ANE** [unverified: whether iOS 26 Core ML supports non-fp16 weights on ANE outside of
  palettisation/quantisation APIs; ANE has historically been fp16].
* **No dynamic Matryoshka truncation** (the graph has one output shape), no per-model pooling plugins
  (you bake the pooling into the conversion), no multimodal towers unless you build them in explicitly.
* **Tokenisation is yours**: Core ML takes `input_ids`; you still need `swift-transformers` for the
  tokenizer, and you must ship/metadata the same prefix logic (§5.4) — so the spec layer is needed anyway.

**`jkrukowski/swift-embeddings` is the concrete ANE/MLTensor alternative to evaluate.** Verified from its
README (v0.0.16+, MIT):
* Runs models on **`MLTensor`** (Apple's tensor type; `MLComputePolicy` selectable per call) rather than
  MLX — so it sits on the Core ML/ANE side of the fence.
* Supports **BERT, ModernBERT, NomicBERT, RoBERTa, XLM-RoBERTa, Qwen3 (last-token), CLIP (text only),
  Word2Vec, Model2Vec, StaticEmbeddings**.
* **It already does part of §5.3**: *"These are derived at load time from the model's
  `sentence-transformers` configuration (`modules.json`, `*_Pooling/config.json`, the
  `sentence_*_config.json` transformer config, and the tokenizer's `model_max_length`) when present — so a
  `sentence-transformers` model is pooled correctly out of the box (e.g. `nomic-ai/nomic-embed-text-v1.5` →
  `.meanPool(normalize: false)`, `nomic-ai/modernbert-embed-base` → `.meanPool(normalize: true)`)."*
  That is the sidecar-free version of exactly our metadata problem.
* It requires **F32 or quantised** weights for some models (`MLTensor` cannot represent BF16 — the README
  says so explicitly for Qwen3 checkpoints, and points at F32 conversions).
* Caveat for us: it does **not** cover the modern decoder-style or multimodal architectures we care most
  about (no Gemma3-Embedding, no LFM2/ColBERT, no image tower), and it is a separate engine with its own
  Hub loader.

**`VecturaKit` (rryam)** is the store-side alternative. Verified: on-device vector DB, **pluggable
embeddings** via a `VecturaEmbedder` protocol with adapters for `MLXEmbedder` (VecturaMLXKit),
`SwiftEmbedder` (VecturaEmbeddingsKit), `NLContextualEmbedder` (NaturalLanguage, zero dependencies) and
`OpenAICompatibleEmbedder`; **hybrid search** combining vector similarity with BM25; auto-dimension
detection; storage modes (automatic / full-memory / indexed) for datasets from thousands to millions;
pluggable `VecturaStorage` (explicitly naming SQLite as an option) and `VecturaSearchEngine`.
Adopt from it: the **hybrid scoring** (BM25 + vector fusion is what makes a "search my notes" Shortcut feel
good on short queries and exact names, where pure cosine is weak) and the **indexed storage mode** design.
Adopt *as a package* only if we are willing to run a second store next to `ChatStore`; if the single-DB
argument in §4.1 wins, implement BM25 as a small FTS5 table in `Embeddings.sqlite` instead — SQLite's FTS5
is built into the system SQLite on iOS (link against the system `libsqlite3` or an amalgamation) and is
about 20 lines of DDL + a ranked query.

**Recommendation:** keep **MLX as the single inference engine** for embeddings (it satisfies the
no-hardcoding requirement, reuses `LocalModelCatalog`/`LocalModelDownloader`/`LocalModelStore`, and covers
text + vision towers). Take **`swift-embeddings`' metadata-reading approach** as the model for §5.3, and
evaluate the package itself only as an *optional* Tier-0 tiny-text embedder if on-device measurement shows
that a 22 MB MLX model's GPU presence measurably disturbs generation. Do not run two inference engines
without that measurement.

### 6.5 What "no hardcoding" costs in memory terms

The requirement "downloading a new embedding model from HF should work without changing app code" implies
the app can hold **several** embedders' metadata and **at most one or two** of their weights. The schema in
§4 handles this naturally: `emb_models` is unbounded (specs are ~2 KB), `emb_vectors` is per-model, and
residency is a separate, budgeted decision. Downloaded-but-not-resident models should behave exactly like
the chat library's unloaded models today — visible, sized, deletable, and reported against
`os_proc_available_memory()` before any load is attempted.

---

## 7. Recommendation: build order, and what to adopt instead of hand-rolling

### 7.1 Build order

**Phase 0 — the spec layer (build this first, ~1–2 days).**
`EmbeddingSpec` + `EmbeddingSpecReader` (reads `config.json`, `modules.json`, `<pool>/config.json`,
`sentence_bert_config.json`, `tokenizer_config.json`) + `.minis-embed.json` writer hooked into
`LocalModelStore.adopt(from:id:)` + `LocalModelKind.embedding` + an `embedderTypes` allow-list parallel to
`vlmTypes` + `EmbedderFactories.registerAll()` over `EmbedderTypeRegistry.shared.registerModelType`.
**Nothing else can be built correctly before this**, because pooling/prefix/dim/dtype are exactly what the
index, the chunker, and the query path all consume. It is also independently testable: assert
MiniLM→(mean, 384, 256, normalize), bge-small→(cls, 384, 512, normalize), bge-m3→(cls, 1024, 8192).
**First thing to build = `EmbeddingSpecReader` with those three fixtures.**

**Phase 1 — text embedding end to end (~2–3 days).**
`EmbeddingCoordinator` (serialised, batched, yields), `EmbeddingHost` (residency via the existing
`os_proc_available_memory()` gate), the `emb_*` tables in `Embeddings.sqlite`, and **`EmbedFileIntent`**
with `LongRunningIntent` + progress. Text files, markdown, and code only. Wire
`ShortcutRunTracker.markPending/complete`. Ship this as the walking skeleton.

**Phase 2 — search (~1–2 days).**
`VectorIndex.search` with a deadline, `SemanticSearchIntent`, `SearchHitEntity` + its query, stable IDs,
plus a `CollectionEntity`. Add the FTS5 BM25 table now and fuse scores — it is what makes short queries
work, and retrofitting fusion later means re-tuning twice.

**Phase 3 — file extractors (~3–5 days).**
`FileExtractor` protocol + text/markdown/code → PDF (with the OCR fallback and per-page caching) →
images (Vision OCR + feature print as the zero-download fallback) → OOXML/EPUB via a small ZIP+XML reader
→ audio (SpeechAnalyzer/ASR) → video (keyframes + audio). Then the **incremental indexer**: mtime/size
gate → content hash → chunk-hash diff → re-embed changed chunks only. Then the Share-Extension
"Embed in Minis" handoff into the App Group queue.

**Phase 4 — multimodal towers (~1 week).**
CLIP/SigLIP image tower via MLX (text→image search first, because that is the demo that sells it), then
multi-vector keyframe storage for video reusing the ColBERT machinery in `MLXEmbedders`, then — only if
still wanted — an audio tower (CLAP has no MLX conversion today, so this is a conversion project, not an
integration task).

**Phase 5 — memory and polish.**
Two-slot residency manager, "Media indexing mode", eviction triggers, `BGProcessingTask` nightly sweep,
Matryoshka truncation controls, optional reranker (`MLXRerankers`, `RerankerModel`) over the top-100.

**Defer indefinitely:** ANN indexes (brute force + `sqlite-vec` later if measured), audio tower, ColBERT
for text, on-device model conversion pipelines, Core ML as a second engine.

### 7.2 Adopt rather than hand-roll

| Component | Adopt | Why / what exactly |
|---|---|---|
| Architecture registry | **`MLXEmbedders.EmbedderTypeRegistry` + `ModelTypeRegistry.registerModelType`** (already a dependency) | The runtime registration API already exists and is public; `contains(_:)` gives a pre-download support check. |
| Pooling | **`MLXEmbedders.Pooling` + `loadPooling`** | mean/cls/first/last/max/none, MRL truncation, L2 normalisation — already implemented and already reads `1_Pooling/config.json`. Extend by also reading `modules.json` for the `2_Normalize` module. |
| Sentence-transformers metadata | **`swift-embeddings`' load-time derivation** (as a design to copy) | It proves the `modules.json` + `*_Pooling/config.json` + `sentence_*_config.json` + tokenizer `model_max_length` path works end to end. |
| Model download/inspection | **`LocalModelCatalog` + `LocalModelDownloader` + `LocalModelStore`** (in-repo) | Already returns the commit sha, file list, sizes, gated-repo handling, symlink-safe adopt, and bookmark-based custom roots. |
| PDF text | **PDFKit** `PDFDocument`/`PDFPage.string` | Exact when it works; the fallback is the only thing to write. |
| OCR / image features | **Vision** `VNRecognizeTextRequest`, `VNGenerateImageFeaturePrintRequest` | Free, on-device, no download. |
| On-device ASR | **`SpeechAnalyzer`/`SpeechTranscriber`** (iOS 26) with `SFSpeechRecognizer` as the older path | Long-form transcription + on-device asset management. |
| Fuzzy/exact search | **SQLite FTS5** (system SQLite) or **VecturaKit's hybrid algorithm** | BM25 fusion with vector scores; FTS5 is in the OS. |
| Vector extension | **`sqlite-vec` (asg017)** + **`SQLiteVec` (jkrukowski)** | Only when brute force measurably fails; compile-in, never `dlopen`. |
| Zero-download text embedder | **`NaturalLanguage.NLContextualEmbedding`** (iOS 17+) | Apple's on-device contextual text embedding, 512-d, multilingual, no weights to ship. A legitimate default for the Shortcuts search path when no model is installed. `https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding` |
| Reranking | **`MLXRerankers` / `MLXEmbedders.RerankerModel`** | Cross-encoder scoring is already implemented with batching, cancellation, and score policies. |
| ANE text path (optional) | **`jkrukowski/swift-embeddings`** | Only if measurement shows the MLX tiny model disturbs generation. |
| Store (optional) | **`VecturaKit`** | Hybrid search + storage modes, MIT. |

### 7.3 The one-sentence version

The registry extension point already exists, so the real work is not "support many models" — it is
**writing the spec sidecar and reading the sentence-transformers metadata it must contain**, then building
`EmbedFileIntent` on `LongRunningIntent` over a brute-force `emb_vectors` blob column in a sibling
SQLite file, with a 22 MB text embedder permanently resident and a 1.1 GB multimodal embedder behind an
explicit media-indexing mode.

---

### Assumptions made

* "iOS 27" is treated as the next release after the documented iOS 26 API surface; any API I could only
  verify as of iOS 26 (e.g. `supportedModes`, `IntentModes`, `LongRunningIntent`, `SpeechAnalyzer`) is
  presented as such. iOS 27 additions I could not verify are marked `[unverified]` or omitted.
* The app is signed with a profile that can carry `com.apple.developer.kernel.increased-memory-limit`
  (the repo already tests for it at runtime, which implies an intent to ship with it).
* All numeric memory/speed figures for embedders are planning estimates, not measurements from this
  device; the LLM-path figures quoted are the repo's own comments.
