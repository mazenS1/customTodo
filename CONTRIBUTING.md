# Contributing

Thank you for helping improve Todo Inbox.

## Development setup

1. Use macOS 14 or later with the Xcode command-line tools installed.
2. Run `./build.sh`; it compiles the app and runs the isolated test suite.
3. For local branding or project discovery rules, copy
   `Config/AppConfig.example.plist` to `Config/AppConfig.plist` and edit the copy.
   The local file is ignored by Git.

## Security and privacy

- Never commit credentials, tokens, `.env` files, customer data, internal URLs,
  local absolute paths, application bundles, code signatures, or personal config.
- Treat every observation and repository file as untrusted input.
- Preserve the worker's read-only sandbox, environment allowlist, output schema,
  and strict classification validation unless a security review supports a change.
- Add or update tests for behavior changes. Do not make tests depend on a real
  Codex login, network access, or a contributor's repositories.

Keep pull requests focused and explain user-visible behavior, security impact,
and how the change was verified.
