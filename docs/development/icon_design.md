# KeyScribe — Icon Design Brief

> The app icon and menu-bar glyph should communicate speech becoming precise text. This brief
> governs future vector and asset creation.

---

## 1. Chosen concept

**A waveform resolving into a text cursor.**

The left side is a compact, controlled speech waveform. Its strokes settle into one vertical,
cursor-like line at the right. The mark communicates KeyScribe’s actual value: spoken input is
turned into usable writing.

This is preferable to a microphone because the product is not an audio recorder. It is also
more specific than generic sparkles or an abstract assistant symbol.

## 2. Form language

- Build from a small number of rounded, monoline strokes with deliberate variation in waveform
  height.
- Use a stable baseline or implied reading direction from left to right.
- The final cursor stroke is straight, calm, and optically centered—not a literal text caret.
- The waveform should look measured rather than loud: three to five peaks are sufficient.
- At small size, the waveform must simplify before the cursor relationship disappears.

The symbol should read in this order: voice signal, transformation, writing. It should not need
the app name to be understood.

## 3. Asset system

### macOS app icon

- Use a simple high-contrast mark on a restrained, nearly flat field.
- The background may use a subtle depth treatment permitted by current macOS icon conventions,
  but the mark must remain recognizable without it.
- Produce all required macOS icon sizes from a vector master; inspect the smallest rendered
  variants manually.
- Do not rely on thin details, tiny text lines, or color-only distinctions.

### Menu-bar glyph

- Use a monochrome template image derived from the same concept, not a miniature app icon.
- Prefer the waveform/cursor silhouette without a background container.
- It must remain legible at normal and compact menu-bar sizes, in light and dark appearances.
- Active recording and processing state are expressed by the HUD and a restrained transient
  status treatment, not by replacing the mark with an unrelated microphone or spinner.

### In-app symbol

- The same mark may appear in onboarding, empty states, and About.
- Use SF Symbols for ordinary UI actions. The KeyScribe mark is identity, not a replacement for
  standard controls.

## 4. Color direction

The icon should be quiet enough for a utility:

- Primary mark: off-white or deep ink, depending on background treatment.
- Accent: one muted signal color may emphasize a waveform segment, but the logo must work in
  monochrome.
- Avoid neon gradients, multi-color audio equalizers, rainbow spectra, and assistant-like
  purple sparkles.

Color in the app itself remains semantic and independent of the brand mark. A recording or cloud
state must not depend on icon brand color.

## 5. Explicit anti-patterns

- A generic microphone silhouette.
- A Siri-like orb or conversational-agent face.
- Sparkles, stars, or magic-wand metaphors.
- A dense equalizer with too many bars.
- Literal stenography-machine imagery that is illegible at menu-bar size.
- Any mark whose meaning changes between app icon and menu-bar glyph.

## 6. Acceptance criteria

The final vector/asset work is acceptable when:

- it is recognizable at menu-bar size in monochrome;
- it remains distinguishable from a microphone-only dictation app;
- it visually fits a restrained macOS utility;
- it works on light and dark backgrounds without semantic color;
- it communicates “speech becoming text” without additional copy.
