//// Core conversion logic from parsed MOD data to Skode 0.83.0 scripts and WAV assets.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import mod_to_skode/mod_parser
import mod_to_skode/types.{
  type ConversionResult, type Instrument, type ModFile, type Note,
  type StereoMode, ConversionResult, Note, StereoAmiga, StereoHeadphone,
  StereoMono,
}

@external(javascript, "../skred_ffi.mjs", "formatFloat")
pub fn format_float(val: Float, decimals: Int) -> String

@external(javascript, "../skred_ffi.mjs", "pcm8ToWav")
pub fn pcm8_to_wav(raw: BitArray) -> BitArray

@external(javascript, "../skred_ffi.mjs", "sliceBitArray")
pub fn slice_bit_array(raw: BitArray, start: Int, length: Int) -> BitArray

pub fn make_range(start: Int, end: Int) -> List(Int) {
  case start <= end {
    True -> [start, ..make_range(start + 1, end)]
    False -> []
  }
}

/// Sine table lookup matching ProTracker (32 entries)
pub const pt_sine: List(Int) = [
  0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253, 255,
  253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
]

pub fn vol_to_db(v: Int) -> Float {
  case v <= 0 {
    True -> -100.0
    False -> {
      let ratio = int.to_float(v) /. 64.0
      case float.logarithm(ratio) {
        Ok(ln_ratio) -> {
          let log10_val = ln_ratio /. 2.302585092994046
          20.0 *. log10_val -. 10.0
        }
        Error(_) -> -100.0
      }
    }
  }
}

pub fn format_cents(cents: Float) -> String {
  let r = float.round(cents)
  case float.absolute_value(cents -. int.to_float(r)) <. 0.0001 {
    True -> int.to_string(r)
    False -> format_float(cents, 1)
  }
}

pub fn format_duration(seconds: Float) -> String {
  let total_secs = float.truncate(seconds)
  let mins = total_secs / 60
  let secs = total_secs % 60
  let mins_str = case mins < 10 {
    True -> "0" <> int.to_string(mins)
    False -> int.to_string(mins)
  }
  let secs_str = case secs < 10 {
    True -> "0" <> int.to_string(secs)
    False -> int.to_string(secs)
  }
  mins_str <> ":" <> secs_str
}

pub type UnrolledRow {
  UnrolledRow(
    seq_idx: Int,
    pat_idx: Int,
    row_idx: Int,
    notes: List(Note),
    is_pat_delay_repeat: Bool,
  )
}

pub type ChannelState {
  ChannelState(
    vol: Int,
    note: Int,
    cents: Float,
    period: Int,
    target_period: Int,
    portamento_speed: Int,
    vib_speed: Int,
    vol_slide_speed: Int,
    vib_depth: Int,
    vib_active: Bool,
    vib_applied: Int,
    trem_active: Bool,
    trem_applied_speed: Int,
    trem_applied_depth: Int,
    trem_applied_tempo: Int,
    trem_applied_vol: Int,
    trem_speed: Int,
    trem_depth: Int,
    current_wave: Int,
    current_inst_id: Int,
    sample_offset_mem: Int,
    active_vs_offset: Int,
    current_fb: Float,
  )
}

pub fn initial_channel_state() -> ChannelState {
  ChannelState(
    vol: 64,
    note: 0,
    cents: 0.0,
    period: 0,
    target_period: 0,
    portamento_speed: 0,
    vib_speed: 0,
    vol_slide_speed: 0,
    vib_depth: 0,
    vib_active: False,
    vib_applied: 0,
    trem_active: False,
    trem_applied_speed: 0,
    trem_applied_depth: 0,
    trem_applied_tempo: 0,
    trem_applied_vol: 0,
    trem_speed: 0,
    trem_depth: 0,
    current_wave: 0,
    current_inst_id: 0,
    sample_offset_mem: 0,
    active_vs_offset: 0,
    current_fb: 0.0,
  )
}

pub type TickRecord {
  TickRecord(t: Int, is_retrig: Bool, fb: Float, vol: Int, arp: Option(Int))
}

