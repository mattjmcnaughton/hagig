# Exploratory spikes

Spikes preserve bounded experiments, reproducible recipes, and reviewed evidence.
They are nonproduction code, not supported application interfaces or approval to
adopt dependencies, models, installers, or security boundaries. Negative results
and limitations belong beside positive findings. Production code must not depend
on these packages.

- [Inference S1](inference-s1/README.md): pinned Linux inference/vocabulary and
  isolated-worker experiments; see its [preservation review](inference-s1/REVIEW.md).

Keep models, native binaries, generated audio, build outputs, personal content,
and raw native diagnostics out of Git. Recipes use explicit acquisition and
synthetic/public inputs; additional tools still require repository approval.
