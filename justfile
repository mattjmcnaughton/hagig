# Recipes for building, installing and removing Hagig on an Apple Silicon Mac.
# Pick the Xcode with DEVELOPER_DIR (16.4 or 27.2; see clients/macos/AGENTS.md), e.g.
#   DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer just build
# Install somewhere other than ~/Applications with HAGIG_INSTALL_DIR, e.g.
#   HAGIG_INSTALL_DIR=/Applications just install

build_app := "clients/macos/.build/Hagig.app"
previous_app := "clients/macos/.build/Hagig.previous.app"
install_dir := env("HAGIG_INSTALL_DIR", home_directory() / "Applications")
app := install_dir / "Hagig.app"
bundle_id := "com.mattjmcnaughton.hagig"

[private]
default:
    @just --list

# Build clients/macos/.build/Hagig.app (refuses to overwrite an existing build)
build:
    bash clients/macos/bundle.sh build

# Move the build to ~/Applications/Hagig.app (the previous one is kept in .build) and open it
install: _quit
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{build_app}}" ]; then
        echo "No build at {{build_app}}; run 'just build' first." >&2
        exit 1
    fi
    codesign --verify --deep --strict "{{build_app}}"
    mkdir -p "{{install_dir}}"
    if [ -L "{{app}}" ]; then
        echo "{{app}} is a symlink; remove it first." >&2
        exit 1
    fi
    if [ -e "{{app}}" ]; then
        # Keep the replaced app for rollback; only one previous copy is kept.
        rm -rf "{{previous_app}}"
        mv "{{app}}" "{{previous_app}}"
    fi
    mv "{{build_app}}" "{{app}}"
    echo "Installed {{app}}"
    open "{{app}}"

# Open the installed app
open:
    open "{{app}}"

# Stop the background transcription service (the app starts it again on the next recording)
stop:
    "{{app}}/Contents/Helpers/hagig" stop

# Open the folder holding app.log and server.log (content-free) in Finder
logs:
    #!/usr/bin/env bash
    set -euo pipefail
    state="${XDG_STATE_HOME:-}"
    # Relative XDG values are ignored, as the backend does.
    case "$state" in /*) ;; *) state="$HOME/.local/state" ;; esac
    folder="$state/hagig/logs"
    if [ ! -d "$folder" ]; then
        echo "No logs yet at $folder; they appear once Hagig has run." >&2
        exit 1
    fi
    open "$folder"

# Remove Hagig: turn off its login item, then delete the app, settings, models, logs, runtime files and microphone access
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    helper=""
    for candidate in "{{app}}" "{{build_app}}" "{{previous_app}}"; do
        if [ -x "$candidate/Contents/Helpers/hagig" ]; then
            helper="$candidate/Contents/Helpers/hagig"
            break
        fi
    done
    if [ -z "$helper" ]; then
        echo "No Hagig app found at {{app}} or in clients/macos/.build." >&2
        exit 1
    fi
    echo "This quits Hagig and permanently removes:"
    for candidate in "{{app}}" "{{build_app}}" "{{previous_app}}"; do
        if [ -e "$candidate" ]; then echo "  $candidate"; fi
    done
    echo "  its login item and microphone access"
    echo "  settings, models, logs and runtime files:"
    "$helper" uninstall < /dev/null 2>/dev/null | sed -n 's/^  /    /p' || true
    read -r -p "Continue? [y/N] " answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        echo "Nothing was removed."
        exit 0
    fi
    # Only the app itself can remove its login item.
    for candidate in "{{app}}" "{{build_app}}" "{{previous_app}}"; do
        if [ -x "$candidate/Contents/MacOS/HagigShell" ]; then
            "$candidate/Contents/MacOS/HagigShell" --unregister-login-item
            break
        fi
    done
    pkill -x HagigShell || true
    while pgrep -x HagigShell > /dev/null; do sleep 0.2; done
    # Stops the service, then removes settings, models, logs and runtime files.
    "$helper" uninstall --yes > /dev/null
    # Before deleting the app: tccutil resolves the bundle ID through it.
    if ! tccutil reset Microphone {{bundle_id}} > /dev/null 2>&1; then
        echo "Could not reset microphone access; remove Hagig under Privacy & Security > Microphone." >&2
    fi
    rm -rf "{{app}}" "{{build_app}}" "{{previous_app}}"
    echo "Hagig is uninstalled. The clone and uv's download cache are left alone."

# Quit the app and stop its service, so a bundle is never replaced under them
[private]
_quit:
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -x HagigShell || true
    while pgrep -x HagigShell > /dev/null; do sleep 0.2; done
    for candidate in "{{app}}" "{{build_app}}"; do
        if [ -x "$candidate/Contents/Helpers/hagig" ]; then
            "$candidate/Contents/Helpers/hagig" stop
            break
        fi
    done
