# Todo Inbox

Todo Inbox is a native macOS menu-bar app for capturing development observations
and investigating them later with the locally installed Codex CLI. It includes a
quick-capture popover, a searchable desktop inbox, optional automatic reviews,
soft deletion, and one-time import from project todo files.

The project has no third-party runtime dependencies. It targets Apple Silicon and
macOS 14 or later.

## Privacy and security model

Observations and findings are stored locally as JSON. A review sends the selected
observation and relevant source context to OpenAI through the user's existing Codex
CLI authentication; local storage does not mean local inference.

The review worker:

- launches Codex directly without a shell and passes the observation on standard input;
- requests a read-only sandbox with approval escalation disabled;
- ignores the user's Codex configuration and rules, and disables apps and sub-agents;
- forwards a small environment allowlist instead of inherited tokens or credentials;
- validates the final response against a strict JSON schema and classification allowlists;
- discards tool transcripts and retains only the final structured finding.

These controls reduce exposure, but the Codex read-only sandbox is not an operating-
system-level project-only filesystem boundary. Project and sensitive-file exclusions
also rely on worker instructions. Review the code and configuration before using the
app with confidential repositories. Web research can be disabled in Settings.

## Build

Install the Xcode command-line tools, then run:

```sh
./build.sh
```

The script validates configuration, runs isolated tests, builds the application,
generates its icon, applies an ad-hoc local signature, verifies that signature, and
writes `build/Todo Inbox.app`. Tests use a stub worker and do not invoke a real Codex
session, access the network, or inspect the contributor's repositories.

The generated app is suitable for local development. Public binary distribution
requires a Developer ID signature and Apple notarization.

## Configuration

Public-safe defaults live in `Config/AppConfig.example.plist`. To customize a local
build, copy that file to `Config/AppConfig.plist` and edit the copy:

```sh
cp Config/AppConfig.example.plist Config/AppConfig.plist
```

The local file is ignored by Git. Alternatively, set `APP_CONFIG_PATH` for one build:

```sh
APP_CONFIG_PATH=/absolute/path/to/AppConfig.plist ./build.sh
```

Configuration controls branding, bundle metadata, storage directory, project root and
folder prefix, legacy todo filename, default Codex executable, review limits and
timeouts, and classification categories. The selected plist is copied into the app
bundle and is readable by anyone with access to it. Never place passwords, API keys,
tokens, customer data, private URLs, or other secrets in configuration.

By default, projects are real, non-symlink directories directly under `~/Desktop`
whose names start with `project-`. Change `ProjectRootPath` and
`ProjectDirectoryPrefix` in local configuration to match your layout. Each discovered
project may contain multiple repositories.

## Workflow

1. Click the menu-bar icon, enter an observation, optionally choose a project and
   category, and press **Capture** or ⌘Return.
2. Open the full inbox to search, filter, edit, complete, delete, or restore items.
3. Select **Investigate** to request a read-only Codex assessment with severity,
   confidence, evidence, a next step, and explicit limitations.
4. Recheck an item after its observation, selected project, or source code changes.

Automatic investigation is disabled initially. When enabled, eligible new captures
are reviewed serially after a short delay, with starts at least 60 seconds apart and a
configurable daily run limit. Imported backlog items always require a manual review.

Quick and deep review modes have configurable timeouts. The model and reasoning effort
can be selected from the local Codex model cache. The app must remain running and the
Mac must remain awake for queued work to continue.

## Local data

The default database is stored at:

```text
~/Library/Application Support/Todo Inbox/inbox.json
```

The directory is created with mode `0700`; the database and backup use mode `0600`.
Writes are atomic, and the previous saved version is retained as `inbox.backup.json`.
The data is not additionally encrypted by the app. Quit the app before manually
restoring a backup.

At launch, the app can import dash-prefixed entries from the configured legacy todo
filename in each discovered project. Multiline entries and completed markers are
preserved. Import is one-time per source path and never rewrites or deletes the source.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and privacy expectations and
[SECURITY.md](SECURITY.md) for private vulnerability reporting. Todo Inbox is available
under the [MIT License](LICENSE).
