import React, { useState, useEffect } from "react";
import { createRoot } from "react-dom/client";

type Stage =
  | "Ready"
  | "Recording"
  | "Transcribing"
  | "Fallback"
  | "Paste requested"
  | "Cancelled"
  | "Setup";
const stages: Stage[] = [
  "Ready",
  "Recording",
  "Transcribing",
  "Fallback",
  "Paste requested",
  "Cancelled",
  "Setup",
];
const prompt =
  "Add a timeout to the inference worker and cover cancellation with a regression test.";
const toml = `# Proposed schema — not implemented. Example values, not model pins.
# $XDG_CONFIG_HOME/hagig/config.toml
# Default: ~/.config/hagig/config.toml (also on macOS)

[shortcut]
hold = "ctrl+shift+space" # Example; conflict-check on your Mac

[model]
id = "parakeet-tdt-0.6b-v2" # Candidate; subject to spike

[vocabulary]
terms = ["Hagig", "Ghostty", "sherpa-onnx", "Parakeet", "Amp"]`;
const yaml = `# Alternative representation only; YAML support is NOT proposed.
# Same illustrative settings as the recommended TOML.
shortcut:
  hold: "ctrl+shift+space"

model:
  id: "parakeet-tdt-0.6b-v2"

vocabulary:
  terms:
    - "Hagig"
    - "Ghostty"
    - "sherpa-onnx"
    - "Parakeet"
    - "Amp"`;

