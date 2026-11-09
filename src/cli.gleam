//// Standalone CLI runner for mod-to-skode compiled via QuickJS
//// Provides zero-dependency native conversion of MOD files to Skode (.sk / .zip)

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mod_to_skode/converter
import mod_to_skode/mod_parser
import mod_to_skode/types.{type ConversionResult}

@external(javascript, "./cli_ffi.mjs", "getArgs")
fn get_args() -> List(String)

@external(javascript, "./cli_ffi.mjs", "readFileBinary")
fn read_file_binary(path: String) -> Result(BitArray, String)

@external(javascript, "./cli_ffi.mjs", "writeTextFile")
fn write_text_file(path: String, content: String) -> Result(Nil, String)

@external(javascript, "./cli_ffi.mjs", "writeBinaryFile")
fn write_binary_file(path: String, data: BitArray) -> Result(Nil, String)

@external(javascript, "./cli_ffi.mjs", "createZipArchive")
fn create_zip(
  main_sk: String,
  samples: List(#(String, BitArray)),
) -> Result(BitArray, String)

@external(javascript, "./cli_ffi.mjs", "makeDir")
fn make_dir(path: String) -> Result(Nil, String)

@external(javascript, "./cli_ffi.mjs", "printStdout")
fn print_stdout(text: String) -> Nil

@external(javascript, "./cli_ffi.mjs", "printStderr")
fn print_stderr(text: String) -> Nil

@external(javascript, "./cli_ffi.mjs", "exitProcess")
fn exit_process(code: Int) -> Nil

pub type CliOptions {
  CliOptions(
    input_file: Option(String),
    output_file: Option(String),
    extract: Bool,
    show_help: Bool,
  )
}

fn parse_cli_args(args: List(String), opts: CliOptions) -> CliOptions {
  case args {
    [] -> opts
    ["-h", ..rest] | ["--help", ..rest] ->
      parse_cli_args(rest, CliOptions(..opts, show_help: True))
    ["-x", ..rest] | ["--extract", ..rest] ->
      parse_cli_args(rest, CliOptions(..opts, extract: True))
    ["-o", out, ..rest] | ["--output", out, ..rest] ->
      parse_cli_args(rest, CliOptions(..opts, output_file: Some(out)))
    [arg, ..rest] -> {
      case string.starts_with(arg, "-") {
        True -> parse_cli_args(rest, opts)
        False ->
          case opts.input_file {
            None ->
              parse_cli_args(rest, CliOptions(..opts, input_file: Some(arg)))
            Some(_) -> parse_cli_args(rest, opts)
          }
      }
    }
  }
}

fn print_help() {
  print_stdout(
    "mod2skode (Gleam Native QuickJS CLI) v0.2.2\n"
    <> "Converts ProTracker / FastTracker MOD music files to Skode scripts\n\n"
    <> "Usage:\n"
    <> "  mod2skode <input.mod> [options]\n\n"
    <> "Options:\n"
    <> "  -o, --output <file>    Output .sk script or .zip archive (default: stdout)\n"
    <> "  -x, --extract          Extract 16-bit WAV samples to samples/ directory\n"
    <> "  -h, --help             Show this help message\n\n"
    <> "Examples:\n"
    <> "  mod2skode song.mod -o song.zip         Package into standalone ready-to-play ZIP\n"
    <> "  mod2skode song.mod -o song.sk -x       Output script and extract WAV samples\n"
    <> "  mod2skode song.mod > song.sk           Stream script directly to stdout\n",
  )
}

fn format_duration(seconds: Float) -> String {
  let total_sec = float_to_int(seconds)
  let mins = total_sec / 60
  let secs = total_sec % 60
  let mins_str = case mins < 10 {
    True -> "0" <> int.to_string(mins)
    False -> int.to_string(mins)
  }
  let secs_str = case secs < 10 {
    True -> "0" <> int.to_string(secs)
    False -> int.to_string(secs)
  }
  mins_str
  <> ":"
  <> secs_str
  <> " ("
  <> converter.format_float(seconds, 2)
  <> "s)"
}

fn float_to_int(f: Float) -> Int {
  case f <. 0.0 {
    True -> 0
    False -> {
      let s = converter.format_float(f, 0)
      result.unwrap(int.parse(s), 0)
    }
  }
}

fn write_extracted_samples(
  samples: List(#(String, BitArray)),
) -> Result(Nil, String) {
  let _ = make_dir("samples")
  write_samples_loop(samples)
}

fn write_samples_loop(
  samples: List(#(String, BitArray)),
) -> Result(Nil, String) {
  case samples {
    [] -> Ok(Nil)
    [#(name, bytes), ..rest] -> {
      case write_binary_file(name, bytes) {
        Ok(_) -> write_samples_loop(rest)
        Error(e) -> Error("Failed to write " <> name <> ": " <> e)
      }
    }
  }
}

pub fn main() {
  let raw_args = get_args()
  let default_opts =
    CliOptions(
      input_file: None,
      output_file: None,
      extract: False,
      show_help: False,
    )
  let opts = parse_cli_args(raw_args, default_opts)

  case opts.show_help {
    True -> {
      print_help()
      exit_process(0)
    }
    False -> {
      case opts.input_file {
        None -> {
          print_stderr(
            "Error: No input MOD file specified.\nRun 'mod2skode --help' for usage instructions.\n",
          )
          exit_process(1)
        }
        Some(input_path) -> {
          case read_file_binary(input_path) {
            Error(err) -> {
              print_stderr("Error reading input file: " <> err <> "\n")
              exit_process(1)
            }
            Ok(bytes) -> {
              case mod_parser.parse(input_path, bytes) {
                Error(err) -> {
                  print_stderr("Error parsing MOD file: " <> err <> "\n")
                  exit_process(1)
                }
                Ok(mod_file) -> {
                  case converter.convert(mod_file) {
                    Error(err) -> {
                      print_stderr("Error converting MOD: " <> err <> "\n")
                      exit_process(1)
                    }
                    Ok(res) -> {
                      handle_output(opts, res)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_output(opts: CliOptions, res: ConversionResult) {
  case opts.output_file {
    Some(out_file) -> {
      case string.ends_with(out_file, ".zip") {
        True -> {
          case create_zip(res.skode_text, res.samples) {
            Error(err) -> {
              print_stderr("Error packaging ZIP archive: " <> err <> "\n")
              exit_process(1)
            }
            Ok(zip_bytes) -> {
              case write_binary_file(out_file, zip_bytes) {
                Error(err) -> {
                  print_stderr("Error writing output file: " <> err <> "\n")
                  exit_process(1)
                }
                Ok(_) -> {
                  print_stderr("Generated " <> out_file <> "\n")
                  print_stderr(
                    "Duration: "
                    <> format_duration(res.duration_seconds)
                    <> "\n",
                  )
                  exit_process(0)
                }
              }
            }
          }
        }
        False -> {
          case write_text_file(out_file, res.skode_text) {
            Error(err) -> {
              print_stderr("Error writing output file: " <> err <> "\n")
              exit_process(1)
            }
            Ok(_) -> {
              print_stderr("Generated " <> out_file <> "\n")
              case opts.extract {
                True -> {
                  case write_extracted_samples(res.samples) {
                    Error(err) -> {
                      print_stderr(err <> "\n")
                      exit_process(1)
                    }
                    Ok(_) -> {
                      print_stderr("Extracted samples to samples/ directory\n")
                    }
                  }
                }
                False -> Nil
              }
              print_stderr(
                "Duration: " <> format_duration(res.duration_seconds) <> "\n",
              )
              exit_process(0)
            }
          }
        }
      }
    }
    None -> {
      print_stdout(res.skode_text)
      case opts.extract {
        True -> {
          case write_extracted_samples(res.samples) {
            Error(err) -> {
              print_stderr(err <> "\n")
              exit_process(1)
            }
            Ok(_) -> {
              print_stderr("Extracted samples to samples/ directory\n")
            }
          }
        }
        False -> Nil
      }
      exit_process(0)
    }
  }
}
