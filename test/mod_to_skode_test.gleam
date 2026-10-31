import gleam/bit_array
import gleam/float
import gleam/string
import gleeunit
import gleeunit/should
import mod_to_skode/converter.{convert, make_range, pcm8_to_wav, vol_to_db}
import mod_to_skode/mod_parser.{channels_from_magic, parse, period_to_midi}

pub fn main() {
  gleeunit.main()
}

pub fn channels_from_magic_test() {
  channels_from_magic("M.K.") |> should.equal(4)
  channels_from_magic("M!K!") |> should.equal(4)
  channels_from_magic("FLT4") |> should.equal(4)
  channels_from_magic("6CHN") |> should.equal(6)
  channels_from_magic("8CHN") |> should.equal(8)
  channels_from_magic("OCTA") |> should.equal(8)
  channels_from_magic("2CHN") |> should.equal(2)
  channels_from_magic("16CH") |> should.equal(16)
  channels_from_magic("28CH") |> should.equal(28)
  channels_from_magic("32CH") |> should.equal(32)
}

pub fn vol_to_db_test() {
  vol_to_db(0) |> should.equal(-100.0)
  let db64 = vol_to_db(64)
  { float.absolute_value(db64 +. 10.0) <. 0.001 } |> should.be_true
}

pub fn period_to_midi_test() {
  let m428 = period_to_midi(428)
  { float.absolute_value(m428 -. 57.0) <. 0.001 } |> should.be_true

  let m856 = period_to_midi(856)
  { float.absolute_value(m856 -. 45.0) <. 0.001 } |> should.be_true
}

pub fn make_range_test() {
  make_range(0, 3) |> should.equal([0, 1, 2, 3])
  make_range(4, 2) |> should.equal([])
}

pub fn pcm8_to_wav_test() {
  let raw = <<0, 127, 128, 255>>
  let wav = pcm8_to_wav(raw)
  // RIFF (12) + fmt (24) + data header (8) + 4 * 2 = 52 bytes
  bit_array.byte_size(wav) |> should.equal(52)
}

pub fn parse_synthetic_mod_test() {
  let title = <<"Synthetic Test Song ":utf8>>
  // 31 empty instruments: 30 bytes each
  let empty_inst = <<
    "Sample 01             ":utf8,
    0:16,
    // length words
    0:8,
    // finetune
    64:8,
    // volume
    0:16,
    // loop start
    0:16,
    // loop len
  >>
  let insts =
    bit_array.concat(
      make_range(1, 31)
      |> list_map(fn(_) { empty_inst }),
    )

  let song_len = <<1:8, 0:8>>
  let order_table =
    bit_array.concat([
      <<0:8>>,
      bit_array.from_string(string.repeat("\u{0000}", 127)),
    ])
  let magic = <<"M.K.":utf8>>
  // 1 pattern of 64 rows, 4 channels each (4 bytes per cell) = 1024 bytes
  let pattern_data = bit_array.from_string(string.repeat("\u{0000}", 1024))

  let mod_bytes =
    bit_array.concat([title, insts, song_len, order_table, magic, pattern_data])

  let parsed = parse("test.mod", mod_bytes)
  parsed |> should.be_ok

  let assert Ok(mod_file) = parsed
  mod_file.num_channels |> should.equal(4)
  mod_file.song_length |> should.equal(1)

  let conversion = convert(mod_file)
  conversion |> should.be_ok
  let assert Ok(res) = conversion
  res.num_channels |> should.equal(4)
  res.total_rows |> should.equal(64)
}

fn list_map(items: List(a), f: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [x, ..rest] -> [f(x), ..list_map(rest, f)]
  }
}
