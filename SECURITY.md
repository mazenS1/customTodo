# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through this repository's **Security**
tab using a private vulnerability report. Do not open a public issue containing
credentials, personal data, customer data, internal repository details, or a
working exploit.

Include the affected version, impact, reproduction steps, and any suggested
mitigation. Maintainers should acknowledge a complete report within seven days.

## Operational boundaries

Todo Inbox launches the locally installed Codex CLI for optional source review.
The app uses a read-only sandbox, ignores personal Codex configuration and rules,
passes an allowlisted environment, and validates structured output. These controls
reduce risk but are not an operating-system-level project-only read boundary.

Never put secrets in `Config/AppConfig.plist`: the file is embedded in the built
application and is readable by anyone who can access the bundle.
