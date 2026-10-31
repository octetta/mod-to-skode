//// Pure Gleam binary parser for ProTracker / FastTracker MOD files.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mod_to_skode/types.{
  type Instrument, type ModFile, type Note, Instrument, ModFile, Note,
}

/// 84-entry ProTracker / FastTracker period table (octaves -1 through 5, MIDI 21 to 104)
pub const periods_table: List(#(Int, Int)) = [
  #(28, 104),
  #(30, 103),
  #(32, 102),
  #(34, 101),
  #(36, 100),
  #(38, 99),
  #(40, 98),
  #(42, 97),
  #(45, 96),
  #(48, 95),
  #(50, 94),
  #(54, 93),
  #(57, 92),
  #(60, 91),
  #(64, 90),
  #(67, 89),
  #(71, 88),
  #(76, 87),
  #(80, 86),
  #(85, 85),
  #(90, 84),
  #(95, 83),
  #(101, 82),
  #(107, 81),
  #(113, 80),
  #(120, 79),
  #(127, 78),
  #(134, 77),
  #(142, 76),
  #(151, 75),
  #(160, 74),
  #(170, 73),
  #(180, 72),
  #(190, 71),
  #(202, 70),
  #(214, 69),
  #(226, 68),
  #(240, 67),
  #(254, 66),
  #(269, 65),
  #(285, 64),
  #(302, 63),
  #(320, 62),
  #(339, 61),
  #(360, 60),
  #(381, 59),
  #(404, 58),
  #(428, 57),
  #(453, 56),
  #(480, 55),
  #(508, 54),
  #(538, 53),
  #(570, 52),
  #(604, 51),
  #(640, 50),
  #(678, 49),
  #(720, 48),
  #(762, 47),
  #(808, 46),
  #(856, 45),
  #(906, 44),
  #(960, 43),
  #(1016, 42),
  #(1076, 41),
  #(1140, 40),
  #(1208, 39),
  #(1280, 38),
  #(1356, 37),
  #(1440, 36),
  #(1524, 35),
  #(1616, 34),
  #(1712, 33),
  #(1812, 32),
  #(1920, 31),
  #(2032, 30),
  #(2152, 29),
  #(2280, 28),
  #(2416, 27),
  #(2560, 26),
  #(2712, 25),
  #(2880, 24),
  #(3048, 23),
  #(3232, 22),
  #(3424, 21),
]

/// Returns exact or closest period to MIDI note mapping.
pub fn period_to_midi(p: Int) -> Float {
  case p <= 0 {
    True -> 0.0
    False -> {
      let ratio = 428.0 /. int.to_float(p)
      case float.logarithm(ratio) {
        Ok(ln_ratio) -> 57.0 +. 12.0 *. { ln_ratio /. 0.6931471805599453 }
        Error(_) -> 0.0
      }
    }
  }
}

