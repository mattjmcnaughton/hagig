# Experimental inference stack: license and attribution inventory

Date: 2026-11-09. Issues [#6](https://github.com/mattjmcnaughton/hagig/issues/6) (licensing track) and [#24](https://github.com/mattjmcnaughton/hagig/issues/24).

This is **evidence collection, not legal clearance or a redistribution decision**.
It covers what the local development bundle (`clients/macos/bundle.sh`) links or
installs at main `3690395`. There is no Hagig release. Nothing here satisfies a
notice obligation; it records which obligations would apply and what is missing.
Security findings are in [AUDIT.md](AUDIT.md); provenance gaps remain open.

`S` = [sherpa-onnx `af2d8d81dbfa61c4cea4c568da78f3982edca005`](https://github.com/k2-fsa/sherpa-onnx/tree/af2d8d81dbfa61c4cea4c568da78f3982edca005), which is tag v2.0.1.

## Native libraries in `Contents/Frameworks`

The source archive is `sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib.tar.bz2` (SHA256 `ac5594ad…f2e3`). According to `S/.github/workflows/macos.yaml` (L67-72, L203-220), it is a universal2 build that was thinned to arm64. The archive ships **no** LICENSE, NOTICE or third-party notice files.

| Component | Version / rev (per `S/cmake`) | License | License text | Notes |
| --- | --- | --- | --- | --- |
| sherpa-onnx core + C API | v2.0.1 | Apache-2.0 | [S/LICENSE](https://github.com/k2-fsa/sherpa-onnx/blob/af2d8d81dbfa61c4cea4c568da78f3982edca005/LICENSE) | No NOTICE file. Some Kaldi-derived sources carry other copyright holders |
| kaldi-native-fbank | v1.22.4 | Apache-2.0 | [LICENSE](https://github.com/csukuangfj/kaldi-native-fbank/blob/v1.22.4/LICENSE) | static |
| kissfft (via kaldi-native-fbank) | `febd4caeed32e33ad8b2e0bb5ea77542c40f18ec` | BSD-3-Clause | [COPYING](https://github.com/mborgerding/kissfft/blob/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec/COPYING) | binary redistribution must reproduce notice |
| kaldi-decoder / kaldifst | v0.3.0 / v1.8.0 | Apache-2.0 | [kaldi-decoder](https://github.com/k2-fsa/kaldi-decoder/blob/v0.3.0/LICENSE), [kaldifst](https://github.com/k2-fsa/kaldifst/blob/v1.8.0/LICENSE) | static |
| OpenFst (csukuangfj fork) | v1.8.5-2026-07-09 | Apache-2.0 | [COPYING](https://github.com/csukuangfj/openfst/blob/v1.8.5-2026-07-09/COPYING) | Version inferred from CMake module order, not a build log |
| simple-sentencepiece | v0.7 | Apache-2.0 | [LICENSE](https://github.com/pkufool/simple-sentencepiece/blob/v0.7/LICENSE) | static |
| utf8proc | v2.12.0 | MIT + Unicode data notice | [LICENSE.md](https://github.com/JuliaStrings/utf8proc/blob/v2.12.0/LICENSE.md) | |
| Eigen (headers compiled in) | 5.0.1 | Mostly MPL-2.0 (some BSD/Apache/MINPACK files) | [COPYING.README](https://gitlab.com/libeigen/eigen/-/blob/5.0.1/COPYING.README) | MPL-2.0 §3.2 source-availability notice applies to binaries; version inferred from CMake order |
| nlohmann/json, hclust-cpp | v3.12.0, tag 2026-02-25 | MIT, BSD-2-Clause (read from text) | [json](https://github.com/nlohmann/json/blob/v3.12.0/LICENSE.MIT), [hclust-cpp](https://github.com/csukuangfj/hclust-cpp/blob/2026-02-25/LICENSE) | hclust included because diarization defaults on |
| ONNX Runtime (`libonnxruntime.dylib`) | 1.28.2; a third-party build by csukuangfj/onnxruntime-libs. The universal2 zip has SHA256 `b5033fb6…0191` per `S/cmake/onnxruntime-osx-universal.cmake` L16-17, not the `onnxruntime-osx-arm64.cmake` zip | MIT + [ThirdPartyNotices](https://github.com/microsoft/onnxruntime/blob/v1.28.2/ThirdPartyNotices.txt) (67 entries, all build flavours) | [LICENSE](https://github.com/microsoft/onnxruntime/blob/v1.28.2/LICENSE) | sherpa's install step copies only the dylib, so the zip's LICENSE/notices are dropped. The build provenance is a third party |

TTS components (espeak-ng, piper, cppjieba), portaudio, websocket and test code
are excluded from the no-TTS C API library according to the S CMake sources.

## Model assets (installed explicitly, not bundled)

| Asset | Revision | License | Obligation / gap |
| --- | --- | --- | --- |
| csukuangfj int8 ONNX encoder/decoder/joiner/tokens | HF `1ab9323565ddb038682214b292f588070a538ce2` | CC-BY-4.0 (card front matter only) | Attribution, license link and a modification notice (conversion/int8) are needed; the card names neither NVIDIA nor the changes |
| NVIDIA parakeet-tdt-0.6b-v2 `.nemo` (tokenizer vocab only) | HF `ae9ad07059c7c739ffaf932226a8fe64ae2620b0` | CC-BY-4.0 ([card L177-179](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/blob/ae9ad07059c7c739ffaf932226a8fe64ae2620b0/README.md)) | Attribution wording must be authored; no copyright/citation line in card |

The installer downloads these from upstream at the user's explicit request.
Whether that counts as Hagig redistributing them is a legal question this
document does not answer.

## Rust crates in the shipped binaries

`cargo tree --locked -e normal,no-proc-macro --target aarch64-apple-darwin` gives 72 crates
shared by `hagig`, `hagig-worker` and `hagig-inference-worker`. The inference
worker adds `sherpa-onnx`/`sherpa-onnx-sys` 2.0.1 (Apache-2.0). Most crates are
`MIT OR Apache-2.0`. The rest:

- **MIT only:** tokio, mio, winnow, simd-adler32, zmij.
- **Other licenses:**
  - ring (`Apache-2.0 AND ISC`);
  - rustls-webpki and untrusted (ISC);
  - webpki-roots (CDLA-Permissive-2.0);
  - subtle (BSD-3-Clause);
  - 15 ICU4X crates (Unicode-3.0);
  - memchr (`Unlicense OR MIT`);
  - miniz_oxide (`MIT OR Zlib OR Apache-2.0`).

Build-only crates, such as the zip/zstd/bzip2/nix closure of sherpa-onnx-sys,
are not shipped.

## Gaps before any redistribution (#24)

1. The bundle has no LICENSE/NOTICE/third-party-notices file, and no
   attribution handling exists anywhere in the repo.
2. Resolved 2026-11-09: Hagig's own source is MIT (`LICENSE`, `backend/Cargo.toml`).
3. The ORT build is third-party. Which ThirdPartyNotices entries apply to this
   macOS/CoreML build, and whether the dylibs correspond to the cited sources, are
   both unverified.
4. Eigen and OpenFst versions are inferred from CMake search order, and the
   Eigen files actually compiled in were not determined.
5. CC-BY-4.0 attribution text for both model cards still has to be written.
6. Linker-level per-binary crate inclusion was not verified.
