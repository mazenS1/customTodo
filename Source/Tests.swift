import Foundation

// Run in an isolated directory; no developer repositories, login, or real Codex runs
// are touched. These checks target preservation, recovery, and injection boundaries.
@MainActor func runTests() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("todo-inbox-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        // Derive fixture names from the selected build configuration so the same tests
        // protect both the public example and a contributor's ignored local override.
        let project = "\(AppConfig.current.projectDirectoryPrefix)test"
        let oldPreferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"automatic":true,"dailyLimit":12,"model":"","codexPath":"/fixture/codex"}"#.utf8))
        precondition(!oldPreferences.isDarkMode && oldPreferences.textScale == 1 && oldPreferences.effort.isEmpty)
        precondition(oldPreferences.allowsWebResearch && oldPreferences.depth == "quick")
        var researchPreferences = oldPreferences
        researchPreferences.depth = "deep"; researchPreferences.allowsWebResearch = false
        let savedResearch = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(researchPreferences))
        let deepPolicy = ReviewPolicy(preferences: savedResearch)
        precondition(deepPolicy.timeoutMinutes == AppConfig.current.deepReviewMinutes && deepPolicy.webMode == "disabled")
        precondition(deepPolicy.exploration.contains("no fixed file-count cap"))
        let quickPolicy = ReviewPolicy(preferences: oldPreferences)
        precondition(quickPolicy.timeoutMinutes == AppConfig.current.quickReviewMinutes && quickPolicy.webMode == "live")
        precondition(quickPolicy.research.contains("Never put private code"))
        var appearance = oldPreferences
        appearance.isDarkMode = true; appearance.effort = "high"; appearance.textScale = 1.2
        let reloaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(appearance))
        precondition(reloaded.isDarkMode && reloaded.effort == "high" && reloaded.textScale == 1.2)
        appearance.textScale = 10; precondition(appearance.textScale == 1.5)
        appearance.textScale = 0; precondition(appearance.textScale == 0.85)
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop.appendingPathComponent(project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop.appendingPathComponent("unrelated"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: desktop.appendingPathComponent("\(AppConfig.current.projectDirectoryPrefix)link"), withDestinationURL: desktop.appendingPathComponent("unrelated"))
        let legacy = "-Complete [✓]\n-Multiline\n{\n  \"errors\": []\n}\n\n-Third"
        let legacyURL = desktop.appendingPathComponent(project).appendingPathComponent(AppConfig.current.legacyTodoFilename)
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent("models.json")
        try Data(#"{"models":[{"slug":"visible","display_name":"Visible","visibility":"list"},{"slug":"internal","display_name":"Internal","visibility":"hide"},{"slug":"visible","display_name":"Duplicate","visibility":"list"}]}"#.utf8).write(to: cache)
        precondition(modelChoices(at: cache, selected: "saved").map(\.id) == ["visible", "saved"])
        precondition(modelChoices(at: root.appendingPathComponent("missing"), selected: "saved").map(\.id) == ["saved"])
        let data = root.appendingPathComponent("Data")
        let store = Store(directory: data, desktop: desktop, startTimer: false)
        precondition(store.projects == [project])
        store.importLegacy(); store.importLegacy()
        precondition(store.db.todos.count == 3, "Import must be idempotent")
        precondition(store.db.todos[0].done)
        precondition(store.db.todos[1].text.contains("\"errors\": []"))
        precondition(store.db.todos.allSatisfy { !$0.autoEligible })
        let preserved = try String(contentsOf: legacyURL)
        precondition(preserved == legacy)
        let observation = "$(touch /tmp/never-run-this) `echo no` ; unicode ✓"
        precondition(store.add(observation, project: "Auto", category: "Security"))
        precondition(!store.add("  \n", project: "Auto", category: "Auto"))
        let reopened = Store(directory: data, desktop: desktop, startTimer: false)
        precondition(reopened.db.todos.first?.text == observation)
        reopened.db.todos[0].state = "Investigating"; reopened.save()
        let recovered = Store(directory: data, desktop: desktop, startTimer: false)
        precondition(recovered.db.todos[0].state == "Failed")
        let id = recovered.db.todos[0].id
        recovered.update(id, done: true)
        precondition(recovered.db.todos[0].done)
        recovered.update(id, done: false)
        precondition(!recovered.db.todos[0].done)
        try Data("corrupted".utf8).write(to: recovered.file)
        let corrupt = Store(directory: data, desktop: desktop, startTimer: false)
        precondition(!corrupt.storageError.isEmpty)
        precondition(!corrupt.add("must not overwrite", project: "Auto", category: "Auto"))
        let preservedCorruption = try String(contentsOf: corrupt.file)
        precondition(preservedCorruption == "corrupted")
        let scheduledStore = Store(directory: root.appendingPathComponent("ScheduledData"), desktop: desktop, startTimer: true)
        precondition(!scheduledStore.hasAutomationTimer, "Disabled automation must not keep a polling timer alive")
        scheduledStore.db.preferences.automatic = true
        precondition(scheduledStore.add("scheduled review", project: "Auto", category: "Auto"))
        precondition(scheduledStore.hasAutomationTimer, "A newly queued automatic review needs one deferred wake-up")
        scheduledStore.db.preferences.automatic = false
        precondition(scheduledStore.save() && !scheduledStore.hasAutomationTimer, "Disabling automation must cancel its deferred wake-up")
        print("PASS: project discovery, symlink exclusion, multiline import, done markers, import deduplication, original preservation, literal capture, empty rejection, persistence, interrupted-run recovery, completion/reopening, corruption protection")
    } catch { fatalError("Test failure: \(error)") }
}