pub fn closest_period(p: Int) -> Int {
  case p <= 0 {
    True -> 0
    False -> {
      let sorted =
        list.sort(periods_table, fn(a, b) {
          let diff_a = int.absolute_value(a.0 - p)
          let diff_b = int.absolute_value(b.0 - p)
          int.compare(diff_a, diff_b)
        })
      case list.first(sorted) {
        Ok(#(cp, _)) -> cp
        Error(_) -> 0
      }
    }
  }
}

pub fn resolve_midi_note(period: Int, dict_p: Dict(Int, Int)) -> Option(Int) {
  case period <= 0 {
    True -> None
    False -> {
      case dict.get(dict_p, period) {
        Ok(n) -> Some(n)
        Error(_) -> {
          let cp = closest_period(period)
          let f_p = period_to_midi(period)
          let f_cp = period_to_midi(cp)
          case float.absolute_value(f_p -. f_cp) <. 0.6 {
            True -> dict.get(dict_p, cp) |> option.from_result
            False -> {
              let rounded = float.round(f_p)
              let clamped = int.clamp(rounded, 1, 127)
              Some(clamped)
            }
          }
        }
      }
    }
  }
}

/// Determines the channel count from the MOD magic tag.
pub fn channels_from_magic(magic: String) -> Int {
  case magic {
    "M.K." | "M!K!" | "FLT4" | "4CHN" -> 4
    "6CHN" -> 6
    "8CHN" | "OCTA" | "OKTA" | "CD81" | "FLT8" -> 8
    "2CHN" -> 2
    _ -> {
      case string.length(magic) {
        4 -> {
          let first_two = string.slice(magic, 0, 2)
          let last_two = string.slice(magic, 2, 2)
          let first_one = string.slice(magic, 0, 1)
          let last_three = string.slice(magic, 1, 3)

          case last_two == "CH" || last_two == "CN" {
            True -> {
              case int.parse(first_two) {
                Ok(n) if n > 0 && n <= 32 -> n
                _ -> 4
              }
            }
            False -> {
              case last_three == "CHN" {
                True -> {
                  case int.parse(first_one) {
                    Ok(n) if n > 0 -> n
                    _ -> 4
                  }
                }
                False -> 4
              }
            }
          }
        }
        _ -> 4
      }
    }
  }
}

/// Safely cleans an ASCII byte string by filtering non-printables.
pub fn clean_ascii_bits(bits: BitArray) -> String {
  clean_ascii_loop(bits, [])
  |> string.from_utf_codepoints
  |> string.trim
}

fn clean_ascii_loop(
  bits: BitArray,
  acc: List(UtfCodepoint),
) -> List(UtfCodepoint) {
  case bits {
    <<b:8, rest:bits>> -> {
      case b >= 32 && b <= 126 {
        True -> {
          case string.utf_codepoint(b) {
            Ok(cp) -> clean_ascii_loop(rest, [cp, ..acc])
            Error(_) -> clean_ascii_loop(rest, acc)
          }
        }
        False -> clean_ascii_loop(rest, acc)
      }
    }
    _ -> list.reverse(acc)
  }
}

/// Parses 31 instruments starting at offset 20.
fn parse_instruments(
  bits: BitArray,
  idx: Int,
  acc: List(Instrument),
) -> Result(#(List(Instrument), BitArray), String) {
  case idx > 31 {
    True -> Ok(#(list.reverse(acc), bits))
    False -> {
      case bits {
        <<
          raw_name:bytes-size(22),
          len_words:16-big,
          ft_byte:8,
          vol_byte:8,
          rep_off_words:16-big,
          rep_len_words:16-big,
          rest:bits,
        >> -> {
          let name = clean_ascii_bits(raw_name)
          let len = len_words * 2
          let raw_ft = int.bitwise_and(ft_byte, 0x0F)
          let finetune = case raw_ft >= 8 {
            True -> raw_ft - 16
            False -> raw_ft
          }
          let cents = int.to_float(finetune) *. 12.5
          let vol = int.min(64, vol_byte)
          let loop_start = rep_off_words * 2
          let loop_len = rep_len_words * 2
          let wants_loop = loop_len > 2

          let inst =
            Instrument(
              id: idx,
              name: name,
              len: len,
              finetune: finetune,
              cents: cents,
              vol: vol,
              loop_start: loop_start,
              loop_len: loop_len,
              wants_loop: wants_loop,
            )
          parse_instruments(rest, idx + 1, [inst, ..acc])
        }
        _ ->
          Error(
            "Failed to parse instrument "
            <> int.to_string(idx)
            <> ": unexpected EOF",
          )
      }
    }
  }
}

/// Parses the 128 bytes pattern sequence order table.
fn parse_sequence(
  bits: BitArray,
  count: Int,
  _acc: List(Int),
) -> #(List(Int), List(Int), BitArray) {
  parse_seq_loop(bits, count, 0, [], [])
}

fn parse_seq_loop(
  bits: BitArray,
  total_needed: Int,
  read_count: Int,
  song_acc: List(Int),
  all_acc: List(Int),
) -> #(List(Int), List(Int), BitArray) {
  case read_count >= 128 {
    True -> #(list.reverse(song_acc), list.reverse(all_acc), bits)
    False -> {
      case bits {
        <<val:8, rest:bits>> -> {
          let new_all = [val, ..all_acc]
          let new_song = case read_count < total_needed {
            True -> [val, ..song_acc]
            False -> song_acc
          }
          parse_seq_loop(rest, total_needed, read_count + 1, new_song, new_all)
        }
        _ -> #(list.reverse(song_acc), list.reverse(all_acc), bits)
      }
    }
  }
}

/// Parses patterns from binary bit array.
fn parse_patterns(
  bits: BitArray,
  num_patterns: Int,
  num_channels: Int,
  dict_p: Dict(Int, Int),
) -> Result(#(List(List(List(Note))), BitArray), String) {
  parse_patterns_loop(bits, num_patterns, 0, num_channels, dict_p, [])
}