/// Unrolls MOD pattern sequence respecting flow control.
pub fn unroll_mod_rows(
  patterns: List(List(List(Note))),
  sequence: List(Int),
  restart_pos: Int,
) -> #(List(UnrolledRow), Dict(Int, Int), Option(Int)) {
  let seq_dict =
    list.index_map(sequence, fn(p, idx) { #(idx, p) })
    |> dict.from_list

  let pat_dict =
    list.index_map(patterns, fn(pat, idx) { #(idx, pat) })
    |> dict.from_list

  let seq_len = list.length(sequence)
  let loop_target_seq = case restart_pos < seq_len {
    True -> Some(restart_pos)
    False -> None
  }

  unroll_seq_loop(
    seq_dict,
    pat_dict,
    seq_len,
    0,
    0,
    set.new(),
    dict.new(),
    loop_target_seq,
    [],
  )
}

fn unroll_seq_loop(
  seq_dict: Dict(Int, Int),
  pat_dict: Dict(Int, List(List(Note))),
  seq_len: Int,
  seq_idx: Int,
  next_start_row: Int,
  visited: Set(Int),
  seq_start_step: Dict(Int, Int),
  loop_target_seq: Option(Int),
  unrolled_acc: List(UnrolledRow),
) -> #(List(UnrolledRow), Dict(Int, Int), Option(Int)) {
  case seq_idx >= 0 && seq_idx < seq_len {
    False -> {
      let final_unrolled = list.reverse(unrolled_acc)
      let final_target_step = case loop_target_seq {
        Some(s) -> dict.get(seq_start_step, s) |> option.from_result
        None -> None
      }
      #(final_unrolled, seq_start_step, final_target_step)
    }
    True -> {
      let current_step_len = list.length(unrolled_acc)
      let new_seq_start = case dict.has_key(seq_start_step, seq_idx) {
        True -> seq_start_step
        False -> dict.insert(seq_start_step, seq_idx, current_step_len)
      }
      let new_visited = set.insert(visited, seq_idx)

      case
        dict.get(seq_dict, seq_idx),
        dict.get(pat_dict, dict.get(seq_dict, seq_idx) |> result.unwrap(0))
      {
        Ok(p_idx), Ok(pattern) -> {
          let pat_rows =
            list.index_map(pattern, fn(r, idx) { #(idx, r) }) |> dict.from_list

          let #(next_s_idx, next_s_row, updated_target, new_acc) =
            unroll_pattern_rows(
              pat_rows,
              seq_len,
              seq_idx,
              p_idx,
              next_start_row,
              dict.new(),
              dict.new(),
              new_visited,
              loop_target_seq,
              unrolled_acc,
            )

          unroll_seq_loop(
            seq_dict,
            pat_dict,
            seq_len,
            next_s_idx,
            next_s_row,
            new_visited,
            new_seq_start,
            updated_target,
            new_acc,
          )
        }
        _, _ -> {
          let final_unrolled = list.reverse(unrolled_acc)
          let final_target_step = case loop_target_seq {
            Some(s) -> dict.get(new_seq_start, s) |> option.from_result
            None -> None
          }
          #(final_unrolled, new_seq_start, final_target_step)
        }
      }
    }
  }
}

fn unroll_pattern_rows(
  pat_rows: Dict(Int, List(Note)),
  seq_len: Int,
  seq_idx: Int,
  p_idx: Int,
  r: Int,
  loop_start_r: Dict(Int, Int),
  loop_count: Dict(Int, Int),
  visited: Set(Int),
  loop_target_seq: Option(Int),
  acc: List(UnrolledRow),
) -> #(Int, Int, Option(Int), List(UnrolledRow)) {
  case r >= 0 && r < 64 {
    False -> #(seq_idx + 1, 0, loop_target_seq, acc)
    True -> {
      case dict.get(pat_rows, r) {
        Error(_) -> #(seq_idx + 1, 0, loop_target_seq, acc)
        Ok(row) -> {
          let #(
            pos_jump,
            pat_break,
            pat_delay,
            e6_target,
            new_l_start,
            new_l_count,
          ) =
            scan_row_flow(
              row,
              r,
              0,
              None,
              None,
              0,
              None,
              loop_start_r,
              loop_count,
            )

          let acc_with_row = [UnrolledRow(seq_idx, p_idx, r, row, False), ..acc]

          let acc_with_delays =
            add_pattern_delays(acc_with_row, pat_delay, seq_idx, p_idx, r, row)

          case e6_target {
            Some(target) -> {
              unroll_pattern_rows(
                pat_rows,
                seq_len,
                seq_idx,
                p_idx,
                target,
                new_l_start,
                new_l_count,
                visited,
                loop_target_seq,
                acc_with_delays,
              )
            }
            None -> {
              case pos_jump != None || pat_break != None {
                True -> {
                  let target_seq = case pos_jump {
                    Some(j) -> j
                    None -> seq_idx + 1
                  }
                  let target_row = case pat_break {
                    Some(b) -> b
                    None -> 0
                  }

                  case
                    pos_jump != None
                    && {
                      set.contains(visited, target_seq) || target_seq >= seq_len
                    }
                  {
                    True -> {
                      let final_target = case target_seq < seq_len {
                        True -> Some(target_seq)
                        False -> loop_target_seq
                      }
                      #(seq_len, 0, final_target, acc_with_delays)
                    }
                    False -> {
                      #(
                        target_seq,
                        target_row,
                        loop_target_seq,
                        acc_with_delays,
                      )
                    }
                  }
                }
                False -> {
                  unroll_pattern_rows(
                    pat_rows,
                    seq_len,
                    seq_idx,
                    p_idx,
                    r + 1,
                    new_l_start,
                    new_l_count,
                    visited,
                    loop_target_seq,
                    acc_with_delays,
                  )
                }
              }
            }
          }
        }
      }
    }
  }
}

fn scan_row_flow(
  notes: List(Note),
  r: Int,
  c: Int,
  pos_jump: Option(Int),
  pat_break: Option(Int),
  pat_delay: Int,
  e6_target: Option(Int),
  l_start: Dict(Int, Int),
  l_count: Dict(Int, Int),
) -> #(
  Option(Int),
  Option(Int),
  Int,
  Option(Int),
  Dict(Int, Int),
  Dict(Int, Int),
) {
  case notes {
    [] -> #(pos_jump, pat_break, pat_delay, e6_target, l_start, l_count)
    [note, ..rest] -> {
      let eff = note.effect
      let param = note.param

      let new_pj = case eff == 0xB {
        True -> Some(param)
        False -> pos_jump
      }

      let new_pb = case eff == 0xD {
        True -> {
          let b =
            { int.bitwise_shift_right(param, 4) * 10 }
            + int.bitwise_and(param, 0x0F)
          case b >= 64 {
            True -> Some(0)
            False -> Some(b)
          }
        }
        False -> pat_break
      }

      let ext_type = int.bitwise_shift_right(param, 4)
      let ext_val = int.bitwise_and(param, 0x0F)

      let #(new_e6, updated_start, updated_count, new_delay) = case eff == 0xE {
        True -> {
          case ext_type {
            0x6 -> {
              case ext_val == 0 {
                True -> #(
                  e6_target,
                  dict.insert(l_start, c, r),
                  l_count,
                  pat_delay,
                )
                False -> {
                  let cur_count = dict.get(l_count, c) |> result.unwrap(0)
                  case cur_count == 0 {
                    True -> {
                      let start_r = dict.get(l_start, c) |> result.unwrap(0)
                      #(
                        Some(start_r),
                        l_start,
                        dict.insert(l_count, c, ext_val),
                        pat_delay,
                      )
                    }
                    False -> {
                      let rem = cur_count - 1
                      let new_cnt_dict = dict.insert(l_count, c, rem)
                      case rem > 0 {
                        True -> {
                          let start_r = dict.get(l_start, c) |> result.unwrap(0)
                          #(Some(start_r), l_start, new_cnt_dict, pat_delay)
                        }
                        False -> #(e6_target, l_start, new_cnt_dict, pat_delay)
                      }
                    }
                  }
                }
              }
            }
            0xE -> #(e6_target, l_start, l_count, ext_val)
            _ -> #(e6_target, l_start, l_count, pat_delay)
          }
        }
        False -> #(e6_target, l_start, l_count, pat_delay)
      }

      scan_row_flow(
        rest,
        r,
        c + 1,
        new_pj,
        new_pb,
        new_delay,
        new_e6,
        updated_start,
        updated_count,
      )
    }
  }
}

fn add_pattern_delays(
  acc: List(UnrolledRow),
  count: Int,
  seq_idx: Int,
  pat_idx: Int,
  r: Int,
  row: List(Note),
) -> List(UnrolledRow) {
  case count <= 0 {
    True -> acc
    False -> {
      add_pattern_delays(
        [UnrolledRow(seq_idx, pat_idx, r, row, True), ..acc],
        count - 1,
        seq_idx,
        pat_idx,
        r,
        row,
      )
    }
  }
}

pub type ConvertOptions {
  ConvertOptions(stereo_mode: StereoMode)
}

pub fn default_options() -> ConvertOptions {
  ConvertOptions(stereo_mode: StereoHeadphone)
}

pub fn get_channel_pan(c: Int, mode: StereoMode) -> String {
  case mode {
    StereoMono -> "0"
    StereoHeadphone ->
      case c % 4 == 0 || c % 4 == 3 {
        True -> "-0.75"
        False -> "0.75"
      }
    StereoAmiga ->
      case c % 4 == 0 || c % 4 == 3 {
        True -> "-1.0"
        False -> "1.0"
      }
  }
}

pub fn build_live_stereo_command(nch: Int, mode: StereoMode) -> String {
  list.map(make_range(0, nch - 1), fn(c) {
    "v" <> int.to_string(c) <> " p" <> get_channel_pan(c, mode)
  })
  |> string.join(" ")
}

/// Converts a parsed ModFile into Skode 0.83.0 script and WAV samples with default options.
pub fn convert(mod: ModFile) -> Result(ConversionResult, String) {
  convert_with_options(mod, default_options())
}