@MainActor func runWorkerTests() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("todo-worker-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let project = "\(AppConfig.current.projectDirectoryPrefix)test"
        let desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop.appendingPathComponent(project), withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("models.json")
        try Data(#"{"models":[{"slug":"fixture","display_name":"Fixture","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]},{"slug":"second","display_name":"Second","visibility":"list","supported_reasoning_levels":[{"effort":"low"}]}]}"#.utf8).write(to: cache)
        let choices = modelChoices(at: cache, selected: "fixture")
        precondition(supportedEfforts(models: choices, model: "fixture") == ["low", "high"])
        precondition(supportedEfforts(models: choices, model: "") == ["low"])
        precondition(supportedEfforts(models: choices, model: "missing").isEmpty)
        let store = Store(directory: root.appendingPathComponent("Data"), desktop: desktop, startTimer: false, modelCacheURL: cache)
        let stub = root.appendingPathComponent("stub-codex")
        let finding = Finding(project: project, category: "Bug", severity: "Low", confidence: "High", summary: "Fixture finding", evidence: ["\(project)/source.swift:1 — fixture"], nextStep: "Inspect fixture", limitations: "Test output")
        let encoded = String(data: try JSONEncoder().encode(finding), encoding: .utf8)!
        // Stub asserts the important launch boundaries and consumes stdin as inert data.
        let script = """
        #!/bin/zsh
        set -eu
        [[ "$*" == *"--ignore-user-config"* && "$*" == *"--ignore-rules"* && "$*" == *"--sandbox read-only"* ]] || exit 21
        [[ -z "${OPENAI_API_KEY:-}" && -z "${CODEX_API_KEY:-}" ]] || exit 22
        [[ "$*" == *'model_reasoning_effort="high"'* && "$*" == *'--model fixture'* ]] || exit 23
        [[ "$*" == *'web_search="live"'* ]] || exit 24
        destination=""
        while (( $# )); do
          if [[ "$1" == "-o" ]]; then shift; destination="$1"; fi
          shift
        done
        /bin/cat > '\(root.appendingPathComponent("prompt.txt").path)'
        /usr/bin/printf '%s' '\(encoded)' > "$destination"
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        store.db.preferences.codexPath = stub.path
        store.db.preferences.model = "fixture"
        store.db.preferences.effort = "high"
        precondition(store.add("$(echo never-execute) ; inert observation", project: project, category: "Security"))
        let id = store.db.todos[0].id
        store.investigate(id)
        for _ in 0..<100 where store.active != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(store.active == nil && store.db.todos[0].state == "Reviewed", "Worker must ingest structured result")
        precondition(store.db.todos[0].category == "Security", "Manual classification must survive AI output")
        precondition(store.usedToday == 1)
        let quickPrompt = try String(contentsOf: root.appendingPathComponent("prompt.txt"))
        precondition(quickPrompt.contains("QUICK triage") && quickPrompt.contains("no fixed file-count cap"))
        precondition(quickPrompt.contains("built-in web search tool") && quickPrompt.contains("Never put private code"))
        store.db.preferences.dailyLimit = 1
        store.investigate(id)
        precondition(store.active == nil && store.usedToday == 1, "Daily limit must gate manual runs")
        store.db.preferences.dailyLimit = 12
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let originalFinding = try encoder.encode(store.db.todos[0].finding!)
        let countBeforeDelete = store.openCount
        store.selected = id
        store.setDeleted(id, deleted: true)
        precondition(store.openCount == countBeforeDelete - 1 && !store.visible.contains { $0.id == id })
        store.filter = "Trash"
        precondition(store.visible.contains { $0.id == id })
        let beforeDeletedReview = store.usedToday
        store.investigate(id)
        precondition(store.active == nil && store.usedToday == beforeDeletedReview)
        let deletedReload = Store(directory: store.directory, desktop: desktop, startTimer: false)
        precondition(deletedReload.db.todos[0].isDeleted && deletedReload.db.todos[0].finding != nil)
        store.setDeleted(id, deleted: false)
        store.filter = "All open"
        let restoredFinding = try encoder.encode(store.db.todos[0].finding!)
        precondition(restoredFinding == originalFinding && store.openCount == countBeforeDelete)
        store.update(id, done: true)
        store.setDeleted(id, deleted: true)
        store.setDeleted(id, deleted: false)
        precondition(store.db.todos[0].done, "Restoring must preserve completion state")
        store.update(id, done: false)
        print("PASS: delete, Trash filtering/counts, blocked review of deleted items, persisted recovery, evidence and completion preservation")
        let reviewedAt = store.db.todos[0].reviewed
        store.update(id, category: "Auto")
        precondition(store.db.todos[0].categorySelection == "Bug")
        precondition(store.db.todos[0].effectiveCategory == "Bug")
        for category in ["Security", "Validation", "Auto"] {
            store.update(id, category: category)
            let preservedFinding = try encoder.encode(store.db.todos[0].finding!)
            precondition(preservedFinding == originalFinding)
            precondition(store.db.todos[0].reviewed == reviewedAt && !store.db.todos[0].needsReview)
        }
        store.update(id, project: "Auto")
        precondition(store.db.todos[0].projectSelection == project && !store.db.todos[0].needsReview)
        store.update(id, text: store.db.todos[0].text)
        precondition(!store.db.todos[0].needsReview, "Unchanged observation should not mark findings stale")
        store.update(id, text: "changed observation")
        precondition(store.db.todos[0].finding != nil && store.db.todos[0].reviewStale == true)
        let persisted = Store(directory: store.directory, desktop: desktop, startTimer: false)
        precondition(persisted.db.todos[0].finding != nil && persisted.db.todos[0].reviewStale == true)
        store.update(id, project: project)
        store.investigate(id)
        for _ in 0..<100 where store.active != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(!store.db.todos[0].needsReview, "Successful recheck clears the stale flag")
        try script.replacingOccurrences(of: "\"project\":\"\(project)\"", with: "\"project\":\"untrusted-project\"").write(to: stub, atomically: true, encoding: .utf8)
        store.investigate(id)
        for _ in 0..<100 where store.active != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(store.db.todos[0].state == "Failed", "Untrusted classification must be rejected")
        try "#!/bin/zsh\nexec /bin/sleep 20\n".write(to: stub, atomically: true, encoding: .utf8)
        store.investigate(id)
        store.setDeleted(id, deleted: true)
        precondition(!store.db.todos[0].isDeleted)
        store.cancel()
        for _ in 0..<100 where store.active != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(store.active == nil && store.db.todos[0].state == "Failed", "Cancellation must release the queue")
        store.db.preferences.depth = "deep"
        store.db.preferences.allowsWebResearch = false
        try script.replacingOccurrences(of: "web_search=\"live\"", with: "web_search=\"disabled\"").write(to: stub, atomically: true, encoding: .utf8)
        store.investigate(id)
        precondition(store.activeReviewPolicy?.timeoutMinutes == AppConfig.current.deepReviewMinutes)
        for _ in 0..<100 where store.active != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(store.db.todos[0].state == "Reviewed")
        let deepPrompt = try String(contentsOf: root.appendingPathComponent("prompt.txt"))
        precondition(deepPrompt.contains("DEEP investigation") && deepPrompt.contains("Web research is disabled"))
        precondition(!deepPrompt.contains("at most 12"))
        print("PASS: research settings migration/persistence, Quick/Deep policies, live/off web launch flags, prompt privacy boundaries, per-run timeout policy")
        store.db.preferences.effort = "ultra"
        let runsBefore = store.usedToday
        store.investigate(id)
        precondition(store.active == nil && store.usedToday == runsBefore, "Unsupported effort must not launch Codex")
        print("PASS: appearance migration and persistence, font scale limits, model-specific efforts, default model intersection, effort CLI argument, unsupported effort rejection")
        print("PASS: worker sandbox arguments, credential environment exclusion, structured result ingestion, resolved picker values, category-edit preservation, no-op edits, persistence, daily cap, stale-review retention and recheck, output validation, cancellation")
    } catch { fatalError("Worker test failure: \(error)") }
}