fn parse_patterns_loop(
  bits: BitArray,
  total_patterns: Int,
  current_pattern: Int,
  num_channels: Int,
  dict_p: Dict(Int, Int),
  acc: List(List(List(Note))),
) -> Result(#(List(List(List(Note))), BitArray), String) {
  case current_pattern >= total_patterns {
    True -> Ok(#(list.reverse(acc), bits))
    False -> {
      case parse_single_pattern(bits, 64, num_channels, dict_p) {
        Ok(#(rows, remaining)) -> {
          parse_patterns_loop(
            remaining,
            total_patterns,
            current_pattern + 1,
            num_channels,
            dict_p,
            [rows, ..acc],
          )
        }
        Error(err) ->
          Error(
            "Pattern " <> int.to_string(current_pattern) <> " error: " <> err,
          )
      }
    }
  }
}

fn parse_single_pattern(
  bits: BitArray,
  num_rows: Int,
  num_channels: Int,
  dict_p: Dict(Int, Int),
) -> Result(#(List(List(Note)), BitArray), String) {
  parse_pattern_rows(bits, num_rows, 0, num_channels, dict_p, [])
}

fn parse_pattern_rows(
  bits: BitArray,
  total_rows: Int,
  current_row: Int,
  num_channels: Int,
  dict_p: Dict(Int, Int),
  row_acc: List(List(Note)),
) -> Result(#(List(List(Note)), BitArray), String) {
  case current_row >= total_rows {
    True -> Ok(#(list.reverse(row_acc), bits))
    False -> {
      case parse_row_channels(bits, num_channels, 0, dict_p, []) {
        Ok(#(notes, remaining)) -> {
          parse_pattern_rows(
            remaining,
            total_rows,
            current_row + 1,
            num_channels,
            dict_p,
            [notes, ..row_acc],
          )
        }
        Error(err) ->
          Error("Row " <> int.to_string(current_row) <> " error: " <> err)
      }
    }
  }
}

fn parse_row_channels(
  bits: BitArray,
  total_channels: Int,
  current_channel: Int,
  dict_p: Dict(Int, Int),
  ch_acc: List(Note),
) -> Result(#(List(Note), BitArray), String) {
  case current_channel >= total_channels {
    True -> Ok(#(list.reverse(ch_acc), bits))
    False -> {
      case bits {
        <<b0:8, b1:8, b2:8, b3:8, rest:bits>> -> {
          let inst_hi = int.bitwise_and(b0, 0xF0)
          let inst_lo = int.bitwise_shift_right(int.bitwise_and(b2, 0xF0), 4)
          let inst = int.bitwise_or(inst_hi, inst_lo)

          let period_hi = int.bitwise_shift_left(int.bitwise_and(b0, 0x0F), 8)
          let period = int.bitwise_or(period_hi, b1)

          let effect = int.bitwise_and(b2, 0x0F)
          let param = b3

          let midi = resolve_midi_note(period, dict_p)
          let note = Note(midi:, inst:, effect:, param:, period:)

          parse_row_channels(rest, total_channels, current_channel + 1, dict_p, [
            note,
            ..ch_acc
          ])
        }
        _ ->
          Error(
            "Unexpected EOF reading channel " <> int.to_string(current_channel),
          )
      }
    }
  }
}

/// Main entry point to parse a MOD file into ModFile record.
pub fn parse(filename: String, raw: BitArray) -> Result(ModFile, String) {
  let file_size = bit_array.byte_size(raw)
  case file_size < 1084 {
    True ->
      Error(
        "File is too small to be a standard MOD ("
        <> int.to_string(file_size)
        <> " bytes)",
      )
    False -> {
      case raw {
        <<title_bits:bytes-size(20), rest_after_title:bits>> -> {
          let title = clean_ascii_bits(title_bits)
          use #(instruments, rest_after_insts) <- result.try(
            parse_instruments(rest_after_title, 1, []),
          )
          case rest_after_insts {
            <<song_length:8, restart_pos:8, rest_after_meta:bits>> -> {
              let #(sequence, all_order, rest_after_seq) =
                parse_sequence(rest_after_meta, song_length, [])
              case rest_after_seq {
                <<raw_magic:bytes-size(4), rest_patterns_bits:bits>> -> {
                  let magic = clean_ascii_bits(raw_magic)
                  let num_channels = channels_from_magic(magic)

                  let n_seq = case list.reduce(sequence, int.max) {
                    Ok(m) -> m + 1
                    Error(_) -> 0
                  }
                  let n_full = case list.reduce(all_order, int.max) {
                    Ok(m) -> m + 1
                    Error(_) -> 0
                  }
                  let pattern_bytes = 64 * num_channels * 4
                  let num_patterns = case
                    1084 + n_full * pattern_bytes <= file_size
                  {
                    True -> n_full
                    False -> n_seq
                  }

                  let dict_p = dict.from_list(periods_table)
                  use #(patterns, _remaining_samples) <- result.try(
                    parse_patterns(
                      rest_patterns_bits,
                      num_patterns,
                      num_channels,
                      dict_p,
                    ),
                  )

                  let sample_data_offset = 1084 + num_patterns * pattern_bytes

                  Ok(ModFile(
                    filename: filename,
                    title: title,
                    num_channels: num_channels,
                    song_length: song_length,
                    restart_pos: restart_pos,
                    sequence: sequence,
                    instruments: instruments,
                    patterns: patterns,
                    sample_data_offset: sample_data_offset,
                    raw_bytes: raw,
                  ))
                }
                _ -> Error("Failed to read MOD magic tag at offset 1080")
              }
            }
            _ -> Error("Failed to read song length and restart pos")
          }
        }
        _ -> Error("Failed to read 20-byte MOD title")
      }
    }
  }
}
