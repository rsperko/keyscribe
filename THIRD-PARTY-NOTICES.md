# Third-Party Notices

KeyScribe is licensed under the GNU General Public License v3.0 (see `LICENSE`). It incorporates
the third-party source and binary components below, and downloads speech-recognition and supporting
model weights at runtime. Each remains under its own license.

## Bundled software libraries

| Component | Project | License |
|---|---|---|
| FluidAudio (Parakeet engine) | github.com/FluidInference/FluidAudio | Apache-2.0 |
| WhisperKit (Whisper engine) | github.com/argmaxinc/WhisperKit (KeyScribe fork of argmax-oss-swift) | MIT |
| speech-swift / Qwen3ASR (Qwen3-ASR engine) | github.com/soniqo/speech-swift (KeyScribe fork) | Apache-2.0 |
| moonshine-swift (Swift wrapper) | github.com/moonshine-ai/moonshine-swift | MIT |
| Moonshine engine (prebuilt Moonshine.xcframework) | github.com/moonshine-ai/moonshine | MIT, plus the upstream third-party terms |
| ONNX Runtime (statically linked into Moonshine.xcframework) | github.com/microsoft/onnxruntime | MIT, plus the ONNX Runtime third-party notices |
| MLX Swift | github.com/ml-explore/mlx-swift | MIT |
| swift-transformers | github.com/huggingface/swift-transformers | Apache-2.0 |
| swift-huggingface | github.com/huggingface/swift-huggingface | Apache-2.0 |
| swift-jinja | github.com/huggingface/swift-jinja | Apache-2.0 |
| TOMLKit | github.com/LebJe/TOMLKit | MIT |
| yyjson | github.com/ibireme/yyjson | MIT |
| EventSource | github.com/mattt/EventSource | MIT |
| swift-numerics, swift-collections, swift-system, swift-atomics, swift-argument-parser, swift-asn1, swift-crypto, swift-nio | github.com/apple, github.com/swift-server | Apache-2.0 |
| Sparkle (public production builds only) | github.com/sparkle-project/Sparkle | MIT, plus the notices reproduced in Sparkle's `LICENSE` |

## Downloaded model weights

Model weights are fetched on demand and are **not** part of this application's source. Each is
the property of its publisher and is used under its own license.

| Model | Publisher | License |
|---|---|---|
| Parakeet TDT v3 / Parakeet TDT-CTC 110M | NVIDIA | CC-BY-4.0 |
| pyannote segmentation/speaker models (via FluidAudio) | pyannote | CC-BY-4.0 |
| Silero VAD Core ML (speech-presence detection) | Silero Team; Core ML conversion by Fluid Inference | MIT |
| Whisper Large v3 Turbo / Whisper Small (English) | OpenAI | MIT |
| Qwen3-ASR 0.6B / 1.7B | Alibaba Cloud (Qwen) | Apache-2.0 |
| Moonshine Base (English) | Moonshine AI | MIT |
| Apple on-device speech (`DictationTranscriber`) | Apple | macOS system framework — no separate distribution |

> The Moonshine **English** models are MIT-licensed; Moonshine's non-English models carry the
> separate non-commercial Moonshine Community License. KeyScribe offers only the English model.

Binary distributions include `LICENSE`, this file, and the license or notice files supplied by
resolved dependencies in the app bundle. Complete terms are also published by the projects linked
above. The Moonshine and Sparkle entries identify their prebuilt binary contents separately because a
wrapper package's license does not replace the notices for code incorporated into its binary artifact.
