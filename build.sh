#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"

# A local config is selected automatically when present. Contributors can also point
# APP_CONFIG_PATH at another plist for one build. The selected file is embedded in the
# app and therefore must contain public settings only—never credentials or private data.
if [[ -n "${APP_CONFIG_PATH:-}" ]]; then
  config_file="$APP_CONFIG_PATH"
elif [[ -f "Config/AppConfig.plist" ]]; then
  config_file="Config/AppConfig.plist"
else
  config_file="Config/AppConfig.example.plist"
fi
[[ -f "$config_file" ]] || { print -u2 -- "Configuration not found: $config_file"; exit 1; }
config_file="${config_file:A}"
plutil -lint -- "$config_file" >/dev/null

config_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$config_file"
}

app_name="$(config_value AppName)"
bundle_identifier="$(config_value BundleIdentifier)"
bundle_version="$(config_value BundleVersion)"
executable_name="$(config_value ExecutableName)"
marketing_version="$(config_value MarketingVersion)"
minimum_system_version="$(config_value MinimumSystemVersion)"

# These values become path components or code-signing metadata. Reject separators and
# metacharacters before any cleanup command can use them, even for a malicious config.
[[ "$app_name" =~ '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$' && "$app_name" != *..* ]] || {
  print -u2 -- "AppName contains unsupported characters."; exit 1
}
[[ "$executable_name" =~ '^[A-Za-z0-9_-]+$' ]] || {
  print -u2 -- "ExecutableName contains unsupported characters."; exit 1
}
[[ "$bundle_identifier" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || {
  print -u2 -- "BundleIdentifier is malformed."; exit 1
}

# Build in isolated temporary directories so a failed compile cannot leave a partially
# signed application at the public output path. The traps only remove mktemp-created paths.
build_work="$(mktemp -d)"
bundle_work="$(mktemp -d)"
trap 'rm -r -- "$build_work" "$bundle_work"' EXIT

sources=(Source/AppConfig.swift Source/Core.swift Source/App.swift)
test_executable="$build_work/TodoInboxTests"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -DSELF_TESTS \
  -target arm64-apple-macosx14.0 $sources Source/Tests.swift -o "$test_executable"
TODO_INBOX_TEST_CONFIG="$config_file" "$test_executable" --self-test

app="$bundle_work/$app_name.app"
macos_directory="$app/Contents/MacOS"
resources_directory="$app/Contents/Resources"
mkdir -p "$macos_directory" "$resources_directory"

# No dependency downloads or third-party runtime: compile against the local macOS SDK.
# Size optimization and dead stripping keep the menu-bar process lightweight while the
# test-only symbols above remain entirely outside the shipped executable.
xcrun swiftc -swift-version 5 -Osize -whole-module-optimization -Xlinker -dead_strip \
  -target arm64-apple-macosx14.0 $sources -o "$macos_directory/$executable_name"
cp -- "$config_file" "$resources_directory/AppConfig.plist"

info_plist="$app/Contents/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleExecutable -string "$executable_name" "$info_plist"
plutil -insert CFBundleIdentifier -string "$bundle_identifier" "$info_plist"
plutil -insert CFBundleName -string "$app_name" "$info_plist"
plutil -insert CFBundleDisplayName -string "$app_name" "$info_plist"
plutil -insert CFBundleIconFile -string AppIcon "$info_plist"
plutil -insert CFBundleVersion -string "$bundle_version" "$info_plist"
plutil -insert CFBundleShortVersionString -string "$marketing_version" "$info_plist"
plutil -insert LSMinimumSystemVersion -string "$minimum_system_version" "$info_plist"
plutil -insert LSUIElement -bool true "$info_plist"
plutil -insert NSHighResolutionCapable -bool true "$info_plist"
plutil -insert NSDesktopFolderUsageDescription -string \
  "Discover configured development projects and import todo files." "$info_plist"

icon_work="$build_work/icon"
mkdir -p "$icon_work"
xcrun swiftc Source/Icon.swift -framework AppKit -o "$icon_work/draw-icon"
"$icon_work/draw-icon" "$icon_work/AppIcon.iconset"
iconutil -c icns "$icon_work/AppIcon.iconset" -o "$resources_directory/AppIcon.icns"

# Ad-hoc signing is suitable for local development builds. Public distribution still
# requires the maintainer's Developer ID signature and Apple's notarization process.
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

output_directory="$PWD/build"
output_app="$output_directory/$app_name.app"
mkdir -p "$output_directory"
if [[ -e "$output_app" ]]; then rm -r -- "$output_app"; fi
mv -- "$app" "$output_app"
print -- "Built and verified: $output_app"
