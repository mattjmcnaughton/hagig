# macOS Actions

Follow `clients/macos/AGENTS.md` for commands, evidence gates and limitations.
Keep build/test and the minimal two-Ready-PNG render proof path-filtered in normal
PR CI; no merge or manual dispatch is needed for that first native evidence.
After that proof succeeds, PR CI also renders the bounded representative states
for pre-merge visual inspection. The manual workflow remains an optional rerun.
All screenshots must be synthetic, bounded and short-retained.
No secrets, write token permissions, arbitrary shell
inputs, `pull_request_target`, automatic deployment, or user transcript fixtures.
Owner permission is required before pushes and manual remote dispatches. New
manual workflows must exist on the default branch before GitHub can dispatch them.
