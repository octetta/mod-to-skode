# mod-to-skode

[![Version](https://img.shields.io/badge/version-v0.2.0-blue.svg)](gleam.toml)
[![Gleam](https://img.shields.io/badge/language-Gleam-ffaff3.svg)](https://gleam.run/)
[![Lustre](https://img.shields.io/badge/frontend-Lustre-ff69b4.svg)](https://hexdocs.pm/lustre/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

High-fidelity Amiga / ProTracker / FastTracker (`.mod`) module converter, interactive web studio, and playback engine for the **Skred 0.80.0** synthesizer and **Skode** live-coding sequencer.

Available both as a **100% client-side web application** with in-browser WebAssembly playback and as a standalone **native CLI binary** (`bin/mod2skode`) compiled from pure Gleam via QuickJS for zero-dependency batch conversions and terminal workflows.

🌐 **Interactive Web Studio:** [octetta.github.io/mod-to-skode](https://octetta.github.io/mod-to-skode/)  
📖 **Gleam & Lustre Code Tour:** [CODE_TOUR.md](CODE_TOUR.md)  
📦 **Skred Audio Engine:** [github.com/octetta/pulp](https://github.com/octetta/pulp)  
👤 **Author:** Joseph Stewart ([josephestewart.com](https://josephestewart.com)) · [YouTube: @octetta](https://youtube.com/@octetta)

---

## Table of Contents

- [Welcome & Overview](#welcome--overview)
- [Gleam & Lustre Code Tour](CODE_TOUR.md)
- [Web Application Studio](#web-application-studio)
  - [Key Features in v0.2.0](#key-features-in-v020)
  - [Real-Time Stereo Separation Modes](#real-time-stereo-separation-modes)
  - [Hardware-Accurate Master Volume](#hardware-accurate-master-volume)
  - [Smart Song Completion & Transport Reset](#smart-song-completion--transport-reset)
  - [Shareable Deep Links & The Mod Archive](#shareable-deep-links--the-mod-archive)
  - [Mobile & Touch-Friendly Studio](#mobile--touch-friendly-studio)
  - [Aspirational Gleam & Lustre Architecture](#aspirational-gleam--lustre-architecture)
- [Standalone Native CLI (`bin/mod2skode`)](#standalone-native-cli-binmod2skode)
  - [Key Benefits](#key-benefits)
  - [Building the CLI Binary](#building-the-cli-binary)
  - [CLI Usage & Options](#cli-usage--options)
  - [Batch Conversions via Make](#batch-conversions-via-make)
  - [Performance & Runtime Benchmarks](#performance--runtime-benchmarks)
- [Legacy Python CLI (`mod2skode.py`)](#legacy-python-cli-mod2skodepy)
- [How It Works](#how-it-works)
  - [Pattern Unrolling & Flow Control](#pattern-unrolling--flow-control)
  - [Dual-Track Sequencer & Conductor Macros](#dual-track-sequencer--conductor-macros)
  - [Adaptive Word-Budget Decimation](#adaptive-word-budget-decimation)
  - [Sample Extraction & 16-bit PAL WAV Conversion](#sample-extraction--16-bit-pal-wav-conversion)
- [Supported Tracker Effects](#supported-tracker-effects)
- [Public MOD Music Sources](#public-mod-music-sources)
- [Embedding Skred in Your Web Projects](#embedding-skred-in-your-web-projects)
- [Development & Makefile](#development--makefile)
  - [Prerequisites](#prerequisites)
  - [Makefile Targets](#makefile-targets)
  - [Updating the Skred WASM Engine](#updating-the-skred-wasm-engine)
  - [Continuous Deployment](#continuous-deployment)
- [Dependencies & Versions](#dependencies--versions)
- [Credits & Acknowledgements](#credits--acknowledgements)
- [License](#license)

---

## Welcome & Overview

`mod-to-skode` was built out of deep love and reverence for the Commodore Amiga demoscene, tracker music, and the expressive beauty of modern functional programming in [Gleam](https://gleam.run/).

There is something genuinely magical about taking an iconic 35-year-old `.mod` file—conceived on a Motorola 68000 with 512 KB of Chip RAM—dropping it into a modern browser window, and hearing pure Gleam code parse its raw bytes in milliseconds, reconstruct every pitch glide, vibrato tick, and loop point, and synthesize it through [Skred's](https://github.com/octetta/pulp) WebAssembly audio engine.

We are proud and excited to share what `mod-to-skode` can do:
- **100% Client-Side Web Audio**: Zero backend servers, zero file uploads. Everything runs locally in your browser via Gleam compiled to JavaScript, WebAssembly, and the Web Audio API.
- **Universal Multi-Channel Architecture**: Converts 4-channel classics (`M.K.`, `FLT4`) up to 32-channel FastTracker modules (`6CHN`, `8CHN`, `OCTA`, `CD81`, `16CN`, `32CN`).
- **Faithful ProTracker & FastTracker FX Emulation**: Full simulation of portamento glides, arpeggios, vibrato FM LFOs, volume sweeps, sample offsets, re-triggers, and tick delays.
- **Dual Form Factor**: Run it as an interactive visual web studio in your browser or as a lightning-fast, zero-dependency standalone native executable (`bin/mod2skode`) on Linux and macOS.
- **Live-Coding Ready**: Generates clean, human-readable Skode scripts (`main.sk`) with pattern and row comments, accompanied by 16-bit 16,574 Hz PAL-tuned PCM samples packed into an in-memory ZIP archive.

At the same time, tracker replay is famously nuanced, full of undocumented hardware quirks, and shaped by decades of demoscene idiosyncrasies. We approach this project with humble gratitude toward the pioneers who paved the way: Karsten Obarski, the ProTracker developers, the composers who pushed early silicon to its limits, and the language creators who make modern development a joy.

---

## Web Application Studio

The web application provides a complete visual workspace and audio player running at [octetta.github.io/mod-to-skode](https://octetta.github.io/mod-to-skode/).

### Key Features in v0.2.0

1. **Instant Drag-and-Drop Loading**: Drop any `.mod` file anywhere on the screen, select a file via dialog, or load from the built-in library.
2. **Real-Time Stereo Separation Switcher**: Toggle dynamically between `🎧 75% Headphone`, `🔊 100% Amiga Hardware`, and `📻 Mono 0%` during active playback without audio glitches or pauses.
3. **Master Volume Slider**: Real-time gain control in decibels (`V#`) from `-40 dB` to `+6 dB` (default: `-6 dB`).
4. **Smart Song Completion**: Automatic playback detection via sentinel downbeat events and loop-wrap tracking, smoothly stopping and resetting transport controls when a song finishes.
5. **The Mod Archive Explorer**: Explore random tracker gems on demand with the `🎲 Random from ModArchive` button.
6. **Shareable Deep Links**: Share links with `?url=...`, `?mod=the_hunter`, or `?id=172266` to let friends immediately listen to tracks, backed by offline fallback copies.
7. **Mobile-Responsive Studio UI**: Tailored dynamic layout (`100dvh`) with touch-friendly controls, responsive metadata grids, and swipeable tabs on iPhone and Android.
8. **Sample Auditioning**: Preview individual 16-bit WAV samples right inside the instrument table when playback is stopped.
9. **Direct ZIP Archive Export**: Download a ready-to-mount ZIP package (`main.sk` + samples) for offline performance or mounting into Skode via `%z archive.zip`.

---

### Real-Time Stereo Separation Modes

The original Commodore Amiga audio hardware (the Paula custom chip) featured four hardware audio channels hard-wired in fixed stereo:
- **Left Channel Output**: Channels 0 and 3
- **Right Channel Output**: Channels 1 and 2

While this hard-panned stereo separation sounds brilliant on stereo hi-fi speakers, it can cause severe listening fatigue on modern headphones. In `v0.2.0`, `mod-to-skode` offers three stereo profiles:

| Mode | Left Channels (0, 3) | Right Channels (1, 2) | Best For |
| :--- | :---: | :---: | :--- |
| **🎧 75% Headphone** *(Default)* | `p -0.75` | `p 0.75` | Comfortable, natural binaural listening on headphones and earbuds without ear fatigue. |
| **🔊 100% Amiga Hardware** | `p -1.0` | `p 1.0` | Authentic, uncompromised Commodore Amiga hardware experience on speakers. |
| **📻 Mono 0%** | `p 0.0` | `p 0.0` | Centered mixdown for mono speakers, smartphones, or club sound systems. |

> [!TIP]
> **Zero-Glitch Live Switching**: Changing the stereo mode during playback does not re-parse the module or re-encode audio buffers. Instead, it dispatches microsecond-fast live panning commands (`v0 p-0.75; v1 p0.75...`) directly to Skred's running WebAssembly synth voices, ensuring continuous, glitch-free audio even on mobile processors.

---

### Hardware-Accurate Master Volume

A dedicated Master Volume slider controls the overall audio output in decibels:
- **Range**: `-40 dB` (whisper quiet) to `+6 dB` (boosted headroom).
- **Default**: `-6 dB` (provides balanced headroom preventing DAC clipping during multi-voice crescendo peaks).
- **Protocol**: Dispatches immediate Skred `V#` commands directly to the audio engine core.

---

### Smart Song Completion & Transport Reset

In tracker music, songs end either when their sequence order completes or when they loop back to an earlier position. `mod-to-skode` handles song completion with precision:
- **Downbeat Sentinel Event**: During compilation, the converter marks the exact final step of the sequence with a sentinel control event (`[Z0 ce 127 v0]`).
- **Loop-Wrap Detection**: The playback engine tracks current step coordinates against song boundaries.
- **Clean Reset**: When the track reaches its natural conclusion, the audio engine smoothly stops, silences all voice allocations (`S-1`), and restores the transport controls to the initial **▶ Play** state.

---

### Shareable Deep Links & The Mod Archive

Want to share an Amiga track with a friend or colleague? `mod-to-skode` supports instant URL deep linking:

- **By Named Shortcut**:
  ```text
  https://octetta.github.io/mod-to-skode/?url=the_hunter
  https://octetta.github.io/mod-to-skode/?mod=the_hunter
  ```
- **By ModArchive ID**:
  ```text
  https://octetta.github.io/mod-to-skode/?id=172266
  ```
- **By Direct Remote URL**:
  ```text
  https://octetta.github.io/mod-to-skode/?url=https://api.modarchive.org/downloads.php?moduleid=172266#hoffman_-_the_hunter.mod
  ```

#### Resilient 3-Tier Offline Fallback
When a visitor opens a deep link:
1. It attempts to fetch the remote binary directly (with ModArchive's CORS-enabled download API).
2. If the user's connection is offline or ModArchive is temporarily unreachable, it seamlessly falls back to a high-speed cached edge proxy.
3. For featured tracks (such as Hoffman's *The Hunter*), it falls back to a locally bundled copy in `public/demos/hoffman_-_the_hunter.mod`. The music never fails to play!

---

### Mobile & Touch-Friendly Studio

We believe you shouldn't need a dual-monitor desktop workstation just to enjoy classic demoscene music. The web studio features a comprehensive mobile layout:
- **Dynamic Viewport Height (`100dvh`)**: Avoids browser address bar jumping on iOS Safari and mobile Chrome.
- **Thumb-Friendly Transport Grid**: Large, accessible touch targets for Play, Pause, Stop, and Panic Silence.
- **Adaptive Metadata Grids**: Responsive two-column displays for tracker format, BPM, speed, channel count, and file sizes.
- **Horizontally Scrollable Inspection Tabs**: Switch effortlessly between Instruments, Skode Script, and Sample Blobs on screens of any width.

---

### Aspirational Gleam & Lustre Architecture

The frontend is built with [Gleam](https://gleam.run/) and [Lustre](https://hexdocs.pm/lustre/), bundled via [Vite](https://vite.dev/), and isolated with Cross-Origin Opener / Embedder Policies (`COOP` and `COEP`) for high-performance multi-threaded WebAssembly audio.

> [!NOTE]
> **Vibe-Coded Aspirational Gleam & Lustre**: This project is an unapologetically "vibe-coded", aspirational exploration of Gleam and Lustre. While it leverages Gleam's algebraic types (`Msg` sum types, `Option`, `Result`, and product records) and Lustre's unidirectional architecture (The Elm Architecture) to run a 100% client-side WebAssembly tracker player, large portions of the converter (`converter.gleam`) were ported in algorithmic lockstep from the reference Python CLI to guarantee byte-for-byte output parity. As a result, purists (and benevolent language creators like Louis Pilfold and Hayleigh Thompson) would rightfully spot plenty of opportunities to make invalid states further unrepresentable, replace boolean flags with rich domain sum types, and refactor procedural accumulators into idiomatic pipelines!

---

## Standalone Native CLI (`bin/mod2skode`)

To eliminate runtime dependencies and establish **pure Gleam as the single source of truth**, `mod-to-skode` provides a standalone native CLI binary compiled directly from Gleam using Fabrice Bellard's [QuickJS](https://bellard.org/quickjs/) engine.

The CLI binary shares 100% of its parsing and conversion algorithms (`mod_parser.gleam` and `converter.gleam`) with the web application, packaged with synchronous ZIP creation via `fflate.mjs`.

### Key Benefits
- **Zero Runtime Dependencies**: Fully self-contained ELF / Mach-O executable (~1.2 MB stripped). No Python, Node.js, or Erlang VM required.
- **Sub-5ms Startup Time**: Launches instantly with zero VM warmup overhead.
- **100% Parity**: Guaranteed exact byte-for-byte output parity with the browser application.

### Building the CLI Binary
```bash
make cli
```
This automatically fetches QuickJS into `.vendor/` (without git submodules), compiles `libquickjs.a` and `qjsc`, bundles Gleam's JavaScript output with `esbuild`, and compiles the native executable into `bin/mod2skode`.

### CLI Usage & Options
```bash
bin/mod2skode <input.mod> [options]
```

| Flag | Argument | Description |
| :--- | :--- | :--- |
| `<input.mod>` | File path | Input ProTracker or FastTracker `.mod` file. |
| `-o`, `--output` | `<file>` | Output path. If ending in `.zip`, generates a ready-to-mount ZIP archive. If ending in `.sk`, writes the script. If omitted, streams to `stdout`. |
| `-x`, `--extract` | — | Extracts 16-bit 16,574 Hz WAV samples to a local `samples/` directory on disk. |
| `-h`, `--help` | — | Displays usage instructions and available options. |

#### CLI Examples
```bash
# Package a module into a complete, ready-to-play ZIP archive
bin/mod2skode mods/ELYSIUM.MOD -o elysium.zip

# Output the Skode script to a file and extract WAV samples to samples/
bin/mod2skode mods/space_debris.mod -o space_debris.sk -x

# Stream the Skode script directly to stdout or pipe into Unix tools
bin/mod2skode mods/aftertouch.mod > aftertouch.sk
```

### Batch Conversions via Make
Convert all `.mod` files in the `mods/` directory to `.zip` in one command:
```bash
make all
```

Or convert an individual module:
```bash
make space_debris.zip
```

### Performance & Runtime Benchmarks

The Gleam QuickJS CLI binary is designed as a **zero-dependency, single-file drop-in tool**, representing a deliberate engineering trade-off between **distribution portability** and **raw conversion throughput**:

| Runtime | Artifact Size | System Dependencies | Startup Time | Standard 4-Channel (`ELYSIUM.MOD`) | Heavy 28-Channel (`DOPE.MOD`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`bin/mod2skode` (QuickJS)** | **~1.2 MB** | **None** (standalone binary) | **< 5 ms** | **~2.5 s** | **~33 s** |
| **`mod2skode.py` (Python 3)** | Requires Python | Python 3 + standard library | ~35 ms | **0.11 s** | **1.3 s** |
| **`node dist/mod2skode.mjs` (V8)** | Requires Node | Node.js or Bun runtime | ~50 ms | **0.26 s** | **1.5 s** |

> [!NOTE]
> **Why the difference in execution speed?**
> 1. **Pure Interpreter vs. JIT / Adaptive Optimization**: QuickJS is a lightweight, embeddable C99 bytecode interpreter without a JIT compiler. In contrast, CPython 3.12+ features an adaptive specializing interpreter, and V8 (Node / Chrome) JIT-compiles hot loops directly into machine code.
> 2. **Immutable Data Structures vs. In-Place Mutation**: Gleam is a pure functional language. Tracking channel states across rows requires immutable record updates and `Dict` (Hash Array Mapped Trie) insertions. In Python, channel arrays are mutated in place with zero object allocations; in Node (V8), the generational garbage collector reclaims young immutable objects in microseconds. In QuickJS, each allocation triggers reference-counting updates in the C bytecode loop.
>
> **Which should you use?**
> - For everyday terminal use, CI containers, or environments where you want a single portable executable with zero dependencies, **`bin/mod2skode`** converts standard 4-channel Amiga tracks in ~2 seconds.
> - For high-volume batch pipelines processing thousands of files, the Python script (**`mod2skode.py`**) or running the bundled JS via Node (**`node dist/mod2skode.mjs`**) provides sub-second JIT throughput.

---

## Legacy Python CLI (`mod2skode.py`)

The original reference implementation in Python (`mod2skode.py`) is retained in the repository for historical benchmark comparisons and algorithmic verification:

```bash
python3 mod2skode.py input.mod [-o output.sk|output.zip] [-c] [-x]
```

---

## How It Works

### Pattern Unrolling & Flow Control

Tracker songs rarely play patterns linearly from start to finish. They rely on sequence order jump tables and flow-control effect opcodes:
- **`Bxx` (Position Jump)**: Jumps sequence playback to pattern order position `xx`.
- **`Dxx` (Pattern Break)**: Breaks the current pattern and resumes at row `xx` of the next pattern in the sequence list.
- **`E6x` (Pattern Loop)**: Sets a loop point on `E60` and repeats the row sequence `x` times on `E6x`.
- **`EEx` (Pattern Delay)**: Freezes progression, repeating the current row `x` times before stepping forward.

`mod-to-skode` unrolls the song sequence dynamically, tracking visited positions and loop iteration counters to prevent infinite loops while preserving every musical nuance.

### Dual-Track Sequencer & Conductor Macros

Skode pattern lengths are bounded at 128 steps. To handle standard 64-row tracker patterns across arbitrary song lengths:
1. Every two consecutive 64-row tracker blocks are mapped into a single 128-step Skode pattern block (e.g., patterns `p0` and `p1` become steps 0–63 and 64–127).
2. Channels are interleaved across Skode tracks (`v0` through `v3` for 4-channel MODs, up to `v31` for 32-channel files).
3. To prevent drift, a **Master Conductor Pattern** (`y127`) is scheduled. As each 128-step block finishes, it fires a control event (`ce <id>`). The Skode runtime catches the event and triggers an automated macro (`e><id>`) that seamlessly queues (`zq1`) the next pattern block locked to the downbeat.

### Adaptive Word-Budget Decimation

Skode sequences feature a strict compiler budget of **32 opcodes/words per step**. Stacked tracker effects (such as vibrato FM, volume slides, pitch bends, and micro-tick defers on the same row) can easily exceed this limit.

`mod-to-skode` employs an adaptive decimation algorithm:
- Every step's word budget is strictly capped at $\le 28$ words (leaving headroom for voice routing and ratchets).
- Priority is given to fundamental triggers: sample selector, note pitch, and primary volume commands.
- Micro-tick volume sweeps and vibrato defers are intelligently decimated over the step duration if the budget is reached, preserving 100% syntactic validity without sacrificing audio fidelity.

### Sample Extraction & 16-bit PAL WAV Conversion

1. **8-bit Signed to 16-bit Signed**: Amiga samples are stored as raw 8-bit signed PCM. They are upsampled and normalized to 16-bit signed PCM (`little-endian`).
2. **PAL Clock Tuning**: Samples are exported at the Amiga PAL tuning frequency of **16,574 Hz** (where A4 is 440 Hz at period 214 and note 57 A3 corresponds to period 428).
3. **Finetune to Cents**: MOD sample finetune (-8 to +7) is converted directly to precise frequency offsets in cents:
   $$\text{cents} = \text{finetune} \times 12.5$$
4. **Loop Padding**: Sustained looping samples are padded according to ProTracker hardware specifications to eliminate clicks at loop boundaries.

---

## Supported Tracker Effects

| Effect Code | Tracker Command | Skode Translation & Behavior |
|:---:|:---|:---|
| `0xy` | **Arpeggio** | Tick-accurate time defers (`+<time> n<note>`) executing rapid microtonal sweeps across the row. |
| `1xx` | **Portamento Up** | Pitch bent upwards using fractional frequency defers (`fb <delta>`). |
| `2xx` | **Portamento Down** | Pitch bent downwards using fractional frequency defers (`fb <delta>`). |
| `3xx` | **Tone Portamento** | Glissando sweep (`g<time>`) without re-triggering envelopes or sample phase. |
| `4xy` | **Vibrato** | Modulates voice frequency via dedicated LFO / FM routing on shadow voices. |
| `5xy` | **Tone Portamento + Vol Slide** | Continues tone portamento glide while executing amplitude fade (`a<db>`). |
| `6xy` | **Vibrato + Vol Slide** | Continues vibrato FM routing while fading amplitude. |
| `7xy` | **Tremolo** | Cyclic amplitude modulation using LFO defers. |
| `9xx` | **Sample Offset** | Offsets playback start position (`so<offset>`) into the sample buffer. |
| `Axy` | **Volume Slide** | Micro-tick amplitude fades (`a<db>`) over the step duration. |
| `Bxx` | **Position Jump** | Unrolled during sequence translation to jump order positions. |
| `Cxx` | **Set Volume** | Direct voice amplitude update (`a<db>`, scaled $0 \dots 64 \to -100 \dots -10\text{ dB}$). |
| `Dxx` | **Pattern Break** | Unrolled during sequence translation to break to a target row in the next pattern. |
| `E1x` | **Fine Portamento Up** | Immediate pitch shift upwards on tick 0. |
| `E2x` | **Fine Portamento Down** | Immediate pitch shift downwards on tick 0. |
| `E6x` | **Pattern Loop** | Loop segment repeat counter unrolled during compilation. |
| `E9x` | **Retrigger Note** | Step ratchet command (`z*<count>`) subdividing the step hardware trigger. |
| `EAx` | **Fine Volume Slide Up** | Immediate volume increase on tick 0. |
| `EBx` | **Fine Volume Slide Down** | Immediate volume decrease on tick 0. |
| `EDx` | **Note Delay** | Deferred execution (`+<time>`) delaying note trigger by exact sub-ticks. |
| `EEx` | **Pattern Delay** | Freezes pattern progression for `x` rows. |
| `Fxx` | **Speed (< 32)** | Modifies clock modulo speed dynamically (`z%<speed>`). |
| `Fxx` | **Tempo (>= 32)** | Emits master BPM and clock timing (`M <bpm> <ticks>`). |

---

## Public MOD Music Sources

Looking for classic Amiga MOD files to convert, explore, and play? Check out these public repositories:

- **[The Mod Archive](https://modarchive.org/)**: The definitive tracker music repository, hosting over 100,000 modules spanning ProTracker, FastTracker, ScreamTracker, and Impulse Tracker with ratings and charts.
- **[Amiga Music Preservation (AMP)](https://amp.dhs.nu/)**: The most comprehensive and historically accurate Commodore Amiga music preservation database, cataloging game soundtracks, demoscene productions, and disk magazines.
- **[Aminet MOD Collection](https://aminet.net/mods)**: The historic Commodore Amiga software and music repository active since 1992, hosting thousands of original `.mod` archives.

---

## Embedding Skred in Your Web Projects

Developers can embed the Skred WebAssembly audio engine into any webpage, web game, creative coding demo, or portfolio to play generated `.zip` packages natively client-side.

### 1. Copy Runtime Files
Copy the following files into your web project:
- `vendor/skred/skred_api.js` (vendored Emscripten glue runtime)
- `vendor/skred/skred_api.wasm` (Skred v0.80.0 multi-threaded synthesizer core)
- `coi-serviceworker.js` (provides Cross-Origin Isolation for `SharedArrayBuffer` on static hosts)

### 2. Include in HTML
```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Skred Player Demo</title>
  <!-- 1. Enable SharedArrayBuffer isolation via Service Worker -->
  <script src="coi-serviceworker.js"></script>

  <!-- 2. Configure Emscripten Module locateFile -->
  <script>
    window.Module = {
      locateFile: (path) => `./vendor/skred/${path}`,
      print: (text) => console.log('[Skred]', text),
      printErr: (text) => console.error('[Skred ERR]', text),
    };
  </script>

  <!-- 3. Load Skred WebAssembly Engine -->
  <script src="vendor/skred/skred_api.js"></script>
</head>
<body>
  <button id="play-btn">▶ Play</button>
  <button id="stop-btn">⏹ Stop</button>

  <script src="player.js"></script>
</body>
</html>
```

### 3. Mount and Play the Converted ZIP (`player.js`)
```javascript
document.getElementById('play-btn').addEventListener('click', async () => {
  const M = window.Module;
  if (!M) return;

  // Web Audio Context unlock on user gesture
  if (M.audioContext && M.audioContext.state === 'suspended') {
    await M.audioContext.resume();
  }

  // Initialize hardware audio device (128 buffer size for <3ms latency, 256 voices)
  if (typeof M._skred_start === 'function') {
    M._skred_enumerate_devices?.(0);
    M._skred_audio_select?.(0, 0);
    M._skred_audio_select?.(1, -2);
    M._skred_start(128, 256, -1);
  }

  // Clean previous playback, unmount zip, clear patterns and voices
  M.ccall('skred_command', 'number', ['string'], ['stop']);
  M.ccall('skred_command', 'number', ['string'], ['%zu']);
  M.ccall('skred_command', 'number', ['string'], ['Y-1']);
  M.ccall('skred_command', 'number', ['string'], ['S-1']);

  // Fetch the generated .zip and write to Emscripten Virtual File System
  const response = await fetch('./space_debris.zip');
  const zipBuffer = await response.arrayBuffer();
  M.FS.writeFile('/song.zip', new Uint8Array(zipBuffer));

  // Mount zip via Skode VFS (%z), load main.sk, and play
  M.ccall('skred_command', 'number', ['string'], ['%z [song.zip];']);
  M.ccall('skred_command', 'number', ['string'], ['play']);
});

// Stop, unmount, clear patterns, and silence all voices
document.getElementById('stop-btn').addEventListener('click', () => {
  const M = window.Module;
  if (!M) return;
  M.ccall('skred_command', 'number', ['string'], ['stop']);
  M.ccall('skred_command', 'number', ['string'], ['%zu']);
  M.ccall('skred_command', 'number', ['string'], ['Y-1']);
  M.ccall('skred_command', 'number', ['string'], ['S-1']);
});
```

---

## Development & Makefile

### Prerequisites

- **Gleam** $\ge 1.19.2$
- **Node.js** $\ge 20.0$ and **npm**
- **GCC** or **Clang** with standard `make` (to compile the standalone native CLI binary)
- *(Optional)* **Python** $\ge 3.9$ (only if running the legacy `mod2skode.py` script)
- *(Optional)* [mise-en-place](https://mise.jdx.dev/) toolchain manager (`mise.toml` provided).

### Makefile Targets

Run `make help` to inspect all available targets:

```text
mod-to-skode Makefile targets:
  make help         Show this help message
  make cli          Build standalone native CLI binary (bin/mod2skode via QuickJS)
  make dev          Start Vite dev server (host 0.0.0.0:3000)
  make run          Alias for 'make dev'
  make build        Compile Gleam and build production web bundle into dist/
  make build-web    Alias for 'make build'
  make preview      Preview production build in dist/ on 0.0.0.0:3000
  make test         Run test suite via Gleam JavaScript target
  make test-gleam   Alias for 'make test'
  make test-cli     Test the standalone CLI binary on mods/ELYSIUM.MOD
  make test-mods    Test conversion of all 20 demo modules in mods/
  make check        Verify compilation and Gleam formatting
  make format       Format all Gleam source and test files
  make deps         Install Gleam and npm dependencies
  make update-skred Pull Skred WASM from github.com/octetta/pulp (latest or VERSION=x.y.z)
  make all          Convert all demo modules in mods/ to out/*.zip via bin/mod2skode
  make <file>.zip   Convert a single module in mods/ to .zip via bin/mod2skode
  make install      Deploy ELYSIUM.zip to ../skred-web/amiga.zip
  make clean        Remove generated .zip files, build, and dist artifacts
  make distclean    Deep clean including .vendor and bin directories
```

### Updating the Skred WASM Engine

The Skred audio engine WebAssembly runtime (`skred_api.js` and `skred_api.wasm`) is vendored directly into `vendor/skred/` and `public/vendor/skred/`.

To pull the latest official release:
```bash
make update-skred
```

To pin to an explicit release version:
```bash
make update-skred VERSION=0.80.0
```

### Continuous Deployment

The web studio is automatically built and deployed to GitHub Pages at [octetta.github.io/mod-to-skode](https://octetta.github.io/mod-to-skode/) via GitHub Actions (`.github/workflows/deploy.yml`):
- Triggers on every push to `main` or manual `workflow_dispatch`.
- Verifies Gleam formatting, tests, and compilation.
- Builds the production bundle with Vite into `dist/`.
- Deploys with `coi-serviceworker.js` to enable `SharedArrayBuffer` isolation seamlessly on GitHub Pages.

---

## Dependencies & Versions

The project relies on pinned, deterministic dependencies across the Gleam, JavaScript, WebAssembly, and native C toolchains:

### Core Toolchains & Runtimes

| Component | Pinned / Required Version | Purpose |
| :--- | :--- | :--- |
| **[Gleam](https://gleam.run/)** | `^1.19.2` | Primary language; compiles to ES module JavaScript |
| **[Node.js](https://nodejs.org/)** | `^20.0.0` (tested `v26.12.0`) | Development server, package runner, and test environment |
| **[GCC](https://gcc.gnu.org/) / Clang** | Standard C99 / GNU99 | Compiles QuickJS and links the standalone native CLI binary |
| **[Skred Audio Engine](https://github.com/octetta/pulp)** | `v0.80.0` (via `SKRED_VERSION`) | Real-time multi-threaded WebAssembly audio synthesizer |

### Gleam Packages (`gleam.toml` & `manifest.toml`)

| Package | Version | Description |
| :--- | :--- | :--- |
| **`gleam_stdlib`** | `1.0.5` | Standard library: algebraic data types, dicts, lists, bit arrays, results |
| **`lustre`** | `5.7.1` | The Elm Architecture frontend framework for the reactive web application |
| **`gleam_json`** | `3.1.0` | JSON encoding and decoding primitives |
| **`gleeunit`** | `1.11.0` | Test framework for running Gleam tests against the JS runtime |

### JavaScript & Build Tools (`package.json`)

| Package | Version | Description |
| :--- | :--- | :--- |
| **`vite`** | `^6.2.0` | High-speed frontend development server and production bundler |
| **`esbuild`** | `^0.25.0` | High-performance JS bundler for packaging the standalone QuickJS CLI |
| **`coi-serviceworker`** | `^0.1.7` | Enables COOP/COEP isolation headers for WebAssembly multi-threading |

### Vendored Engines & Libraries (`vendor/` & `.vendor/`)

| Library | Origin / Commit | Description |
| :--- | :--- | :--- |
| **[QuickJS](https://bellard.org/quickjs/)** | Fabrice Bellard & Charlie Gordon | Embeddable C JS engine (`libquickjs.a` + `qjsc`) for standalone native binaries |
| **[fflate](https://github.com/101arrowz/fflate)** | `v0.8.2` (Arjun Barrett) | Pure JavaScript synchronous and asynchronous Deflate/ZIP compression |
| **Skred WASM Runtime** | `v0.80.0` (`octetta/pulp`) | `skred_api.js` and `skred_api.wasm` Emscripten WebAssembly runtime files |

---

## Credits & Acknowledgements

This project stands on the shoulders of brilliant software pioneers, musicians, and open-source contributors:

- **Joseph Stewart ([Octetta](https://github.com/octetta))**: Project creator, converter architecture, Skode sequencer design, and author of the [Skred audio engine](https://github.com/octetta/pulp). Find more work and music at [josephestewart.com](https://josephestewart.com) and on YouTube at [@octetta](https://youtube.com/@octetta).
- **[Louis Pilfold](https://github.com/lpil) & the Gleam Community**: Creators of [Gleam](https://gleam.run/)—a delightfully friendly, type-safe language that brings absolute joy to functional programming.
- **[Hayleigh Thompson](https://github.com/hayleigh-dot-dev) & the Lustre Contributors**: Creators of [Lustre](https://hexdocs.pm/lustre/), bringing The Elm Architecture to the Gleam web ecosystem with elegance and clarity.
- **[Fabrice Bellard](https://bellard.org/) & Charlie Gordon**: Creators of **QuickJS**, the remarkably compact, standards-compliant C JavaScript engine that powers the standalone native `mod2skode` CLI.
- **Arjun Barrett ([@101arrowz](https://github.com/101arrowz))**: Author of [fflate](https://github.com/101arrowz/fflate), the fastest zero-dependency pure JavaScript compression library.
- **Guido van Rossum & the Python Community**: Creators of Python, which hosted the initial prototype implementation ([`mod2skode.py`](mod2skode.py)).
- **Amiga Tracker Pioneers**:
  - **Karsten Obarski**: Creator of *The Ultimate Soundtracker* (1987) on the Commodore Amiga, who invented the 4-channel MOD format, step pattern structure, and sample triggering model that started the entire tracker movement.
  - **Lars Hamre, Kjetil Nygård, Peter Hesselberg, and Michael Kleps**: Authors of *ProTracker*, the legendary Amiga music editor whose playback quirks and effect commands set the standard for tracker music worldwide.
- **Demoscene Composers & Module Attributions**:
  This repository vendors historical module files located under [`mods/`](mods/) and [`public/demos/`](public/demos/) used for automated parity verification, test benchmarking, and demonstration:
  - **`mods/ELYSIUM.MOD`**: Volker Tripp (*Jester / Sanity*) – Title track from the legendary Amiga demo *Elysium* (Sanity, Germany).
  - **`mods/stardust-memories.mod`**: Volker Tripp (*Jester / Sanity*) – Soundscape composed for Sanity's *World of Commodore 92* demo (1992).
  - **`mods/space_debris.mod`**: Markus Schneider (*Captain / Image*) – Iconic 1991 melodic synthesizer tracker anthem.
  - **`public/demos/hoffman_-_the_hunter.mod`**: *Hoffman* – High-energy Amiga demoscene breakbeat/synth classic (The Mod Archive ID #172266).
  - **`mods/beyond_music.mod`**: Markus Schneider (*Captain / Image*) – 1st place winner in The Gathering 1991 music competition (Parikkala, Finland).
  - **`mods/creamof.mod`** (*Cream of the Earth*): Eckart Herzog (*Romeo Knight / Red Sector Inc.*) – Historic rock/synth module from the *RSI Megademo* (1989/1990).
  - **`mods/tempest-acidjazz.mod`** (*Acidjazzed Evening*): Aleksi Eeben (*Tempest / Damage / Chippendales*) – 1st place winner in the Assembly 2000 (asm2k) oldskool music compo.
  - **`mods/jogeir_liljedahl_-_addiction.mod`**: Jogeir Liljedahl (*Noiseless*) – Classic 1992 Amiga melody.
  - **`mods/physical_presence.mod`**: Jogeir Liljedahl (*Virtual Dreams / Fairlight*) – Soundtrack for the landmark 1993 demo *Physical Presence*.
  - **`mods/street_jungle.mod`**: Antti Mikkonen (*Heatbeat / Rebels*) – High-energy breakbeat/jungle module (Kajaani, Finland).
  - **`mods/bananasplit.mod`**: Juha Kujanpää (*Dizzy / CNCD*) – Funk/fusion tracker groove (1993, Finland).
  - **`mods/aftertouch.mod`**: *Substance (Mono & Kinky)* – Atmospheric 1997 jungle/drum & bass competition tune for Digital Candy BBS.
  - **`mods/random_voice_-_monday.mod`**: Edvin Fladen (*Random Voice*) – Classic melodic module (April 1991, Norway).
  - **`mods/_1995.mod`**: *Angelwings / Apex* – Chiptune composed for Lord Lech / Humbugs (April 1995).
  - **`mods/_4k_introtune_.mod`**: *Bionic / Erotic* – Compact chiptune composed for the *Turnips 4k Intro* (October 1996, Gliwice, Poland).
  - **`mods/class09.mod`**: *Maktone* – Signature compact, crystalline Amiga tracker chiptune.
  - **`mods/musiklinjen.mod`**: Mats & Thomas (*Firefox & Tip / Phenomena*) – Legendary Swedish duo celebrated for Phenomena's *Enigma* and *Megademo*.
  - **`mods/projectx.mod`**: Remixed by *Bladswede* – Tribute remix of Allister Brimble's iconic 1992 Team17 shoot 'em up game soundtrack *Project-X*.
  - **`mods/hymn_to_aurora.mod`**: *Clawz / Aurora / Shamus* – Ambient melodic soundscape.
  - **`mods/giel.mod`**: *Giel van Dooren* – Classic European Amiga tracker composition.
  - **`mods/DOPE.MOD`**: Classic multi-track electronic module featuring Roland TR-808/909 percussion and sampled groove loops.

Immense respect and gratitude to all tracker musicians and demoscene coders whose artistry, ingenuity, and passion defined early computer music culture.

---

## License

[MIT License](LICENSE). Copyright (c) Octetta / Joseph Stewart. See [`LICENSE`](LICENSE) for details.
