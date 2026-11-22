# Recipes for building and running Hagig on an Apple Silicon Mac.
# Pick the Xcode with DEVELOPER_DIR (16.4 or 27.2; see clients/macos/AGENTS.md), e.g.
#   DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer just build

app := "clients/macos/.build/Hagig.app"

[private]
default:
    @just --list

# Build clients/macos/.build/Hagig.app (refuses to overwrite an existing bundle)
build:
    bash clients/macos/bundle.sh build

# Open the built app
open:
    open {{app}}

# Stop the built app's background transcription service
stop:
    {{app}}/Contents/Helpers/hagig stop