/// Converts a parsed ModFile into Skode 0.83.0 script and WAV samples with custom options.
pub fn convert_with_options(
  mod: ModFile,
  options: ConvertOptions,
) -> Result(ConversionResult, String) {
  let inst_map =
    list.map(mod.instruments, fn(ins) { #(ins.id, ins) })
    |> dict.from_list

  let nch = mod.num_channels

  // Initial tempo and speed
  let #(initial_speed, initial_tempo) = case mod.patterns, mod.sequence {
    [_, ..], [first_seq, ..] -> {
      let first_pat =
        list.drop(mod.patterns, first_seq) |> list.first |> result.unwrap([])
      let first_row = list.first(first_pat) |> result.unwrap([])
      find_initial_speed_tempo(first_row, 6, 125)
    }
    _, _ -> #(6, 125)
  }

  let #(unrolled_rows, _seq_steps, _loop_target_step) =
    unroll_mod_rows(mod.patterns, mod.sequence, mod.restart_pos)

  let total_rows = list.length(unrolled_rows)
  case total_rows == 0 {
    True -> Error("MOD file contains 0 playable rows.")
    False -> {
      let total_steps = total_rows + 1

      // Header comment and initialization
      let init_sb = [
        "# Converted from " <> mod.filename <> "\n",
        "M " <> int.to_string(initial_tempo) <> " 96\n\n",
        "# === INITIALIZATION ===\n",
        string.join(
          list.map(make_range(0, nch * 2 - 1), fn(i) { "S" <> int.to_string(i) }),
          " ",
        )
          <> "\n",
        "DL 1 0 0 0 0 15 10\n",
      ]

      let voice_inits =
        list.map(make_range(0, nch - 1), fn(c) {
          let pan = get_channel_pan(c, options.stereo_mode)
          let c_str = int.to_string(c)
          let lfo_str = int.to_string(c + nch)
          "v"
          <> c_str
          <> " [ch "
          <> int.to_string(c + 1)
          <> "] vt w0 m0 p"
          <> pan
          <> " t0,0,1,0 s0.002,1 g0.001,2 g0 fbp24 a-100 F-1 A-1\n"
          <> "v"
          <> lfo_str
          <> " [lfo "
          <> int.to_string(c + 1)
          <> "] vt w0 m1 t0,0,1,0 a-10 f20000 F-1 A-1\n"
        })

      // Instrument definitions
      let inst_defs =
        list.filter_map(mod.instruments, fn(ins) {
          case ins.len > 2 {
            True -> {
              let w_id = int.to_string(100 + ins.id)
              let id_padded = case ins.id < 10 {
                True -> "0" <> int.to_string(ins.id)
                False -> int.to_string(ins.id)
              }
              let ws_line =
                "[samples/inst_" <> id_padded <> ".wav] /ws " <> w_id <> "\n"
              let clean_name = case string.trim(ins.name) {
                "" -> "inst_" <> id_padded
                other ->
                  string.replace(other, "[", "(") |> string.replace("]", ")")
              }
              let wt_line = "[" <> clean_name <> "] wt " <> w_id <> "\n"
              let wl_line = case ins.wants_loop {
                True -> {
                  let loop_end = int.min(ins.len, ins.loop_start + ins.loop_len)
                  "WL "
                  <> w_id
                  <> ","
                  <> int.to_string(ins.loop_start)
                  <> ","
                  <> int.to_string(loop_end)
                  <> "\n"
                }
                False -> ""
              }
              Ok(ws_line <> wt_line <> wl_line)
            }
            False -> Error(Nil)
          }
        })

      // Patterns setup: y0..y{nch} %initial_speed
      let pat_speed_defs =
        list.map(make_range(0, nch), fn(c) {
          "y"
          <> int.to_string(c)
          <> " %"
          <> int.to_string(initial_speed)
          <> "\n"
        })

      let s_last = total_steps - 1
      let master_cond = [
        "# === THE MASTER CONDUCTOR ===\n",
        "# y127 is an empty pattern set as the 'Master' (yp127).\n",
        "# Because it is the master, any pattern launched with 'zq1' (queue start)\n",
        "# will wait perfectly in sync until y127 reaches step 0 (the downbeat).\n",
        "y127 %"
          <> int.to_string(initial_speed)
          <> " [v0] x"
          <> int.to_string(s_last)
          <> " yp127\n\n",
      ]

      // Initial channel states
      let initial_channels =
        list.map(make_range(0, nch - 1), fn(c) { #(c, initial_channel_state()) })
        |> dict.from_list

      // Generate pattern rows
      let #(pattern_texts, _final_chans, total_duration, step_times) =
        generate_all_rows(
          unrolled_rows,
          0,
          nch,
          initial_speed,
          initial_tempo,
          initial_channels,
          inst_map,
          dict.new(),
          0.0,
          dict.new(),
        )

      // Natural song end step
      let end_step = s_last
      let end_ch_lines =
        list.map(make_range(0, nch - 1), fn(c) {
          let line = case c == 0 {
            True -> "[Z0 ce 127 v0] x" <> int.to_string(end_step) <> "\n"
            False ->
              "[v"
              <> int.to_string(c)
              <> "] x"
              <> int.to_string(end_step)
              <> "\n"
          }
          #(c, line)
        })

      let end_cond_line = #(
        nch,
        "[Z0 +2.0 ce 127] x" <> int.to_string(end_step) <> "\n",
      )

      let all_end_lines = [end_cond_line, ..end_ch_lines]
      let full_pattern_texts =
        list.fold(all_end_lines, pattern_texts, fn(acc, item) {
          let #(ch_id, line) = item
          let existing = dict.get(acc, ch_id) |> result.unwrap("")
          dict.insert(acc, ch_id, existing <> line)
        })

      // Format pattern tracks y0..y{nch}
      let pat_tracks =
        list.map(make_range(0, nch), fn(c) {
          let text = dict.get(full_pattern_texts, c) |> result.unwrap("")
          case c < nch {
            True ->
              "# ==============================================================================\n"
              <> "# TRACK "
              <> int.to_string(c)
              <> " (Channel "
              <> int.to_string(c + 1)
              <> ")\n"
              <> "# ==============================================================================\n"
              <> "y"
              <> int.to_string(c)
              <> "\n"
              <> "[#] x "
              <> int.to_string(s_last)
              <> "\n"
              <> text
            False ->
              "# ==============================================================================\n"
              <> "# CONDUCTOR TRACK (Speed & Tempo Automation)\n"
              <> "# ==============================================================================\n"
              <> "y"
              <> int.to_string(c)
              <> "\n"
              <> "[#] x "
              <> int.to_string(s_last)
              <> "\n"
              <> text
          }
        })

      // Stop & Play Macros matching Skred v0.83.0
      let stop_cmds = "/cer 0 Z0 O DQ ?ce!"
      let end_macros =
        "\n# === PATTERN TRANSITIONS & END OF SONG LOOP ===\n"
        <> "["
        <> stop_cmds
        <> "] /ceb 4 127\n\n/cer 1\n\n"

      let pat_list =
        list.map(make_range(0, nch), int.to_string)
        |> list.append(["127"])
        |> string.join(" ")
      let play_cmds = "?ce! /cer 1 Z0 Z! (" <> pat_list <> ") Z>"
      let efx_cmds =
        "v0 p0 r1 ds .5 v1 p0 r1 ds .5 v2 p0 r1 ds .5 v3 p0 r1 ds .5 DL 1 0 0 0 0 15 10"
      let nofx_cmds =
        list.map(make_range(0, nch - 1), fn(c) {
          "v"
          <> int.to_string(c)
          <> " p"
          <> get_channel_pan(c, options.stereo_mode)
        })
        |> string.join(" ")

      let macro_defs = [
        "# === MACROS ===\n",
        "# The file does not start automatically. Type 'play' to begin, and 'stop' to halt.\n",
        "[play]: " <> play_cmds <> ";\n",
        "[stop]: " <> stop_cmds <> ";\n",
        "[efx!]: " <> efx_cmds <> ";\n\n",
        "[nofx]: " <> nofx_cmds <> ";\n\n",
      ]

      let raw_credits =
        list.map(mod.instruments, fn(ins) {
          let clean = string.trim(ins.name)
          string.replace(clean, "[", "(") |> string.replace("]", ")")
        })
      let trimmed_start = list.drop_while(raw_credits, fn(s) { s == "" })
      let trimmed =
        list.reverse(trimmed_start)
        |> list.drop_while(fn(s) { s == "" })
        |> list.reverse
      let #(_, collapsed) =
        list.fold(trimmed, #(False, []), fn(acc, line) {
          let #(prev_empty, res) = acc
          case line == "" {
            True -> {
              case prev_empty {
                True -> #(True, res)
                False -> #(True, [line, ..res])
              }
            }
            False -> #(False, [line, ..res])
          }
        })
      let credits_lines =
        list.reverse(collapsed)
        |> list.map(fn(line) { "[" <> line <> "] puts\n" })

      let banner_clean = case string.trim(mod.title) {
        "" -> mod.filename
        t -> mod.filename <> " ('" <> t <> "')"
      }
      let banner_safe =
        string.replace(banner_clean, "[", "(") |> string.replace("]", ")")
      let banner_defs =
        list.flatten([
          ["# === INFO DISPLAY ON LOAD ===\n", "[" <> banner_safe <> "] puts\n"],
          credits_lines,
          case credits_lines {
            [] -> []
            _ -> ["[] puts\n"]
          },
          [
            "[play : " <> play_cmds <> "] puts\n",
            "[stop : " <> stop_cmds <> "] puts\n",
            "[efx! : " <> efx_cmds <> "] puts\n",
            "[nofx : " <> nofx_cmds <> "] puts\n",
          ],
        ])

      let all_skode_parts =
        list.flatten([
          init_sb,
          voice_inits,
          ["\n"],
          inst_defs,
          ["\n"],
          pat_speed_defs,
          master_cond,
          pat_tracks,
          [end_macros],
          macro_defs,
          banner_defs,
        ])
      let skode_text = string.join(all_skode_parts, "")

      // Generate WAV sample assets from raw PCM bytes
      let samples =
        extract_samples(
          mod.instruments,
          mod.sample_data_offset,
          mod.raw_bytes,
          [],
        )

      Ok(ConversionResult(
        skode_text: skode_text,
        samples: samples,
        num_channels: nch,
        total_rows: total_rows,
        initial_tempo: initial_tempo,
        initial_speed: initial_speed,
        duration_seconds: total_duration,
        step_times: step_times,
      ))
    }
  }
}

fn find_initial_speed_tempo(
  row: List(Note),
  def_speed: Int,
  def_tempo: Int,
) -> #(Int, Int) {
  case row {
    [] -> #(def_speed, def_tempo)
    [note, ..rest] -> {
      case note.effect == 0xF && note.param > 0 {
        True -> {
          case note.param < 32 {
            True -> find_initial_speed_tempo(rest, note.param, def_tempo)
            False -> find_initial_speed_tempo(rest, def_speed, note.param)
          }
        }
        False -> find_initial_speed_tempo(rest, def_speed, def_tempo)
      }
    }
  }
}

