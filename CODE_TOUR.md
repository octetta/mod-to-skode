# A Tour of the Codebase for Gleam & Lustre Learners

Welcome! If you are learning [Gleam](https://gleam.run/) or [Lustre](https://hexdocs.pm/lustre/) (The Elm Architecture for Gleam) and want to see how they work in a non-trivial, real-world project beyond a simple counter or to-do list, this guide is for you.

`mod-to-skode` is an interactive in-browser audio workstation and native CLI that converts 35-year-old Commodore Amiga / ProTracker (`.mod`) music files into live-coding scripts and synthesizes them in real time via a WebAssembly audio engine.

This codebase demonstrates several core strengths of the Gleam language and ecosystem:
1. **Low-level binary pattern matching** using Gleam's Erlang-inspired `BitArray` syntax.
2. **State machines and simulation** written purely functionally without mutable variables.
3. **The Elm Architecture (TEA)** with Lustre managing complex UI state, asynchronous audio dispatch, and responsive layout.
4. **Typed Foreign Function Interface (FFI)** safely bridging Gleam to JavaScript, Web Audio, and WebAssembly.
5. **Code sharing across targets**: Running the exact same parsing and conversion logic in a browser web app and as a standalone native ELF binary via QuickJS.

---

## Table of Contents

- [Codebase Map](#codebase-map)
- [Architectural Philosophy: Functional Core, Imperative Shell](#architectural-philosophy-functional-core-imperative-shell)
- [Stop 1: The Domain Model (`src/mod_to_skode/types.gleam`)](#stop-1-the-domain-model-srcmod_to_skodetypesgleam)
  - [Custom Types & Sum Types](#custom-types--sum-types)
  - [Modeling Absence & Failure: `Option` and `Result`](#modeling-absence--failure-option-and-result)
  - [The Lustre `Model` & `Msg`](#the-lustre-model--msg)
- [Stop 2: Binary Pattern Matching with `BitArray` (`src/mod_to_skode/mod_parser.gleam`)](#stop-2-binary-pattern-matching-with-bitarray-srcmod_to_skodemod_parsergleam)
  - [Unpacking Binary Headers Declaratively](#unpacking-binary-headers-declaratively)
  - [Recursive Binary Unpacking](#recursive-binary-unpacking)
  - [Magic Bytes & Pattern Matching](#magic-bytes--pattern-matching)
- [Stop 3: Pure Functional State Simulation (`src/mod_to_skode/converter.gleam`)](#stop-3-pure-functional-state-simulation-srcmod_to_skodeconvertergleam)
  - [Simulating Sequences Without Mutable Loops](#simulating-sequences-without-mutable-loops)
  - [Tracking Channel State with Immutable `Dict`](#tracking-channel-state-with-immutable-dict)
  - [Strings and Accumulators](#strings-and-accumulators)
- [Stop 4: The Elm Architecture with Lustre (`src/mod_to_skode.gleam`)](#stop-4-the-elm-architecture-with-lustre-srcmod_to_skodegleam)
  - [The Three Pillars: Model, Msg, Update](#the-three-pillars-model-msg-update)
  - [Managing Side Effects with `Effect(Msg)`](#managing-side-effects-with-effectmsg)
  - [Declarative Views as Pure Functions](#declarative-views-as-pure-functions)
  - [Record Update Syntax](#record-update-syntax)
- [Stop 5: Bridging to JavaScript & WebAssembly (`src/skred_ffi.mjs`)](#stop-5-bridging-to-javascript--webassembly-srcskred_ffimjs)
  - [Declaring `@external` Functions](#declaring-external-functions)
  - [Feeding JS Events back into Lustre via `dispatch`](#feeding-js-events-back-into-lustre-via-dispatch)
  - [Binary Interop: `BitArray` and `Uint8Array`](#binary-interop-bitarray-and-uint8array)
- [Stop 6: Sharing Code with the Native CLI (`src/cli.gleam`)](#stop-6-sharing-code-with-the-native-cli-srccligleam)
- [Hands-On Exercises for Learners](#hands-on-exercises-for-learners)
- [Further Learning Resources](#further-learning-resources)

---

## Codebase Map

Here are the key files you'll encounter in `src/`:

```text
src/
├── mod_to_skode/
│   ├── types.gleam         # Stop 1: Data models, custom types, Lustre Model & Msg
│   ├── mod_parser.gleam    # Stop 2: Binary decoding using BitArray pattern matching
│   └── converter.gleam     # Stop 3: Pure functional tracker engine and compiler
├── mod_to_skode.gleam      # Stop 4: Lustre application (TEA: update, view, effects)
├── skred_ffi.mjs           # Stop 5: Web Audio, Emscripten WASM bridge, DOM helpers
├── cli.gleam               # Stop 6: Standalone native CLI runner (QuickJS target)
└── cli_ffi.mjs             # Node / QuickJS filesystem and process primitives
```

---

## Architectural Philosophy: Functional Core, Imperative Shell

A well-architected Gleam application typically follows the **Functional Core, Imperative Shell** pattern:

```
┌────────────────────────────────────────────────────────┐
│                   Imperative Shell                     │
│  - Web Audio Context (WebAssembly Skred Engine)        │
│  - DOM Events (Drag-and-drop, Click, Sliders)          │
│  - HTTP / Network (Fetching remote .mod files)         │
│  - File System I/O (in the CLI)                        │
└──────────────────────────┬─────────────────────────────┘
                           │ Dispatches Msg / Passes BitArrays
                           ▼
┌────────────────────────────────────────────────────────┐
│                   Functional Core                      │
│  - types.gleam      (Strict domain definitions)        │
│  - mod_parser.gleam (Pure binary decoding)             │
│  - converter.gleam  (Pure simulation & code generation)│
│  - update / view    (Pure state transitions & HTML)    │
└────────────────────────────────────────────────────────┘
```

The core has **zero side effects**: it never touches the DOM, never calls Web Audio, and never talks to the network. It takes inputs (`BitArray`), returns results (`Result(ModFile, String)`), and generates strings. Because of this, the core can be tested in milliseconds using `gleam test` and runs identically in Node, the browser, or native QuickJS.

---

## Stop 1: The Domain Model (`src/mod_to_skode/types.gleam`)

Every good Gleam program starts with its types. In [`src/mod_to_skode/types.gleam`](src/mod_to_skode/types.gleam), you'll see how we model the domain of retro tracker music and application state.

### Custom Types & Sum Types

In languages like JavaScript or Python, modes or states are often strings (`"playing"`, `"paused"`, `"stopped"`). If you make a typo like `"plaaing"`, the error only surfaces at runtime.

In Gleam, we represent mutually exclusive states using **Custom Types** (sum types / tagged unions):

```gleam
pub type StereoMode {
  StereoHeadphone
  StereoAmiga
  StereoMono
}
```

Now, the compiler will guarantee that:
1. Only these three values can ever exist for `StereoMode`.
2. Any `case` expression matching on `StereoMode` must handle all three cases (exhaustive pattern matching), or the code will not compile.

### Modeling Absence & Failure: `Option` and `Result`

Gleam does not have `null`, `nil`, or `undefined`. It also does not use runtime exceptions for normal control flow. Instead:

- **Absence** is modeled with `Option(a)` from `gleam/option`:
  ```gleam
  pub type Note {
    Note(
      midi: Option(Int), // Some(60) for Middle C, or None if no note was triggered
      inst: Int,
      effect: Int,
      param: Int,
      period: Int,
    )
  }
  ```
- **Operations that might fail** return `Result(value, error)`:
  ```gleam
  pub fn parse(filename: String, data: BitArray) -> Result(ModFile, String)
  ```
  Callers are forced by the compiler to handle both the `Ok(mod_file)` and `Error(message)` outcomes.

### The Lustre `Model` & `Msg`

Notice how the entire state of the web application is captured in a single record:

```gleam
pub type Model {
  Model(
    engine_ready: Bool,
    is_playing: Bool,
    is_paused: Bool,
    current_step: Int,
    active_file: Option(ModFile),
    conversion: Option(ConversionResult),
    is_converting: Bool,
    error_message: Option(String),
    status_text: String,
    active_tab: String,
    modarchive_info: Option(ModArchiveInfo),
    stereo_mode: StereoMode,
    master_volume: Int,
  )
}
```

And every possible user interaction or external event is an explicit variant in the `Msg` type:

```gleam
pub type Msg {
  EngineStatusChanged(Bool)
  FileDropped(name: String, data: BitArray)
  PlayClicked
  PauseClicked
  StereoModeChanged(StereoMode)
  MasterVolumeChanged(Int)
  PlaybackStepChanged(step: Int, total_steps: Int)
  PlaybackEnded
  // ...
}
```

---

## Stop 2: Binary Pattern Matching with `BitArray` (`src/mod_to_skode/mod_parser.gleam`)

One of Gleam's greatest superpowers—inherited directly from Erlang—is **pattern matching on binary data**.

In C, parsing a binary format requires pointer arithmetic and struct casting. In Python, it requires `struct.unpack('>22sHBBHH', buffer)`. In JavaScript, it requires juggling `DataView` with offset counters.

Look at how [`src/mod_to_skode/mod_parser.gleam`](src/mod_to_skode/mod_parser.gleam#L237-L245) unpacks an Amiga sample instrument header in a single pattern:

```gleam
case bits {
  <<
    raw_name:bytes-size(22),      // 22 bytes of ASCII name
    len_words:16-big,             // 16-bit big-endian unsigned integer
    ft_byte:8,                    // 8-bit finetune byte
    vol_byte:8,                   // 8-bit volume level (0..64)
    rep_off_words:16-big,         // 16-bit big-endian repeat offset
    rep_len_words:16-big,         // 16-bit big-endian repeat length
    rest:bits,                    // The remainder of the binary stream
  >> -> {
    // Process values directly!
    let name = clean_ascii_bits(raw_name)
    let len = len_words * 2
    // ...
  }
  _ -> Error("Unexpected end of file while reading instrument header")
}
```

### Unpacking Binary Headers Declaratively
Notice what happened here:
- `16-big` specifies a 16-bit integer decoded as **Big-Endian** (the Motorola 68000 byte order used by the Amiga).
- `bytes-size(22)` extracts an exact 22-byte chunk as a sub-`BitArray`.
- `rest:bits` captures everything that follows, allowing you to pass the tail to the next recursive iteration.

### Recursive Binary Unpacking

Because Gleam data is immutable, parsing loops are written using **recursion with an accumulator**:

```gleam
fn parse_instruments(
  bits: BitArray,
  idx: Int,
  acc: List(Instrument),
) -> Result(#(List(Instrument), BitArray), String) {
  case idx > 31 {
    // Base case: Amiga modules have exactly 31 instrument slots
    True -> Ok(#(list.reverse(acc), bits))
    False -> {
      case bits {
        << ..., rest:bits >> -> {
          let inst = Instrument(...)
          // Recurse with the next index and prepend to accumulator
          parse_instruments(rest, idx + 1, [inst, ..acc])
        }
        _ -> Error("Failed to parse instrument: unexpected EOF")
      }
    }
  }
}
```

> [!TIP]
> **List Prepend & Reverse**: Prepending an item to a linked list with `[item, ..acc]` is an $O(1)$ constant-time operation. Appending to the end of a list (`acc ++ [item]`) is $O(N)$. The standard functional idiom in Gleam and Erlang is to prepend during recursion and call `list.reverse(acc)` once when reaching the base case.

### Magic Bytes & Pattern Matching

At offset 1080 of a `.mod` file sits a 4-character identifier ("magic bytes") designating the tracker format. In `mod_parser.gleam`, we identify the channel count using simple string pattern matching:

```gleam
pub fn channels_from_magic(magic: String) -> Int {
  case magic {
    "M.K." | "M!K!" | "FLT4" | "4CHN" -> 4
    "6CHN" -> 6
    "8CHN" | "OCTA" | "OKTA" | "CD81" | "FLT8" -> 8
    "2CHN" -> 2
    _ -> {
      // Handles custom xxCH / xxCN patterns
      // ...
    }
  }
}
```

---

## Stop 3: Pure Functional State Simulation (`src/mod_to_skode/converter.gleam`)

Tracker modules don't just store notes; they store an execution script. A song can jump backward (`Bxx`), break patterns midway (`Dxx`), or loop rows (`E6x`).

In an imperative language, you would write:
```python
# Imperative approach:
while current_order < song_length:
    row = next_row()
    channels[0].volume += slide_amount  # Mutation!
```

In [`src/mod_to_skode/converter.gleam`](src/mod_to_skode/converter.gleam), there are no mutable variables. How do we simulate playback over time?

### Simulating Sequences Without Mutable Loops

We pass the current simulation state forward through a recursive function:

```gleam
fn unroll_sequence_loop(
  orders: List(Int),
  patterns: List(List(List(Note))),
  order_idx: Int,
  row_idx: Int,
  visited: Set(#(Int, Int)),
  acc: List(RowEvents),
) -> List(RowEvents) {
  // Check loop termination or sequence boundary
  case order_idx >= list.length(orders) {
    True -> list.reverse(acc)
    False -> {
      // 1. Read current row
      // 2. Compute state transition (effects, jumps, breaks)
      // 3. Recurse with updated coordinates!
      unroll_sequence_loop(orders, patterns, next_order, next_row, visited, [row, ..acc])
    }
  }
}
```

### Tracking Channel State with Immutable `Dict`

Each of the tracker's voices has an ongoing state: active sample, current pitch period, volume in dB, vibrato speed, and portamento target.

In `converter.gleam`, voice state is held in a `Dict(Int, ChannelState)`:

```gleam
// Reading voice 0 state:
let ch = case dict.get(channels, ch_idx) {
  Ok(state) -> state
  Error(_) -> default_channel_state(ch_idx)
}

// Updating voice state creates a NEW dictionary without mutating the old one:
let updated_channels = dict.insert(channels, ch_idx, ChannelState(..ch, volume: new_vol))
```

This guarantees **zero race conditions**: a step calculation can never accidentally corrupt or mutate the state of another step.

---

## Stop 4: The Elm Architecture with Lustre (`src/mod_to_skode.gleam`)

Lustre brings **The Elm Architecture (TEA)** to Gleam. If you have used React, Elm, or Redux, TEA will feel familiar, but with complete type safety.

The architecture revolves around three parts:

```
                    ┌──────────────┐
                    │     View     │ ◄── Pure render of Model to HTML
                    └──────┬───────┘
                           │ User clicks button / drops file
                           ▼
                    ┌──────────────┐
                    │     Msg      │
                    └──────┬───────┘
                           │ Sent to update function
                           ▼
                    ┌──────────────┐
                    │    Update    │ ──► Returns #(NewModel, Effect(Msg))
                    └──────────────┘
```

### The Three Pillars: Model, Msg, Update

Look at the `update` function in [`src/mod_to_skode.gleam`](src/mod_to_skode.gleam#L246):

```gleam
pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    PlayClicked -> {
      case model.conversion {
        Some(res) -> #(
          Model(..model, is_playing: True, is_paused: False),
          play_effect(res.skode_text, res.samples, res.total_rows),
        )
        None -> #(model, effect.none())
      }
    }

    PauseClicked -> #(
      Model(..model, is_paused: True),
      pause_effect(),
    )

    StereoModeChanged(new_mode) -> #(
      Model(..model, stereo_mode: new_mode),
      send_command_effect(converter.build_live_stereo_command(new_mode)),
    )
  }
}
```

Every branch of `update`:
1. Takes the current `model` and the received `msg`.
2. Returns a 2-element tuple: `#(NewModel, Effect)`.
3. If no side effect is needed, it returns `effect.none()`.

### Managing Side Effects with `Effect(Msg)`

Notice that `update` **never directly calls Web Audio or the browser**. Instead, it returns an `Effect(Msg)`.

Lustre provides `effect.from` to encapsulate side effects:

```gleam
fn send_command_effect(cmd: String) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    // JavaScript FFI call safely wrapped in an effect
    js_send_command(cmd)
  })
}
```

The runtime executes the effect outside of the pure update cycle. If the effect needs to produce a new message later (for example, when an HTTP request finishes or an audio track ends), it calls `dispatch(MyNewMsg)`.

### Declarative Views as Pure Functions

Views in Lustre are written using Gleam functions that return `Element(Msg)`. Look at how the transport controls are defined in `src/mod_to_skode.gleam`:

```gleam
fn view_transport_buttons(model: Model) -> Element(Msg) {
  html.div([class("transport-controls")], [
    case model.is_playing {
      False ->
        html.button(
          [class("btn btn-primary"), event.on_click(PlayClicked)],
          [text("▶ Play")],
        )
      True ->
        case model.is_paused {
          False ->
            html.button(
              [class("btn btn-warning"), event.on_click(PauseClicked)],
              [text("⏸ Pause")],
            )
          True ->
            html.button(
              [class("btn btn-success"), event.on_click(ResumeClicked)],
              [text("▶ Resume")],
            )
        }
    },
    html.button(
      [class("btn btn-danger"), event.on_click(StopClicked)],
      [text("⏹ Stop")],
    ),
  ])
}
```

Notice:
- **No JSX, template language, or virtual DOM compiler quirks**: HTML elements are regular Gleam functions (`html.div`, `html.button`, `html.span`).
- **Events are typed**: `event.on_click(PlayClicked)` takes a `Msg` constructor directly. If you misspell it or pass the wrong payload, the compiler catches it immediately!

### Record Update Syntax

Gleam records are immutable. To create a copy of a record with one or two fields updated, use the `..` spread syntax:

```gleam
Model(..model, is_playing: True, is_paused: False)
```

This returns a brand-new `Model` where `is_playing` and `is_paused` are changed, and all other 11 fields retain their original values.

---

## Stop 5: Bridging to JavaScript & WebAssembly (`src/skred_ffi.mjs`)

Because Gleam compiles to standard ECMAScript modules when targeting JavaScript, interacting with existing browser APIs, Web Audio, or WebAssembly is straightforward.

### Declaring `@external` Functions

To call a JavaScript function from Gleam, use the `@external` attribute:

```gleam
// in src/mod_to_skode.gleam:
@external(javascript, "./skred_ffi.mjs", "setMasterVolume")
fn js_set_master_volume(db: Int) -> Nil
```

And in [`src/skred_ffi.mjs`](src/skred_ffi.mjs):

```javascript
// in src/skred_ffi.mjs:
export function setMasterVolume(db) {
  if (!window.Module || typeof window.Module.ccall !== 'function') return;
  // Send Skred hardware volume command "V<db>"
  window.Module.ccall('skred_command', 'number', ['string'], [`V${db}`]);
}
```

### Feeding JS Events back into Lustre via `dispatch`

When an asynchronous external event occurs (such as a song reaching its end or the user dropping a file), JavaScript notifies Lustre by calling the `dispatch` function supplied by `effect.from`:

```gleam
fn register_playback_listener_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_register_playback_listener(
      fn(step, total) { dispatch(PlaybackStepChanged(step, total)) },
      fn() { dispatch(PlaybackEnded) },
    )
  })
}
```

In `skred_ffi.mjs`, when the audio engine hits the final step:

```javascript
export function registerPlaybackListener(onStep, onEnd) {
  playbackEndedCallback = onEnd; // JavaScript stores the callback
}

// When Skred finishes the song:
if (typeof playbackEndedCallback === 'function') {
  playbackEndedCallback(); // Dispatches PlaybackEnded to Lustre!
}
```

### Binary Interop: `BitArray` and `Uint8Array`

Under the hood on the JavaScript target, a Gleam `BitArray` is represented as a JavaScript `Uint8Array` (wrapped in a Gleam bit-array helper).

When mounting samples into Emscripten's virtual filesystem:

```javascript
export function loadAndPlaySkode(mainSk, samplesList, totalRows) {
  // Convert Gleam list of #(name, BitArray) to JS array
  const samples = samplesList.toArray();
  for (const [name, bitArray] of samples) {
    // bitArray.buffer extracts the underlying Uint8Array!
    window.Module.FS.writeFile(`/samples/${name}`, bitArray.buffer);
  }
}
```

---

## Stop 6: Sharing Code with the Native CLI (`src/cli.gleam`)

One of the most satisfying aspects of this project is that the conversion engine (`mod_parser.gleam` and `converter.gleam`) is **100% shared** between:
1. The interactive browser application (`mod_to_skode.gleam` via Lustre).
2. The standalone native command-line binary (`bin/mod2skode` via [`src/cli.gleam`](src/cli.gleam)).

When compiling the CLI binary with `make cli`:
1. Gleam compiles `src/cli.gleam` to JavaScript.
2. `esbuild` bundles it with `cli_ffi.mjs` and `fflate.mjs` into a single standalone script.
3. Fabrice Bellard's **QuickJS** compiler (`qjsc`) compiles that bundle directly into native C code and links it with `libquickjs.a` to produce a standalone ~1.2 MB executable.

The exact same parser, the exact same period math, and the exact same Skode compiler run without changing a single line of code!

---

## Hands-On Exercises for Learners

Want to get your hands dirty and practice writing Gleam and Lustre? Here are three guided mini-projects you can try right in this repository:

### Exercise 1: Add a "Double Speed" Button
- **Goal**: Add a button to the transport bar that toggles playback speed between 1x and 2x.
- **Steps**:
  1. Add a new `playback_speed: Float` field to `Model` in `types.gleam`.
  2. Add a `ToggleSpeedClicked` variant to `Msg`.
  3. Handle `ToggleSpeedClicked` in `update` in `mod_to_skode.gleam`.
  4. Emit a Skred command effect (`send_command_effect("z%...")`).
  5. Add a button in `view_transport_buttons` displaying the current speed.
  6. Run `make check && make build` to verify!

### Exercise 2: Refactor `active_tab` to a Custom Type
- **Goal**: In `types.gleam`, `active_tab: String` currently stores `"info"`, `"code"`, or `"samples"`.
- **Steps**:
  1. Define a sum type:
     ```gleam
     pub type ActiveTab {
       TabInfo
       TabCode
       TabSamples
     }
     ```
  2. Change `active_tab: String` in `Model` to `active_tab: ActiveTab`.
  3. Update `TabSelected` in `Msg` to take `ActiveTab` instead of `String`.
  4. Follow the compiler errors (`gleam check`)—it will pinpoint every place in `update` and `view` that needs updating. Notice how confident refactoring feels in Gleam!

### Exercise 3: Write a New Unit Test for Channel Parsing
- **Goal**: Add a test in `test/mod_to_skode_test.gleam` verifying that `channels_from_magic` properly recognizes `"16CN"` and `"32CN"`.
- **Steps**:
  1. Open `test/mod_to_skode_test.gleam`.
  2. Write a new test function:
     ```gleam
     pub fn multi_channel_magic_test() {
       mod_parser.channels_from_magic("16CN")
       |> should.equal(16)
     }
     ```
  3. Run `gleam test --target javascript` and watch it pass.

---

## Further Learning Resources

- **[Gleam Language Tour](https://tour.gleam.run/)**: Interactive browser-based tutorial covering all core language features.
- **[Lustre Documentation](https://hexdocs.pm/lustre/)**: Comprehensive guide and tutorials for Lustre and The Elm Architecture.
- **[Gleam Standard Library](https://hexdocs.pm/gleam_stdlib/)**: Documentation for `list`, `dict`, `result`, `option`, `bit_array`, and more.
- **[Gleam Discord Server](https://discord.gg/FmNXHDzkq8)**: An extraordinarily friendly and welcoming community of Gleam developers.

Happy coding, and enjoy the music! 🎶
