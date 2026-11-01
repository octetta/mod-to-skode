//// Types for mod_to_skode converter and Lustre web interface

import gleam/option.{type Option}

pub type Instrument {
  Instrument(
    id: Int,
    name: String,
    len: Int,
    finetune: Int,
    cents: Float,
    vol: Int,
    loop_start: Int,
    loop_len: Int,
    wants_loop: Bool,
  )
}

pub type Note {
  Note(midi: Option(Int), inst: Int, effect: Int, param: Int, period: Int)
}

pub type ModFile {
  ModFile(
    filename: String,
    title: String,
    num_channels: Int,
    song_length: Int,
    restart_pos: Int,
    sequence: List(Int),
    instruments: List(Instrument),
    patterns: List(List(List(Note))),
    sample_data_offset: Int,
    raw_bytes: BitArray,
  )
}

pub type ConversionResult {
  ConversionResult(
    skode_text: String,
    samples: List(#(String, BitArray)),
    num_channels: Int,
    total_rows: Int,
    initial_tempo: Int,
    initial_speed: Int,
    duration_seconds: Float,
  )
}

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
  )
}

pub type Msg {
  EngineStatusChanged(Bool)
  FileDropped(name: String, data: BitArray)
  ConvertClicked
  ConversionCompleted(Result(ConversionResult, String))
  PlayClicked
  PauseClicked
  ResumeClicked
  StopClicked
  PlaybackStepChanged(step: Int, total_steps: Int)
  PlaybackEnded
  PreviewSampleClicked(id: Int)
  DownloadZipClicked
  ResetClicked
  TabSelected(String)
  PanicClicked
  LoadDemo(url: String, filename: String)
}