fn generate_all_rows(
  rows: List(UnrolledRow),
  global_idx: Int,
  nch: Int,
  cur_speed: Int,
  cur_tempo: Int,
  chans: Dict(Int, ChannelState),
  inst_map: Dict(Int, Instrument),
  pat_texts: Dict(Int, String),
  duration_acc: Float,
  step_times: Dict(Int, Float),
) -> #(Dict(Int, String), Dict(Int, ChannelState), Float, Dict(Int, Float)) {
  case rows {
    [] -> #(pat_texts, chans, duration_acc, step_times)
    [u_row, ..rest_rows] -> {
      let notes = u_row.notes
      let is_delay = u_row.is_pat_delay_repeat

      let updated_step_times = dict.insert(step_times, global_idx, duration_acc)

      // Scan row for speed/tempo changes
      let #(row_speed, row_tempo) =
        scan_speed_tempo(notes, None, None, global_idx)
      let new_speed = option.unwrap(row_speed, cur_speed)
      let new_tempo = option.unwrap(row_tempo, cur_tempo)

      let row_duration =
        int.to_float(new_speed) *. 2.5 /. int.to_float(new_tempo)

      // Process each channel 0..nch-1
      let #(updated_chans, ch_cmds_list) =
        process_channels(
          notes,
          0,
          nch,
          global_idx,
          new_speed,
          new_tempo,
          row_speed,
          row_tempo,
          is_delay,
          chans,
          inst_map,
          [],
        )

      // Conductor track commands (channel nch)
      let cond_cmds = build_conductor_cmds(row_speed, row_tempo, is_delay)

      // Section header comment for pattern/bar boundaries
      let section_header = case u_row.is_pat_delay_repeat {
        True ->
          "\n# --- Pattern Delay Repeat (Step "
          <> int.to_string(global_idx)
          <> ") ---\n"
        False ->
          case u_row.row_idx {
            0 ->
              "\n# --- Order "
              <> pad_2(u_row.seq_idx)
              <> " | Pattern "
              <> pad_2(u_row.pat_idx)
              <> " (Step "
              <> int.to_string(global_idx)
              <> ") ---\n"
            r if r % 16 == 0 ->
              "\n# --- Row "
              <> int.to_string(r)
              <> " (Step "
              <> int.to_string(global_idx)
              <> ") ---\n"
            _ -> ""
          }
      }

      let updated_pat_texts =
        list.fold(ch_cmds_list, pat_texts, fn(acc, item) {
          let #(c, cmd_str, comment) = item
          let actual_cmd = case cmd_str, rest_rows {
            "", [] -> "v" <> int.to_string(c)
            _, _ -> cmd_str
          }
          let comment_suffix = case comment {
            "" -> ""
            _ -> "   # " <> comment
          }
          let line = case actual_cmd {
            "" -> section_header
            _ ->
              section_header
              <> "["
              <> actual_cmd
              <> "] x"
              <> int.to_string(global_idx)
              <> comment_suffix
              <> "\n"
          }
          let existing = dict.get(acc, c) |> result.unwrap("")
          dict.insert(acc, c, existing <> line)
        })

      let final_pat_texts = case cond_cmds {
        "" -> updated_pat_texts
        _ -> {
          let cond_comment = case row_speed, row_tempo {
            Some(s), Some(t) ->
              "Speed "
              <> int.to_string(s)
              <> " | Tempo "
              <> int.to_string(t)
              <> " BPM"
            Some(s), None -> "Speed " <> int.to_string(s)
            None, Some(t) -> "Tempo " <> int.to_string(t) <> " BPM"
            None, None -> ""
          }
          let cond_comment_suffix = case cond_comment {
            "" -> ""
            _ -> "   # " <> cond_comment
          }
          let line =
            section_header
            <> "["
            <> cond_cmds
            <> "] x"
            <> int.to_string(global_idx)
            <> cond_comment_suffix
            <> "\n"
          let existing = dict.get(updated_pat_texts, nch) |> result.unwrap("")
          dict.insert(updated_pat_texts, nch, existing <> line)
        }
      }

      generate_all_rows(
        rest_rows,
        global_idx + 1,
        nch,
        new_speed,
        new_tempo,
        updated_chans,
        inst_map,
        final_pat_texts,
        duration_acc +. row_duration,
        updated_step_times,
      )
    }
  }
}

fn scan_speed_tempo(
  notes: List(Note),
  speed_acc: Option(Int),
  tempo_acc: Option(Int),
  global_idx: Int,
) -> #(Option(Int), Option(Int)) {
  case notes {
    [] -> #(speed_acc, tempo_acc)
    [n, ..rest] -> {
      case n.effect == 0xF && n.param > 0 {
        True -> {
          case n.param < 32 {
            True -> scan_speed_tempo(rest, Some(n.param), tempo_acc, global_idx)
            False -> {
              case global_idx > 0 {
                True ->
                  scan_speed_tempo(rest, speed_acc, Some(n.param), global_idx)
                False ->
                  scan_speed_tempo(rest, speed_acc, tempo_acc, global_idx)
              }
            }
          }
        }
        False -> scan_speed_tempo(rest, speed_acc, tempo_acc, global_idx)
      }
    }
  }
}

