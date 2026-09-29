# mod-to-skode

`mod-to-skode` is a Python utility that translates classic ProTracker (`.mod`) files into `.sk` (Skode) scripts for playback in the Skred audio engine.

## Usage

```bash
python mod2skode.py input.mod [-o output.sk] [-c] [-x]
```

- `input.mod`: The path to the ProTracker MOD file you want to convert.
- `-o`, `--output`: Specifies the output `.sk` or `.zip` file. If the file ends in `.zip`, the script and all converted 16-bit WAV samples are automatically bundled into a single `.zip` file ready to be mounted via Skode's VFS (`%z output.zip`). If omitted, the Skode text is printed to `stdout`.
- `-x`, `--extract`: Explicitly extracts the instrument samples natively to disk inside a `samples/` directory alongside the generated script.
- `-c`, `--compress`: Compresses blank sequencer rows (omitting empty `[] x{step}` declarations) to significantly reduce the output file size.

### Sample Extraction
By default, the converter relies on the presence of WAV files inside a `samples/` directory. However, you can use the built-in extraction features to handle this automatically:
1. **ZIP Output (`-o file.zip`)**: Bundles the `.sk` script and all automatically converted 16-bit signed WAV files (at 16574 Hz) into a single archive without writing WAVs to your local disk.
2. **Disk Extraction (`-x`)**: Automatically rips, converts, and saves the 16-bit WAV files directly to a local `samples/` directory.

## How it Works

`mod2skode.py` unwraps the sequence timeline of a MOD file and generates 4 parallel Skode sequences. Because Skode patterns have a maximum length of 128 steps, the converter dynamically maps every two 64-row MOD sequences into a single Skode pattern (e.g., MOD sequences 0 and 1 are mapped to Skode steps 0-63 and 64-127).

To maintain perfect synchronization between the 4 hardware channels during playback, the converter creates a **Master Conductor Pattern** (`y127`). As each track finishes a 128-step block, it emits a UDP control event (`ce {id}`). The REPL catches this event and fires a macro (`e>{id}`) that gracefully stops the old patterns and queues (`zq1`) the next patterns to lock in perfectly on the downbeat.

## Supported Tracker Effects

The converter aggressively translates standard ProTracker FX into idiomatic Skode commands:

- **`0x0` (Arpeggio):** Handled via exact tick-based time-defers (`+0.0104 n{note}`) generating precise micro-arpeggios across the row.
- **`0x1` / `0x2` (Portamento Up/Down):** Translated into fractional frequency bends (`fb`) incremented tick-by-tick over the row's duration.
- **`0x3` (Tone Portamento / Glide):** Mapped natively to Skode's glissando (`g<time>`) functionality, bypassing envelope re-triggering for perfectly smooth sweeps.
- **`0x4` (Vibrato):** Translates into Skode LFO Frequency Modulation routing using a dedicated shadow voice (`v4-v7`).
- **`0x6` (Vibrato + Vol Slide):** Combines LFO FM routing with fractional amplitude defers.
- **`0xA` (Volume Slide):** Fractional amplitude fades (`a{db}`) executed on micro-ticks.
- **`0xC` (Set Volume):** Directly updates voice amplitude (`a{db}`).
- **`0xE9x` (Retrigger Note):** Calculates step sub-divisions and uses Skode's hardware step-ratchet command (`z*{count}`).
- **`0xEDx` (Note Delay):** Uses Skode's time-defer (`+<time>`) to delay note execution by precise tick subdivisions.
- **`0xF` (Speed / Tempo):**
  - `< 32`: Sets the step speed dynamically via clock modulo (`z%<speed>`).
  - `>= 32`: Analyzes the first row of the song to emit an explicit Master Clock start tempo (`M <bpm> <ticks>`).

## Limitations

- **Mid-song Tempo Changes:** While initial tempos are supported, mid-song BPM changes (`0xF >= 32`) are not fully handled because Skode's `M` command is currently immediate-only and cannot be embedded safely inside sequence grid steps.
- **`Bxx` (Position Jump) and `Dxx` (Pattern Break):** The converter linearly unrolls the MOD sequence array from start to finish. Songs that rely heavily on `Bxx` or `Dxx` to loop back or jump over blank patterns dynamically may not translate their song structure perfectly.
- **32-Opcode Limit:** Heavily stacked tracker effects (e.g., Vibrato + Vol Slide + Pitch Bend on a single row) might exceed Skode's internal 32-opcode-per-step limit, triggering a compiler warning during conversion.

## License

MIT License. Copyright (c) Octetta. See `LICENSE` for details.
