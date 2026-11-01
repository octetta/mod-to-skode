# mod-to-skode

High-fidelity Amiga / ProTracker / FastTracker (`.mod`) module converter and playback engine for the **Skred 0.80.0** synthesizer and **Skode** live-coding sequencer.

Available both as a **100% client-side web application** with in-browser WASM playback and as a standalone **native CLI binary** (`bin/mod2skode`) compiled from pure Gleam via QuickJS for zero-dependency batch conversions and terminal workflows.

🌐 **Web App:** [octetta.github.io/mod-to-skode](https://octetta.github.io/mod-to-skode/)  
📦 **Skred Audio Engine:** [github.com/octetta/pulp](https://github.com/octetta/pulp)

---

## Table of Contents

- [Overview](#overview)
- [Web Application](#web-application)
- [Standalone Native CLI (`bin/mod2skode`)](#standalone-native-cli-binmod2skode)
- [Legacy Python CLI (`mod2skode.py`)](#legacy-python-cli-mod2skodepy)
- [How it Works](#how-it-works)
  - [Pattern Unrolling & Flow Control](#pattern-unrolling--flow-control)
  - [Dual-Track Sequencer & Conductor Macros](#dual-track-sequencer--conductor-macros)
  - [Adaptive Word-Budget Decimation](#adaptive-word-budget-decimation)
  - [Sample Extraction & 16-bit WAV Conversion](#sample-extraction--16-bit-wav-conversion)
- [Supported Tracker Effects](#supported-tracker-effects)
- [Public MOD Music Sources](#public-mod-music-sources)
- [Embedding Skred in Your Web Application](#embedding-skred-in-your-web-application)
- [Development & Makefile](#development--makefile)
  - [Prerequisites](#prerequisites)
  - [Makefile Targets](#makefile-targets)
  - [Updating Skred WASM](#updating-skred-wasm)
  - [GitHub Pages Deployment](#github-pages-deployment)
- [Dependencies & Versions](#dependencies--versions)
- [Credits & Acknowledgements](#credits--acknowledgements)
- [License](#license)

---

## Overview

`mod-to-skode` bridges the golden age of Commodore Amiga tracker music (1987–1990s) with modern live-coding audio synthesis in Skred. It translates binary MOD tracker channels, speed commands, pattern breaks, and micro-tick audio effects into human-readable, editable Skode scripts (`main.sk`) and 16-bit mono WAV samples at Amiga PAL tuning (16,574 Hz).

Key capabilities:
- **Zero Server Uploads**: Operates entirely in the browser using Gleam compiled to JavaScript, WebAssembly, and the Web Audio API.
- **Universal Multi-Channel Support**: 1 to 32 channels (`M.K.`, `M!K!`, `4CHN`, `FLT4`, `6CHN`, `8CHN`, `OCTA`, `CD81`, `16CN`, `32CN`).
- **Complete Tracker FX Emulation**: Accurate portamentos, glissandos, vibrato FM LFO routing, arpeggios, volume slides, re-triggers, and note delays.
- **In-Memory ZIP Archives**: Downloads ready-to-mount ZIP packages (`main.sk` + samples) directly in the browser via `fflate`.
- **Integrated Skred v0.80.0 Player**: Instant one-click playback and hardware panic silence (`S-1`).

---

## Web Application

The interactive web UI is built with [Gleam](https://gleam.run/) and [Lustre](https://hexdocs.pm/lustre/), bundled with [Vite](https://vite.dev/), and isolated via Cross-Origin Opener / Embedder Policies (COOP/COEP) for multi-threaded WASM support.

> [!NOTE]
> **Vibe-Coded Aspirational Gleam & Lustre**: This project is an unapologetically "vibe-coded", aspirational exploration of Gleam and Lustre. While it leverages Gleam's algebraic types (`Msg` sum types, `Option`, `Result`, and product records) and Lustre's unidirectional architecture (The Elm Architecture) to run a 100% client-side WebAssembly tracker player, large portions of the converter (`converter.gleam`) were ported in algorithmic lockstep from the reference Python CLI to guarantee byte-for-byte output parity. As a result, purists (and benevolent language creators like Louis Pilfold and Hayleigh Thompson) would rightfully spot plenty of opportunities to make invalid states further unrepresentable, replace boolean flags with rich domain sum types, and refactor procedural accumulators into idiomatic pipelines!

### Features
1. **Drag-and-Drop Loader**: Drop any `.mod` file directly onto the browser window or pick via file dialog.
2. **Instant Demo Modules**: Includes built-in classic modules ready to test in 1 click:
   - 🚀 *Space Debris* by Captain / Image (4 channels, melodic synth leads and arpeggios).
   - ⚡ *4K Intro Tune* (compact 4-channel chiptune intro).
3. **Interactive Inspection Dashboard**:
   - **Instruments & Samples**: Lists all 31 sample slots with byte sizes, 0..64 volume levels, finetunes, tuning offsets in cents, loop ranges, and **interactive sample audition / preview** buttons to listen to individual 16-bit WAV samples when stopped.
   - **Generated Skode (`main.sk`)**: Full syntax-highlighted preview of the compiled Skode script.
   - **WAV Sample Blobs**: Overview of all generated 16-bit 16,574 Hz PCM samples mounted in the virtual filesystem.
4. **WASM Transport Controls & Real-Time Progress**:
   - **Play / Pause / Resume / Stop**: Mounts samples into the Emscripten VFS and triggers native engine playback, with seamless pause/resume and automatic transport reset on song completion.
   - **Live Step & Time Tracking**: Real-time progress bar, current step counter (`Step X / Y`), elapsed time, and total song duration.
   - **Panic Silence**: Instantly silences all voices (`S-1`) and resets audio dispatchers.
   - **Download .ZIP**: Bundles the script and samples into an archive ready for Skode's `%z archive.zip` command.

---

## Standalone Native CLI (`bin/mod2skode`)

To shed the Python dependency and establish **pure Gleam as the single source of truth**, `mod-to-skode` provides a standalone native CLI binary compiled directly from Gleam using Fabrice Bellard's [QuickJS](https://bellard.org/quickjs/) engine.

The CLI binary shares 100% of the conversion algorithms (`mod_parser.gleam` and `converter.gleam`) with the web application, packaged with synchronous ZIP creation via `fflate.mjs`.

### Key Benefits
- **Zero Runtime Dependencies**: Fully self-contained ELF executable (~1.2 MB stripped). No Python, Node.js, or Erlang VM required to run.
- **Instant Startup**: Launches in under 5 ms.
- **100% Parity**: Guaranteed exact byte-for-byte output parity with the browser application.

### Build the CLI Binary
```bash
make cli
```
This automatically fetches QuickJS into `.vendor/` (without git submodules), compiles `libquickjs.a` and `qjsc`, bundles Gleam's JavaScript output with `esbuild`, and compiles the native executable into `bin/mod2skode`.

### Usage
```bash
bin/mod2skode <input.mod> [options]
```

### Options
- `<input.mod>`: Path to the ProTracker or FastTracker `.mod` file.
- `-o`, `--output <file>`: Target output path.
  - If given a filename ending in `.zip`, creates a ready-to-mount ZIP archive containing `main.sk` and all 16-bit WAV samples.
  - If given a `.sk` filename, writes the Skode script to that file.
  - If omitted, streams the generated `.sk` script directly to `stdout`.
- `-x`, `--extract`: Extracts the 16-bit WAV samples to a local `samples/` directory on disk.
- `-h`, `--help`: Prints help and usage options.

### Examples
```bash
# Package a module into a complete, standalone ready-to-play ZIP
bin/mod2skode mods/ELYSIUM.MOD -o elysium.zip

# Output the Skode script to a file and extract WAV samples to samples/
bin/mod2skode mods/space_debris.mod -o space_debris.sk -x

# Stream the Skode script directly to stdout or pipe into tools
bin/mod2skode mods/aftertouch.mod > aftertouch.sk
```

### Batch Conversion via Make
Convert all `.mod` files in the `mods/` directory to `.zip` in one step using the native CLI:
```bash
make all
```

Or convert an individual module:
```bash
make space_debris.zip
```

---

## Legacy Python CLI (`mod2skode.py`)

The original reference implementation in Python (`mod2skode.py`) is retained for historical benchmark comparisons:

```bash
python3 mod2skode.py input.mod [-o output.sk|output.zip] [-c] [-x]
```

---

## How it Works

### Pattern Unrolling & Flow Control

Tracker songs often feature looping sequences, jump commands, and mid-pattern breaks. Rather than blindly concatenating patterns linearly, `mod-to-skode` simulates the tracker playback pointer:
- **`Bxx` (Position Jump)**: Jumps sequence playback to pattern order position `xx`.
- **`Dxx` (Pattern Break)**: Breaks the current pattern and resumes at row `xx` of the next pattern in the sequence list.
- **`E6x` (Pattern Loop)**: Supports nested and channel-specific pattern loops (sets loop point on `E60`, repeats `x` times on `E6x`).
- **`EEx` (Pattern Delay)**: Repeats the current row `x` times before stepping forward.

### Dual-Track Sequencer & Conductor Macros

Skode pattern lengths are bounded at 128 steps. To handle standard 64-row tracker patterns across arbitrary song lengths:
1. Every two consecutive 64-row tracker blocks are mapped into a single 128-step Skode pattern block (e.g., patterns `p0` and `p1` become steps 0–63 and 64–127).
2. Channels are interleaved across Skode tracks (`v0` through `v3` for 4-channel MODs, up to `v31`).
3. To prevent drift, a **Master Conductor Pattern** (`y127`) is scheduled. As each 128-step block finishes, it fires a control event (`ce <id>`). The Skode runtime catches the event and triggers an automated macro (`e><id>`) that seamlessly queues (`zq1`) the next pattern block locked to the downbeat.

### Adaptive Word-Budget Decimation

Skode sequences feature a strict compiler budget of **32 opcodes/words per step**. Stacked tracker effects (such as vibrato FM, volume slides, pitch bends, and micro-tick defers on the same row) can easily exceed this limit.

`mod-to-skode` employs an adaptive decimation algorithm:
- Every step's word budget is strictly capped at $\le 28$ words (leaving headroom for voice routing and ratchets).
- Priority is given to fundamental triggers: sample selector, note pitch, and primary volume commands.
- Micro-tick volume sweeps and vibrato defers are intelligently decimated over the step duration if the budget is reached, preserving 100% syntactic validity without sacrificing audio fidelity.

### Sample Extraction & 16-bit WAV Conversion

1. **8-bit Signed to 16-bit Signed**: Amiga samples are stored as raw 8-bit signed PCM. They are upsampled and normalized to 16-bit signed PCM (`little-endian`).
2. **PAL Clock Tuning**: Samples are exported at Amiga PAL tuning frequency of **16,574 Hz** (where A4 is 440 Hz at period 214 and note 57 A3 corresponds to period 428).
3. **Finetune to Cents**: MOD sample finetune (-8 to +7) is converted directly to precise frequency offsets in cents:
   $$\text{cents} = \text{finetune} \times 12.5$$
4. **Loop Padding**: Sustained looping samples are padded according to ProTracker hardware specs to eliminate clicks at loop boundaries.

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

Looking for classic Amiga MOD files to convert and play? Explore these public archives:

- **[The Mod Archive](https://modarchive.org/)**: The premier repository of tracker music on the web. Over 100,000 modules spanning ProTracker, FastTracker, ScreamTracker, and Impulse Tracker, with searchable charts and community ratings.
- **[Amiga Music Preservation (AMP)](https://amp.dhs.nu/)**: The most comprehensive and historically accurate Commodore Amiga music preservation database, cataloging game soundtracks, demoscene productions, and disk magazines.
- **[Aminet MOD Collection](https://aminet.net/mods)**: The historic Commodore Amiga software and music repository active since 1992, hosting thousands of original `.mod` archives.

---

## Embedding Skred in Your Web Application

Developers can embed the Skred WebAssembly audio engine into any webpage, web game, creative coding demo, or portfolio to play generated `.zip` packages natively client-side.

### 1. Copy Runtime Files

Copy the following files into your web project:
- `vendor/skred/skred_api.js` (vendored Emscripten glue runtime)
- `vendor/skred/skred_api.wasm` (Skred v0.80.0 multi-threaded synthesizer core)
- `coi-serviceworker.js` (provides Cross-Origin Isolation for `SharedArrayBuffer` on GitHub Pages or static hosts without server-side header access)

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
- *(Optional)* [mise-en-place](https://mise.jdx.dev/) toolchain manager (configuration provided in `mise.toml`).

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

### Updating Skred WASM

The Skred audio engine WebAssembly runtime (`skred_api.js` and `skred_api.wasm`) is vendored directly into `vendor/skred/` and `public/vendor/skred/`.

To pull the latest official release from GitHub:
```bash
make update-skred
```

To pin to an explicit release version:
```bash
make update-skred VERSION=0.80.0
```

This target uses `scripts/fetch-skred.sh` to query the GitHub Releases API on `octetta/pulp`, download the `skred-<version>-maxed-wasm.zip` artifact, verify contents, extract the runtime files, and record the active version in `SKRED_VERSION`.

### GitHub Pages Deployment

The web application is automatically built and deployed to GitHub Pages at [octetta.github.io/mod-to-skode](https://octetta.github.io/mod-to-skode/) via GitHub Actions (`.github/workflows/deploy.yml`):
- Triggers on every push to `main` or manual `workflow_dispatch`.
- Installs pinned Gleam and Node.js toolchains.
- Runs `gleam test --target javascript` and `gleam check`.
- Bundles the production application via `npm run build` into `dist/`.
- Deploys the static bundle with `coi-serviceworker.js` to ensure WebAssembly multi-threading isolation works seamlessly on GitHub Pages.

---

## Dependencies & Versions

The project is structured with pinned, deterministic dependencies across the Gleam, JavaScript, WebAssembly, and native C toolchains:

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

- **[Octetta](https://github.com/octetta)**: Architecture, converter algorithms, Skode sequencer design, and the [Skred audio engine](https://github.com/octetta/pulp).
- **[Fabrice Bellard](https://bellard.org/) & Charlie Gordon**: Authors of **QuickJS**, the remarkably compact, standards-compliant C JavaScript engine that powers the self-contained native `mod2skode` CLI.
- **[Louis Pilfold](https://github.com/lpil) & the Gleam Community**: Creators of the friendly, robust, type-safe [Gleam](https://gleam.run/) language.
- **[Hayleigh Thompson](https://github.com/hayleigh-dot-dev) & the Lustre Contributors**: Creators of [Lustre](https://hexdocs.pm/lustre/), bringing The Elm Architecture to Gleam with declarative elegance.
- **Arjun Barrett ([@101arrowz](https://github.com/101arrowz))**: Author of [fflate](https://github.com/101arrowz/fflate), the fastest zero-dependency pure JavaScript compression library.
- **Guido van Rossum & the Python Software Foundation**: Creators of Python, which hosted the initial prototype implementation ([`mod2skode.py`](mod2skode.py)).
- **Amiga Tracker Pioneers**:
  - **Karsten Obarski**: Creator of *The Ultimate Soundtracker* (1987) on the Commodore Amiga, who invented the 4-channel MOD format, step pattern structure, and sample triggering model that started the tracker movement.
  - **Lars Hamre, Kjetil Nygård, Peter Hesselberg, and Michael Kleps**: Authors of *ProTracker*, the legendary Amiga music editor whose playback quirks and effect commands set the standard for tracker music worldwide.
- **Demoscene Composers & Module Attributions**:
  This repository vendors 20 historical module files located under [`mods/`](mods/) used for automated parity verification, test benchmarking, and demonstration:
  - **`mods/ELYSIUM.MOD`**: Volker Tripp (*Jester / Sanity*) – Title track from the legendary Amiga demo *Elysium* (Sanity, Germany).
  - **`mods/stardust-memories.mod`**: Volker Tripp (*Jester / Sanity*) – Soundscape composed for Sanity's *World of Commodore 92* demo (1992).
  - **`mods/space_debris.mod`**: Markus Schneider (*Captain / Image*) – Iconic 1991 melodic synthesizer tracker anthem.
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
  - Respect and gratitude to all tracker musicians whose artistry and sonic ingenuity defined early computer music culture.

---

## License

MIT License. Copyright (c) Octetta. See [`LICENSE`](LICENSE) for details.