fn build_conductor_cmds(
  row_speed: Option(Int),
  row_tempo: Option(Int),
  is_delay: Bool,
) -> String {
  case is_delay {
    True -> ""
    False -> {
      let parts = []
      let parts = case row_speed {
        Some(s) -> ["z%" <> int.to_string(s), ..parts]
        None -> parts
      }
      let parts = case row_tempo {
        Some(t) -> ["M" <> int.to_string(t) <> ",96", ..parts]
        None -> parts
      }
      string.join(list.reverse(parts), " ")
    }
  }
}

fn pad_2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn midi_to_note_name(midi: Int) -> String {
  let note_names = [
    "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-",
  ]
  let semitone = midi % 12
  let oct = { midi / 12 } - 1
  let name =
    list.drop(note_names, semitone)
    |> list.first
    |> result.unwrap("C-")
  name <> int.to_string(oct)
}

fn effect_description(eff: Int, param: Int) -> String {
  let ext_type = int.bitwise_shift_right(param, 4)
  case eff {
    0x0 if param > 0 -> "Arp"
    0x1 -> "Porta Up"
    0x2 -> "Porta Down"
    0x3 -> "Tone Porta"
    0x4 -> "Vibrato"
    0x5 -> "Porta+VolSlide"
    0x6 -> "Vib+VolSlide"
    0x7 -> "Tremolo"
    0x8 -> "Pan"
    0x9 -> "Sample Offset"
    0xA -> "Vol Slide"
    0xB -> "Pos Jump"
    0xC -> "Vol " <> int.to_string(param)
    0xD -> "Pat Break"
    0xE if ext_type == 0x0 -> "Filter Toggle"
    0xE if ext_type == 0x1 -> "Fine Porta Up"
    0xE if ext_type == 0x2 -> "Fine Porta Down"
    0xE if ext_type == 0x3 -> "Glissando"
    0xE if ext_type == 0x4 -> "Vib Wave"
    0xE if ext_type == 0x5 -> "Finetune"
    0xE if ext_type == 0x6 -> "Pattern Loop"
    0xE if ext_type == 0x7 -> "Trem Wave"
    0xE if ext_type == 0x8 -> "Pan"
    0xE if ext_type == 0x9 -> "Retrig"
    0xE if ext_type == 0xA -> "Fine VolSlide Up"
    0xE if ext_type == 0xB -> "Fine VolSlide Down"
    0xE if ext_type == 0xC -> "Note Cut"
    0xE if ext_type == 0xD -> "Note Delay"
    0xE if ext_type == 0xE -> "Pattern Delay"
    0xE if ext_type == 0xF -> "Invert Loop"
    0xF if param > 0 && param < 32 -> "Speed " <> int.to_string(param)
    0xF if param >= 32 -> "BPM " <> int.to_string(param)
    _ -> ""
  }
}

fn build_note_comment(note: Note, inst_map: Dict(Int, Instrument)) -> String {
  let note_part = case note.midi {
    Some(m) -> midi_to_note_name(m)
    None -> ""
  }

  let inst_part = case note.inst > 0 {
    True -> {
      let id_str = pad_2(note.inst)
      case dict.get(inst_map, note.inst) {
        Ok(ins) -> {
          let clean = string.trim(ins.name)
          case clean == "" {
            True -> "Inst " <> id_str
            False -> id_str <> " \"" <> clean <> "\""
          }
        }
        Error(_) -> "Inst " <> id_str
      }
    }
    False -> ""
  }

  let eff_part = effect_description(note.effect, note.param)

  let parts = []
  let parts = case note_part != "" {
    True -> [note_part, ..parts]
    False -> parts
  }
  let parts = case inst_part != "" {
    True -> [inst_part, ..parts]
    False -> parts
  }
  let parts = case eff_part != "" {
    True -> [eff_part, ..parts]
    False -> parts
  }

  string.join(list.reverse(parts), " | ")
}

