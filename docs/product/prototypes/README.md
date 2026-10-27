# Hagig product prototype

Editable source for the reviewed private-alpha UI concept. This is a browser
simulation, **not the native Hagig application**. It does not use the microphone,
read or write the clipboard, run a model, verify cross-app focus, or paste text.
The Chrome/Amp scene is schematic, not a reproduction of Amp's current UI.

The [MVP PRD](../prds/01-mvp.md) owns requirements; the
[technical design](../../technical/tdds/01-mvp.md) owns implementation choices. Prototype
behavior and sample configuration are not proof of native functionality.

## Build and open

Prerequisites: Node.js 22 or newer and pnpm 12.0.0. Run these commands from this
directory:

```sh
pnpm install --frozen-lockfile
pnpm build
```

Open `dist/index.html` directly in a browser. It is one self-contained file, works
without a server, and makes no runtime network requests. Building/installing does
fetch dependencies. Build-time native scripts are allowed only for esbuild and
Parcel's watcher. `pnpm check` runs TypeScript checking without exporting HTML.

The generated file can be shared independently of the source and dependencies.
Do not commit `dist/`, intermediate bundles, `node_modules/`, screenshots, or
recordings. They are generated artifacts, not the editable design reference.

## Explore

- Switch between Ghostty and Chrome and select each preview state.
- Start recording, simulate release, and simulate the worker result. Check
  "Destination changed / unverified" to reach Copy/Dismiss rather than paste.
- Escape cancels recording, transcription, or fallback in the simulation.
- The inline copy icon changes to a checkmark; it does not modify the clipboard.
- Recording pulses and transcription spins unless reduced motion is enabled.
- Setup previews model, permission, and worker failure states.
- TOML/YAML examples can be downloaded. TOML is the proposed app format; showing
  YAML here does not commit the product to a second parser.

All interaction state is in memory and resets on reload. The download controls
save only the illustrative configuration selected by the reader.

## Source map

- `app.tsx`: scenes, state transitions, icons, and sample configuration.
- `style.css`: responsive presentation and reduced-motion-aware animation.
- `embed.mjs`: embeds compiled JS/CSS into the standalone HTML export.
- `package.json`, `pnpm-lock.yaml`, `tsconfig.json`: pinned build inputs and checks.

To check a revision, build the exported file and open it with networking blocked.
Exercise both destinations, recording/transcribing, changed-destination fallback,
copy feedback, Escape/Dismiss, setup variants, and both config downloads. Inspect
wide/narrow layouts and reduced-motion behavior. These checks validate only the
prototype, not the PRD's macOS acceptance criteria.