function Mic() {
  return (
    <svg
      width="22"
      height="22"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      aria-hidden="true"
    >
      <rect x="8" y="2" width="8" height="13" rx="4" />
      <path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" />
    </svg>
  );
}
function CopyIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      aria-hidden="true"
    >
      <rect x="8" y="8" width="12" height="13" rx="2" />
      <path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3" />
    </svg>
  );
}
function App() {
  const [stage, setStage] = useState<Stage>("Ready");
  const [target, setTarget] = useState("Ghostty");
  const [changed, setChanged] = useState(false);
  const [copied, setCopied] = useState(false);
  const [format, setFormat] = useState("TOML");
  const [setup, setSetup] = useState("Model missing");
  function go(s: Stage) {
    setStage(s);
    setCopied(false);
  }
  useEffect(() => {
    function cancel(e: KeyboardEvent) {
      if (
        e.key === "Escape" &&
        ["Recording", "Transcribing", "Fallback"].includes(stage)
      )
        go("Cancelled");
    }
    window.addEventListener("keydown", cancel);
    return () => window.removeEventListener("keydown", cancel);
  }, [stage]);
  function download() {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(
      new Blob([format === "TOML" ? toml : yaml], { type: "text/plain" }),
    );
    a.download =
      format === "TOML" ? "hagig.example.toml" : "hagig.alternative.yaml";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  const descriptions: Record<Stage, string> = {
    Ready:
      "Hold the shortcut in your intended input. Hagig stays in the menu bar; there is no main app window to manage.",
    Recording:
      "Capture only. No live transcript is proposed. Release the shortcut to transcribe, or press Escape to discard.",
    Transcribing:
      "The worker transcribes locally. Your warm-path goal is ≤2 seconds after release for a 15–30-second prompt; this demo does not measure it.",
    Fallback:
      "The intended input changed or could not be verified. Do not switch focus or write the clipboard automatically. Offer Copy and Dismiss.",
    "Paste requested":
      "Request paste only into the verified, still-focused input. Never press Enter. “Requested” is not a universal acknowledgment from the target app.",
    Cancelled:
      "Discard this request. A late inference result must not display, copy, or paste. Cancellation cannot undo delivery already initiated.",
    Setup:
      "Show a specific recovery path. Never silently download a missing model. Permissions and model installation are distinct setup steps.",
  };
  return (
    <main className="mx-auto max-w-6xl px-6 py-10">
      <header id="intro">
        <div className="brand">
          <span className="mark">
            <Mic />
          </span>
          <strong>hagig</strong>
          <span className="badge">Private alpha concept · v3</span>
        </div>
        <h1>
          Think aloud.
          <br />
          Keep coding.
        </h1>
        <p className="lead">
          A small voice-to-text companion for Ghostty and Chrome.
          <br />
          Your prompt lands in the input. You decide when to send.
        </p>
        <p className="disclaimer">
          Interactive simulation, not a macOS app. No microphone, clipboard,
          model download, or cross-app access.
        </p>
      </header>
      <section id="prototype" aria-labelledby="preview-title">
        <div className="section-heading">
          <h2 id="preview-title">The menu-bar experience</h2>
          <div className="segmented" aria-label="Simulated destination">
            {["Ghostty", "Chrome"].map((t) => (
              <button
                key={t}
                aria-pressed={target === t}
                onClick={() => {
                  setTarget(t);
                  go("Ready");
                }}
              >
                {t}
              </button>
            ))}
          </div>
        </div>
        <div className="states" aria-label="Preview state">
          {stages.map((s) => (
            <button
              id={"state-" + s.toLowerCase().replaceAll(" ", "-")}
              key={s}
              aria-pressed={stage === s}
              onClick={() => go(s)}
            >
              {s}
            </button>
          ))}
        </div>
        <figure id="fig-desktop">
          <div className="desktop">
            <div className="menubar">
              <span>
                ◈ &nbsp; <b>{target}</b>
                <span className="desktop-only">
                  {" "}
                  &nbsp; File &nbsp; Edit &nbsp; View
                </span>
              </span>
              <span className="menu-end">
                <span
                  className={
                    "menu-mic " + (stage === "Recording" ? "active" : "")
                  }
                >
                  <Mic />
                </span>{" "}
                Mon 10:24
              </span>
            </div>
            <div
              className={
                "destination " + (target === "Chrome" ? "chrome" : "terminal")
              }
            >
              <div className="windowbar">
                <span className="traffic">● ● ●</span>
                <span>
                  {target === "Ghostty"
                    ? "hagig — agent prompt"
                    : "ampcode.com — prompt composer (schematic)"}
                </span>
              </div>
              {target === "Ghostty" ? (
                <div className="terminal-body">
                  <div className="terminal-muted">
                    ~/projects/hagig &nbsp; main
                  </div>
                  <p>What would you like to build?</p>
                  <div className="terminal-input">
                    ❯{" "}
                    {stage === "Paste requested" ? (
                      prompt
                    ) : (
                      <span className="caret">▎</span>
                    )}
                  </div>
                  <div className="terminal-muted terminal-bottom">
                    {stage === "Paste requested"
                      ? "Sample text inserted in this mock input. Not submitted."
                      : "Your terminal keeps the focus."}
                  </div>
                </div>
              ) : (
                <div className="browser-body">
                  <div className="browser-address">ampcode.com</div>
                  <h3>What are we building?</h3>
                  <div className="composer">
                    {stage === "Paste requested" ? (
                      prompt
                    ) : (
                      <span className="placeholder">Describe a task…</span>
                    )}
                    <div className="composer-foot">
                      Prompt composer <span>Not submitted</span>
                    </div>
                  </div>
                  <p className="mock-label">
                    Schematic destination, not a reproduction of Amp’s current
                    UI.
                  </p>
                </div>
              )}
            </div>
            <div className="popover" aria-label="Hagig simulated popover">
              <div className="popover-brand">
                <Mic />
                <strong>Hagig</strong>
                <span>Parakeet · English</span>
              </div>
              <div className="popover-content" aria-live="polite">
                <span
                  className={
                    "status-dot " +
                    (stage === "Fallback" || stage === "Setup" ? "warning" : "")
                  }
                />
                <h3>
                  {
                    {
                      Ready: "Ready when you are",
                      Recording: "Listening…",
                      Transcribing: "Transcribing…",
                      Fallback: "Destination changed",
                      "Paste requested": "Paste requested",
                      Cancelled: "Cancelled",
                      Setup: setup,
                    }[stage]
                  }
                </h3>
                {stage === "Ready" && (
                  <>
                    <p>Hold your shortcut and speak into the focused input.</p>
                    <div className="keys">
                      <kbd>⌃</kbd>
                      <kbd>⇧</kbd>
                      <kbd>Space</kbd>
                    </div>
                    <small>Example shortcut · configurable in TOML</small>
                    <button
                      className="primary"
                      id="begin"
                      onClick={() => go("Recording")}
                    >
                      Simulate recording
                    </button>
                  </>
                )}
                {stage === "Recording" && (
                  <>
                    <p>
                      Release the shortcut to transcribe.
                      <br />
                      Escape cancels and discards the audio.
                    </p>
                    <div className="capture">
                      <span
                        className="capture-dot recording-pulse"
                        aria-hidden="true"
                      />
                      Microphone capture <span>Demo</span>
                    </div>
                    <button
                      className="primary"
                      id="release"
                      onClick={() => go("Transcribing")}
                    >
                      Simulate release
                    </button>
                    <button className="quiet" onClick={() => go("Cancelled")}>
                      Cancel
                    </button>
                  </>
                )}
                {stage === "Transcribing" && (
                  <>
                    <p>
                      Turning your recording into text.
                      <br />
                      Nothing has been delivered.
                    </p>
                    <div className="capture">
                      <span
                        className="transcription-spinner"
                        aria-hidden="true"
                      />
                      Processing audio <span>Demo</span>
                    </div>
                    <label className="check">
                      <input
                        id="changed"
                        type="checkbox"
                        checked={changed}
                        onChange={(e) => setChanged(e.target.checked)}
                      />{" "}
                      Destination changed / unverified
                    </label>
                    <button
                      className="primary"
                      id="finish"
                      onClick={() =>
                        go(changed ? "Fallback" : "Paste requested")
                      }
                    >
                      Simulate worker result
                    </button>
                    <button className="quiet" onClick={() => go("Cancelled")}>
                      Cancel
                    </button>
                  </>
                )}
                {stage === "Fallback" && (
                  <>
                    <p className="warn-text">
                      Nothing pasted. Copy the text, then choose where to paste
                      it.
                    </p>
                    <blockquote className="transcript">
                      {prompt}
                      <button
                        className="copy-icon"
                        id="copy"
                        aria-label={
                          copied ? "Copy simulated" : "Copy transcript"
                        }
                        title={copied ? "Copy simulated" : "Copy transcript"}
                        onClick={() => setCopied(true)}
                      >
                        {copied ? (
                          <svg
                            width="18"
                            height="18"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            strokeWidth="2"
                            aria-hidden="true"
                          >
                            <path d="m5 12 4 4L19 6" />
                          </svg>
                        ) : (
                          <CopyIcon />
                        )}
                      </button>
                    </blockquote>
                    <button
                      className="quiet"
                      id="dismiss"
                      onClick={() => go("Ready")}
                    >
                      Dismiss
                    </button>
                  </>
                )}
                {stage === "Paste requested" && (
                  <>
                    <p>
                      Paste requested in {target}.<br />
                      Review your prompt before sending.
                    </p>
                    <small>
                      Demo only: no real paste or focus check occurred.
                    </small>
                    <button className="primary" onClick={() => go("Ready")}>
                      Back to ready
                    </button>
                  </>
                )}
                {stage === "Cancelled" && (
                  <>
                    <p>
                      This request was discarded.
                      <br />
                      Nothing will be delivered from it.
                    </p>
                    <button className="primary" onClick={() => go("Ready")}>
                      Back to ready
                    </button>
                  </>
                )}
                {stage === "Setup" && (
                  <>
                    <div className="setup-select">
                      <label htmlFor="setup-kind">Preview issue</label>
                      <select
                        id="setup-kind"
                        value={setup}
                        onChange={(e) => setSetup(e.target.value)}
                      >
                        <option>Model missing</option>
                        <option>Microphone permission needed</option>
                        <option>Accessibility permission needed</option>
                        <option>Worker stopped unexpectedly</option>
                      </select>
                    </div>
                    <p>
                      {setup === "Model missing"
                        ? "Install the model explicitly using the documented setup command. No download starts here."
                        : setup === "Worker stopped unexpectedly"
                          ? "Transcription failed. Nothing delivered. Start a new recording to retry."
                          : "In the app, use macOS System Settings to grant access. This demo requests no permissions."}
                    </p>
                    <button className="primary" onClick={() => go("Ready")}>
                      Simulate recovery
                    </button>
                  </>
                )}
              </div>
              <div className="popover-footer">
                No app-maintained transcript history
              </div>
            </div>
          </div>
          <figcaption id="state-explanation">
            <b>{stage}.</b> {descriptions[stage]}
          </figcaption>
        </figure>
        <div id="privacy-boundaries" className="notes">
          <p>
            <b>F1 · Keep the surface small.</b> The popover makes states legible
            here. Whether recording feedback can stay visible without taking
            focus is a native spike question.
          </p>
          <p>
            <b>R1 · Delivery safety is not proven.</b> Ghostty pane/tab and
            Chrome input changes must be checked on your Mac. Clipboard writes
            must disable Universal Clipboard sharing; local clipboard managers
            and destination apps can still retain or transmit text.
          </p>
        </div>
      </section>
      <section id="configuration" aria-labelledby="config-title">
        <div className="section-heading">
          <div>
            <h2 id="config-title">A file, not a settings app.</h2>
            <p>
              Proposed schema. TOML is the working choice; no parser exists yet.
            </p>
          </div>
          <div className="segmented" aria-label="Configuration format">
            {["TOML", "YAML"].map((f) => (
              <button
                id={"format-" + f.toLowerCase()}
                key={f}
                aria-pressed={format === f}
                onClick={() => setFormat(f)}
              >
                {f}
              </button>
            ))}
          </div>
        </div>
        <div className="config-layout">
          <div>
            <pre id="config-code">
              <code>{format === "TOML" ? toml : yaml}</code>
            </pre>
            <button id="download" onClick={download}>
              Download example {format}
            </button>
          </div>
          <aside id="config-decisions">
            <h3>What belongs here</h3>
            <p>
              <b>Shortcut.</b> A hold-to-record binding, checked for conflicts
              on your Mac.
            </p>
            <p>
              <b>Model.</b> One candidate configuration, not an engine plugin
              system. Revision and assets will be pinned in the technical design
              after validation.
            </p>
            <p>
              <b>Vocabulary.</b> Project names and technical terms. Boost
              strength waits for measurements.
            </p>
            <h3>What is not a toggle</h3>
            <p>
              No automatic submission, no silent downloads, and no default
              content history are commitments—not settings to disable.
            </p>
            <p>
              Recording is capped at five minutes. Clipboard cleanup remains
              deferred.
            </p>
          </aside>
        </div>
      </section>
      <footer id="scope">
        <p id="change-animations">
          What changed in v2: recording pulses; transcription uses an
          indeterminate spinner. Both respect reduced motion. These show
          activity, not audio levels or progress.
        </p>
        <p id="change-popover">
          What changed in v3: inline copy icon, Parakeet label, and fewer
          explanatory notes inside the popover. The five-minute recording cap
          and pre-limit warning remain requirements.
        </p>
        Design reference only · M4 / 48 GB / macOS Sequoia 15.7.3 acceptance
        target · No performance or privacy validation implied.
      </footer>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