fn process_channels(
  notes: List(Note),
  c: Int,
  nch: Int,
  global_idx: Int,
  cur_speed: Int,
  cur_tempo: Int,
  row_speed: Option(Int),
  row_tempo: Option(Int),
  is_delay: Bool,
  chans: Dict(Int, ChannelState),
  inst_map: Dict(Int, Instrument),
  acc: List(#(Int, String, String)),
) -> #(Dict(Int, ChannelState), List(#(Int, String, String))) {
  case c >= nch {
    True -> #(chans, list.reverse(acc))
    False -> {
      let raw_note: Note =
        list.drop(notes, c)
        |> list.first
        |> result.unwrap(Note(None, 0, 0, 0, 0))
      let note: Note = case is_delay {
        True -> Note(None, 0, raw_note.effect, raw_note.param, 0)
        False -> raw_note
      }

      let ch = dict.get(chans, c) |> result.unwrap(initial_channel_state())

      let #(new_ch, cmd_str, comment) =
        process_single_channel(
          c,
          nch,
          global_idx,
          cur_speed,
          cur_tempo,
          row_speed,
          row_tempo,
          is_delay,
          note,
          ch,
          inst_map,
        )

      let updated_chans = dict.insert(chans, c, new_ch)
      process_channels(
        notes,
        c + 1,
        nch,
        global_idx,
        cur_speed,
        cur_tempo,
        row_speed,
        row_tempo,
        is_delay,
        updated_chans,
        inst_map,
        [#(c, cmd_str, comment), ..acc],
      )
    }
  }
}

fn process_single_channel(
  c: Int,
  nch: Int,
  global_idx: Int,
  cur_speed: Int,
  cur_tempo: Int,
  row_speed: Option(Int),
  row_tempo: Option(Int),
  is_delay: Bool,
  note: Note,
  ch: ChannelState,
  inst_map: Dict(Int, Instrument),
) -> #(ChannelState, String, String) {
  let cmds = []

  // Pattern boundary: rebind voice
  let cmds = case global_idx % 64 == 0 {
    True -> ["v" <> int.to_string(c), ..cmds]
    False -> cmds
  }

  // Speed and tempo changes
  let cmds = case row_speed, is_delay {
    Some(s), False -> ["z%" <> int.to_string(s), ..cmds]
    _, _ -> cmds
  }
  let cmds = case row_tempo, c == 0, is_delay {
    Some(t), True, False -> ["M" <> int.to_string(t) <> ",96", ..cmds]
    _, _, _ -> cmds
  }

  let old_vol = ch.vol

  // Instrument lookup and assignment
  let ch_inst = case note.inst > 0 {
    True -> {
      case dict.get(inst_map, note.inst) {
        Ok(ins) -> ChannelState(..ch, current_inst_id: ins.id, vol: ins.vol)
        Error(_) -> ch
      }
    }
    False -> ch
  }

  // Portamento memory
  let ch_porta = case
    { note.effect == 0x1 || note.effect == 0x2 || note.effect == 0x3 }
    && note.param > 0
  {
    True -> ChannelState(..ch_inst, portamento_speed: note.param)
    False -> ch_inst
  }

  // Tone portamento target period
  let ch_target = case
    note.period > 0 && { note.effect == 0x3 || note.effect == 0x5 }
  {
    True -> ChannelState(..ch_porta, target_period: note.period)
    False -> ch_porta
  }

  let ext_type = int.bitwise_shift_right(note.param, 4)
  let ext_val = int.bitwise_and(note.param, 0x0F)

  let is_note_delay = note.effect == 0xE && ext_type == 0xD && ext_val > 0
  let cmds = case is_note_delay {
    True -> ["+-" <> int.to_string(ext_val), ..cmds]
    False -> cmds
  }

  // Tick 0 effects: volume and panning
  let #(ch_vol0, cmds) = case note.effect {
    0xC -> #(ChannelState(..ch_target, vol: int.clamp(note.param, 0, 64)), cmds)
    0x8 -> {
      let p_val = int.clamp(note.param, 0, 255)
      let pan = { int.to_float(p_val) -. 128.0 } /. 128.0
      #(ch_target, ["p" <> format_float(pan, 2), ..cmds])
    }
    0xE if !is_delay -> {
      case ext_type {
        0xA -> #(
          ChannelState(..ch_target, vol: int.min(64, ch_target.vol + ext_val)),
          cmds,
        )
        0xB -> #(
          ChannelState(..ch_target, vol: int.max(0, ch_target.vol - ext_val)),
          cmds,
        )
        0x8 -> {
          let pan = { int.to_float(ext_val) /. 7.5 } -. 1.0
          #(ch_target, ["p" <> format_float(pan, 2), ..cmds])
        }
        _ -> #(ch_target, cmds)
      }
    }
    _ -> #(ch_target, cmds)
  }

  // Emit volume if changed
  let cmds = case
    ch_vol0.vol != old_vol
    || { note.midi != None && note.effect != 0x3 && note.effect != 0x5 }
  {
    True -> ["a" <> format_float(vol_to_db(ch_vol0.vol), 2), ..cmds]
    False -> cmds
  }

  // Waveform switch
  let ins_opt = dict.get(inst_map, ch_vol0.current_inst_id)
  let #(ch_wave, cmds) = case ins_opt {
    Ok(ins) if ins.len > 2 -> {
      let should_switch =
        { note.midi != None && note.effect != 0x3 && note.effect != 0x5 }
        || { note.inst > 0 && ins.wants_loop && ins.len <= 512 }
      case should_switch && ch_vol0.current_wave != ins.id {
        True -> {
          let w_cmd = "w" <> int.to_string(100 + ins.id)
          let loop_cmd = case ins.wants_loop {
            True -> "B1"
            False -> "B0"
          }
          let cents_cmds = case ins.cents != ch_vol0.cents {
            True -> ["N0," <> format_cents(ins.cents)]
            False -> []
          }
          let updated =
            ChannelState(
              ..ch_vol0,
              current_wave: ins.id,
              active_vs_offset: 0,
              cents: ins.cents,
            )
          let c_acc = list.flatten([cents_cmds, [loop_cmd, w_cmd], cmds])
          #(updated, c_acc)
        }
        False -> #(ch_vol0, cmds)
      }
    }
    _ -> #(ch_vol0, cmds)
  }

  // Note trigger
  let #(ch_note, tick_cursor, cmds, note_cmd_opt) = case
    note.midi,
    note.effect != 0x3 && note.effect != 0x5
  {
    Some(midi_n), True -> {
      let ch_n0 =
        ChannelState(
          ..ch_wave,
          note: midi_n,
          period: note.period,
          vib_applied: 0,
        )

      // Sample offset 9xx
      let #(ch_off, cmds) = case note.effect == 0x9 {
        True -> {
          let new_off_mem = case note.param > 0 {
            True -> note.param * 256
            False -> ch_n0.sample_offset_mem
          }
          case ins_opt {
            Ok(ins) if new_off_mem > 0 && new_off_mem < ins.len - 2 -> {
              case ch_n0.active_vs_offset != new_off_mem {
                True -> {
                  let vs =
                    "VS"
                    <> int.to_string(new_off_mem)
                    <> ","
                    <> int.to_string(ins.len)
                  #(
                    ChannelState(
                      ..ch_n0,
                      sample_offset_mem: new_off_mem,
                      active_vs_offset: new_off_mem,
                    ),
                    [vs, ..cmds],
                  )
                }
                False -> #(
                  ChannelState(..ch_n0, sample_offset_mem: new_off_mem),
                  cmds,
                )
              }
            }
            _ -> #(ChannelState(..ch_n0, sample_offset_mem: new_off_mem), cmds)
          }
        }
        False -> {
          case ch_n0.active_vs_offset != 0 {
            True -> #(ChannelState(..ch_n0, active_vs_offset: 0), ["VS", ..cmds])
            False -> #(ch_n0, cmds)
          }
        }
      }

      // Note delay EDx
      let cur_cursor = case is_note_delay {
        True -> ext_val
        False -> 0
      }

      // Clear bend
      let #(ch_fb0, cmds) = case ch_off.current_fb != 0.0 {
        True -> #(ChannelState(..ch_off, current_fb: 0.0), ["fb0", ..cmds])
        False -> #(ch_off, cmds)
      }

      // Format note trigger
      let periods_dict = dict.from_list(mod_parser.periods_table)
      let is_exact = dict.has_key(periods_dict, note.period)
      let note_cmd = case is_exact {
        True -> "n" <> int.to_string(midi_n)
        False -> {
          let exact_midi = mod_parser.period_to_midi(note.period)
          let note_cents = { exact_midi -. int.to_float(midi_n) } *. 100.0
          case float.absolute_value(note_cents) >=. 1.0 {
            True ->
              "n" <> int.to_string(midi_n) <> "," <> format_float(note_cents, 0)
            False -> "n" <> int.to_string(midi_n)
          }
        }
      }
      #(ch_fb0, cur_cursor, [note_cmd <> " l1", ..cmds], Some(note_cmd))
    }
    _, _ -> #(ch_wave, 0, cmds, None)
  }

  // Fine Portamento E1x / E2x
  let #(ch_fine_p, cmds) = case
    note.effect == 0xE
    && { ext_type == 0x1 || ext_type == 0x2 }
    && ext_val > 0
    && ch_note.period > 0
    && !is_delay
  {
    True -> {
      let new_p = case ext_type == 0x1 {
        True -> int.max(28, ch_note.period - ext_val)
        False -> int.min(3424, ch_note.period + ext_val)
      }
      let bend = mod_parser.period_to_midi(new_p) -. int.to_float(ch_note.note)
      let fb_val = float.clamp(bend /. 24.0, -1.0, 1.0)
      let fb_cmd = case float.absolute_value(fb_val) >=. 0.0005 {
        True -> "fb" <> format_float(fb_val, 3)
        False -> "fb0"
      }
      #(ChannelState(..ch_note, period: new_p, current_fb: fb_val), [
        fb_cmd,
        ..cmds
      ])
    }
    False -> #(ch_note, cmds)
  }

  // Note cut ECx
  let #(ch_cut, cursor_after_cut, cmds) = case
    note.effect == 0xE && ext_type == 0xC
  {
    True -> {
      case ext_val == 0 {
        True -> #(ChannelState(..ch_fine_p, vol: 0), tick_cursor, [
          "a-100.00",
          ..cmds
        ])
        False if ext_val < cur_speed && ext_val >= tick_cursor -> {
          let dt = ext_val - tick_cursor
          let cut_cmd = case dt > 0 {
            True -> "+-" <> int.to_string(dt) <> " a-100.00"
            False -> "a-100.00"
          }
          #(ChannelState(..ch_fine_p, vol: 0), ext_val, [cut_cmd, ..cmds])
        }
        _ -> #(ch_fine_p, tick_cursor, cmds)
      }
    }
    False -> #(ch_fine_p, tick_cursor, cmds)
  }

  // Base bend for vibrato
  let base_fb = case ch_cut.period > 0 && ch_cut.note > 0 {
    True -> {
      let bend =
        mod_parser.period_to_midi(ch_cut.period) -. int.to_float(ch_cut.note)
      float.clamp(bend /. 24.0, -1.0, 1.0)
    }
    False -> 0.0
  }

  // Vibrato active cleanup
  let #(ch_vib_clean, cmds) = case note.effect != 0x4 && note.effect != 0x6 {
    True -> {
      case ch_cut.vib_active {
        True -> {
          let #(ch_vib, cmds) = case
            float.absolute_value(ch_cut.current_fb -. base_fb) >=. 0.0005
          {
            True -> {
              let fb_cmd = case float.absolute_value(base_fb) >=. 0.0005 {
                True -> "fb" <> format_float(base_fb, 3)
                False -> "fb0"
              }
              #(ChannelState(..ch_cut, current_fb: base_fb), [fb_cmd, ..cmds])
            }
            False -> #(ch_cut, cmds)
          }
          #(ChannelState(..ch_vib, vib_active: False), cmds)
        }
        False -> #(ch_cut, cmds)
      }
    }
    False -> {
      case float.absolute_value(ch_cut.current_fb -. base_fb) >=. 0.0005 {
        True -> {
          let fb_cmd = case float.absolute_value(base_fb) >=. 0.0005 {
            True -> "fb" <> format_float(base_fb, 3)
            False -> "fb0"
          }
          #(ChannelState(..ch_cut, current_fb: base_fb), [fb_cmd, ..cmds])
        }
        False -> #(ch_cut, cmds)
      }
    }
  }

  // Tremolo cleanup
  let #(ch_trem_clean, cmds) = case
    note.effect != 0x7 && ch_vib_clean.trem_active
  {
    True -> #(ChannelState(..ch_vib_clean, trem_active: False), ["A", ..cmds])
    False -> #(ch_vib_clean, cmds)
  }

  // Update vibrato / tremolo speeds and depths
  let ch_lfo_params = case note.effect {
    0x4 -> {
      let x = int.bitwise_shift_right(note.param, 4)
      let y = int.bitwise_and(note.param, 0x0F)
      ChannelState(
        ..ch_trem_clean,
        vib_speed: case x > 0 {
          True -> x
          False -> ch_trem_clean.vib_speed
        },
        vib_depth: case y > 0 {
          True -> y
          False -> ch_trem_clean.vib_depth
        },
        vib_active: True,
      )
    }
    0x6 -> ChannelState(..ch_trem_clean, vib_active: True)
    0x7 if note.param > 0 -> {
      let x = int.bitwise_shift_right(note.param, 4)
      let y = int.bitwise_and(note.param, 0x0F)
      ChannelState(
        ..ch_trem_clean,
        trem_speed: case x > 0 {
          True -> x
          False -> ch_trem_clean.trem_speed
        },
        trem_depth: case y > 0 {
          True -> y
          False -> ch_trem_clean.trem_depth
        },
      )
    }
    _ -> ch_trem_clean
  }

  // Tremolo LFO setup
  let #(ch_trem_setup, cmds) = case note.effect == 0x7 {
    True -> {
      let cur_trem_same =
        ch_lfo_params.trem_active
        && ch_lfo_params.trem_applied_speed == ch_lfo_params.trem_speed
        && ch_lfo_params.trem_applied_depth == ch_lfo_params.trem_depth
        && ch_lfo_params.trem_applied_tempo == cur_tempo
        && ch_lfo_params.trem_applied_vol == ch_lfo_params.vol

      case cur_trem_same {
        True -> #(ch_lfo_params, cmds)
        False -> {
          let rate_hz =
            int.to_float(ch_lfo_params.trem_speed * cur_tempo) /. 160.0
          let v_ = int.max(1, ch_lfo_params.vol) |> int.to_float
          let delta = 255.0 *. int.to_float(ch_lfo_params.trem_depth) /. 64.0
          let lo = float.max(0.0, { v_ -. delta } /. v_)
          let hi = float.min(64.0 /. v_, { v_ +. delta } /. v_)
          let d = { hi -. lo } /. 2.0
          let o = { hi +. lo } /. 2.0
          let lfo_v = int.to_string(c + nch)
          let t_cmd =
            "v"
            <> lfo_v
            <> " f"
            <> format_float(rate_hz, 2)
            <> " v"
            <> int.to_string(c)
            <> " A"
            <> lfo_v
            <> ","
            <> format_float(d, 3)
            <> ","
            <> format_float(o, 3)
          let updated =
            ChannelState(
              ..ch_lfo_params,
              trem_active: True,
              trem_applied_speed: ch_lfo_params.trem_speed,
              trem_applied_depth: ch_lfo_params.trem_depth,
              trem_applied_tempo: cur_tempo,
              trem_applied_vol: ch_lfo_params.vol,
            )
          #(updated, [t_cmd, ..cmds])
        }
      }
    }
    False -> #(ch_lfo_params, cmds)
  }

  // Volume slide speed memory
  let ch_vol_slide = case
    { note.effect == 0xA || note.effect == 0x5 || note.effect == 0x6 }
    && note.param > 0
  {
    True -> {
      let up = int.bitwise_shift_right(note.param, 4)
      let down = int.bitwise_and(note.param, 0x0F)
      let spd = case up > 0 {
        True -> up
        False -> -down
      }
      ChannelState(..ch_trem_setup, vol_slide_speed: spd)
    }
    False -> ch_trem_setup
  }

  // Retrigger interval
  let retrig_interval = case
    note.effect == 0xE && ext_type == 0x9 && ext_val > 0
  {
    True -> ext_val
    False -> 0
  }
  let retrig_cmd = case note_cmd_opt {
    Some(cmd) -> Some(cmd)
    None if ch_vol_slide.note > 0 ->
      Some("n" <> int.to_string(ch_vol_slide.note))
    _ -> None
  }

  // Simulate ticks 1..cur_speed-1
  let sine_dict = dict.from_list(list.index_map(pt_sine, fn(v, i) { #(i, v) }))
  let #(tick_records, ch_after_ticks) =
    simulate_ticks(
      1,
      cur_speed,
      note,
      ch_vol_slide,
      retrig_interval,
      sine_dict,
      [],
    )

  // Adaptive tick decimation to stay within budget
  let #(cand_cmds, final_fb) =
    decimate_ticks(
      tick_records,
      ch_vol_slide.current_fb,
      old_vol,
      cursor_after_cut,
      1,
      cur_speed,
      list.reverse(cmds),
      retrig_cmd,
    )

  let full_cmds = list.flatten([list.reverse(cmds), cand_cmds])
  let final_ch = ChannelState(..ch_after_ticks, current_fb: final_fb)
  let comment = build_note_comment(note, inst_map)

  #(final_ch, string.join(full_cmds, " "), comment)
}

fn simulate_ticks(
  t: Int,
  speed: Int,
  note: Note,
  ch: ChannelState,
  retrig_interval: Int,
  sine_dict: Dict(Int, Int),
  acc: List(TickRecord),
) -> #(List(TickRecord), ChannelState) {
  case t >= speed {
    True -> #(list.reverse(acc), ch)
    False -> {
      let is_retrig = retrig_interval > 0 && t % retrig_interval == 0

      // Portamento period update
      let cur_p = ch.period
      let porta_spd = ch.portamento_speed
      let new_p = case note.effect {
        0x1 if porta_spd > 0 && cur_p > 0 -> int.max(28, cur_p - porta_spd)
        0x2 if porta_spd > 0 && cur_p > 0 -> int.min(3424, cur_p + porta_spd)
        0x3 | 0x5 if ch.target_period > 0 && cur_p > 0 -> {
          case cur_p < ch.target_period {
            True -> int.min(ch.target_period, cur_p + porta_spd)
            False -> {
              case cur_p > ch.target_period {
                True -> int.max(ch.target_period, cur_p - porta_spd)
                False -> cur_p
              }
            }
          }
        }
        _ -> cur_p
      }

      // Vibrato modulation
      let #(mod_p, next_vib_applied) = case
        { note.effect == 0x4 || note.effect == 0x6 } && new_p > 0
      {
        True -> {
          let pos = int.bitwise_and(ch.vib_applied, 63)
          let sin_val =
            dict.get(sine_dict, int.bitwise_and(pos, 31)) |> result.unwrap(0)
          let delta = { sin_val * ch.vib_depth } / 128
          let signed_delta = case pos >= 32 {
            True -> -delta
            False -> delta
          }
          let clamped_p = int.clamp(new_p + signed_delta, 28, 3424)
          let next_pos = int.bitwise_and(ch.vib_applied + ch.vib_speed, 63)
          #(clamped_p, next_pos)
        }
        False -> #(new_p, ch.vib_applied)
      }

      // Pitch bend fb
      let t_fb = case ch.note > 0 && mod_p > 0 {
        True -> {
          let bend = mod_parser.period_to_midi(mod_p) -. int.to_float(ch.note)
          float.clamp(bend /. 24.0, -1.0, 1.0)
        }
        False -> ch.current_fb
      }

      // Volume slide
      let new_vol = case
        note.effect == 0xA || note.effect == 0x5 || note.effect == 0x6
      {
        True -> int.clamp(ch.vol + ch.vol_slide_speed, 0, 64)
        False -> ch.vol
      }

      // Arpeggio
      let t_arp = case note.effect == 0x0 && note.param > 0 && ch.note > 0 {
        True -> {
          let step = t % 3
          let ax = int.bitwise_shift_right(note.param, 4)
          let ay = int.bitwise_and(note.param, 0x0F)
          case step {
            1 -> Some(ch.note + ax)
            2 -> Some(ch.note + ay)
            _ -> Some(ch.note)
          }
        }
        False -> None
      }

      let rec = TickRecord(t, is_retrig, t_fb, new_vol, t_arp)
      let next_ch =
        ChannelState(
          ..ch,
          period: new_p,
          vib_applied: next_vib_applied,
          vol: new_vol,
          current_fb: t_fb,
        )

      simulate_ticks(t + 1, speed, note, next_ch, retrig_interval, sine_dict, [
        rec,
        ..acc
      ])
    }
  }
}

fn decimate_ticks(
  records: List(TickRecord),
  init_fb: Float,
  init_vol: Int,
  cursor: Int,
  stride: Int,
  speed: Int,
  base_cmds: List(String),
  retrig_cmd: Option(String),
) -> #(List(String), Float) {
  case records {
    [] -> #([], init_fb)
    _ -> {
      decimate_loop(
        records,
        init_fb,
        init_vol,
        cursor,
        stride,
        speed,
        base_cmds,
        retrig_cmd,
      )
    }
  }
}

