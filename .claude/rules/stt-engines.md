---
paths:
  - "Sources/KeyScribe/Adapters/{*Engine,EngineRegistry,EngineErrors,SpeechPresenceDetector,AudioDecoder}.swift"
  - "Sources/KeyScribe/{BenchmarkRunner,VadProbeRunner,InstalledEngineFilter}.swift"
  - "Sources/KeyScribe/Settings/SpeechModel*.swift"
  - "Sources/KeyScribeKit/{SpeechModelCatalog,SpeechModelSet,SpeechEngine,SerializedEngine,SpeechPresenceGate,LeadingSilenceTrim,AppleSpeechModelChoice,StreamingDictationDriver,StreamingStartPolicy,Qwen3OutputBudget,FuzzyCorrector,Benchmark*}.swift"
  - "Tests/**/{SpeechModel,SpeechPresence,SpeechEngine,LeadingSilence,AppleSpeech,Streaming,Parakeet,Whisper,Qwen3,EngineInstall,EngineRegistry,Benchmark,BiasBenchmark,FuzzyCorrector}*.swift"
  - "corpus/**"
---

You are working in code that touches speech-to-text engines. Before editing, open `docs/development/areas/stt-engines.md`, scan its section headings, and read every section that covers the code you are changing. If the change spans more than one section, read the whole guide. Several of its rules fail silently.
