---
paths:
  - "Sources/KeyScribe/Adapters/{AudioCapture,CaptureWriter,HALInputUnit,CaptureArchive,CaptureLeftovers,CaptureStartRecord,AudioInputDevices}.swift"
  - "Sources/KeyScribe/CaptureProbeRunner.swift"
  - "Sources/KeyScribeKit/{AudioSampleRing,ChannelSelector,TailDrainGate,ReadinessBudget,EvictionPolicy,CaptureRetention,CaptureProbeScoring}.swift"
  - "Tests/**/{Capture,AudioCapture,AudioSampleRing,ChannelSelector,TailDrainGate,ReadinessBudget,EvictionPolicy,FrugalCapture,IdleEviction}*.swift"
---

You are working in code that touches audio capture. Before editing, open `docs/development/areas/audio-capture.md`, scan its section headings, and read every section that covers the code you are changing. If the change spans more than one section, read the whole guide. Several of its rules fail silently.