fn decimate_loop(
  records: List(TickRecord),
  init_fb: Float,
  init_vol: Int,
  cursor: Int,
  stride: Int,
  speed: Int,
  base_cmds: List(String),
  retrig_cmd: Option(String),
) -> #(List(String), Float) {
  case stride > speed {
    True -> {
      // Fallback: only retriggers and last tick
      let rec_len = list.length(records)
      let sel =
        list.index_map(records, fn(r, idx) {
          case r.is_retrig || idx == rec_len - 1 {
            True -> Some(r)
            False -> None
          }
        })
        |> list.filter_map(option.to_result(_, Nil))

      synth_ticks(sel, init_fb, init_vol, cursor, retrig_cmd)
    }
    False -> {
      let rec_len = list.length(records)
      let sel = case stride == 1 {
        True -> records
        False -> {
          list.index_map(records, fn(r, idx) {
            case r.is_retrig || idx == rec_len - 1 || r.t % stride == 0 {
              True -> Some(r)
              False -> None
            }
          })
          |> list.filter_map(option.to_result(_, Nil))
        }
      }

      let #(cand_cmds, cand_fb) =
        synth_ticks(sel, init_fb, init_vol, cursor, retrig_cmd)
      let cand_words =
        list.fold(cand_cmds, 0, fn(acc, c) {
          acc
          + list.length(list.filter(string.split(c, " "), fn(w) { w != "" }))
        })
      let base_words =
        list.fold(base_cmds, 0, fn(acc, c) {
          acc
          + list.length(list.filter(string.split(c, " "), fn(w) { w != "" }))
        })
      let total_words = base_words + cand_words
      let defer_count =
        list.count(cand_cmds, fn(c) { string.contains(c, "+-") })

      case total_words <= 28 && defer_count <= 14 {
        True -> #(cand_cmds, cand_fb)
        False ->
          decimate_loop(
            records,
            init_fb,
            init_vol,
            cursor,
            stride + 1,
            speed,
            base_cmds,
            retrig_cmd,
          )
      }
    }
  }
}

fn synth_ticks(
  records: List(TickRecord),
  init_fb: Float,
  init_vol: Int,
  init_cursor: Int,
  retrig_cmd: Option(String),
) -> #(List(String), Float) {
  synth_tick_loop(records, init_fb, init_vol, init_cursor, retrig_cmd, [])
}

fn synth_tick_loop(
  records: List(TickRecord),
  cur_fb: Float,
  cur_vol: Int,
  cursor: Int,
  retrig_cmd: Option(String),
  acc: List(String),
) -> #(List(String), Float) {
  case records {
    [] -> #(list.reverse(acc), cur_fb)
    [rec, ..rest] -> {
      case rec.t < cursor {
        True -> synth_tick_loop(rest, cur_fb, cur_vol, cursor, retrig_cmd, acc)
        False -> {
          let ops = []

          // Retrig op
          let ops = case rec.is_retrig, retrig_cmd {
            True, Some(cmd) -> [cmd <> " l1", ..ops]
            _, _ -> ops
          }

          // Pitch bend op
          let #(ops, next_fb) = case
            float.absolute_value(rec.fb -. cur_fb) >=. 0.0005
          {
            True -> {
              let fb_str = case float.absolute_value(rec.fb) >=. 0.0005 {
                True -> "fb" <> format_float(rec.fb, 3)
                False -> "fb0"
              }
              #([fb_str, ..ops], rec.fb)
            }
            False -> #(ops, cur_fb)
          }

          // Volume op
          let #(ops, next_vol) = case rec.vol != cur_vol {
            True -> {
              let a_str = "a" <> format_float(vol_to_db(rec.vol), 2)
              #([a_str, ..ops], rec.vol)
            }
            False -> #(ops, cur_vol)
          }

          // Arpeggio op
          let ops = case rec.arp {
            Some(n) -> ["n" <> int.to_string(n), ..ops]
            None -> ops
          }

          case ops {
            [] ->
              synth_tick_loop(rest, next_fb, next_vol, cursor, retrig_cmd, acc)
            _ -> {
              let ops_str = string.join(list.reverse(ops), " ")
              let dt = rec.t - cursor
              let cmd_with_dt = case dt > 0 {
                True -> "+-" <> int.to_string(dt) <> " " <> ops_str
                False -> ops_str
              }
              synth_tick_loop(rest, next_fb, next_vol, rec.t, retrig_cmd, [
                cmd_with_dt,
                ..acc
              ])
            }
          }
        }
      }
    }
  }
}

fn extract_samples(
  instruments: List(Instrument),
  offset: Int,
  raw: BitArray,
  acc: List(#(String, BitArray)),
) -> List(#(String, BitArray)) {
  case instruments {
    [] -> list.reverse(acc)
    [ins, ..rest] -> {
      let len = ins.len
      case len > 2 {
        True -> {
          let raw_pcm = slice_bit_array(raw, offset, len)
          let wav_bytes = pcm8_to_wav(raw_pcm)
          let id_padded = case ins.id < 10 {
            True -> "0" <> int.to_string(ins.id)
            False -> int.to_string(ins.id)
          }
          let filename = "samples/inst_" <> id_padded <> ".wav"
          extract_samples(rest, offset + len, raw, [
            #(filename, wav_bytes),
            ..acc
          ])
        }
        False -> extract_samples(rest, offset + len, raw, acc)
      }
    }
  }
}
