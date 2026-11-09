//// # Mod-to-Skode In-Browser Audio Converter & Tracker Web App
////
//// Runs client-side in the browser, converts Amiga / ProTracker MOD files
//// to Skode scripts, packages them with WAV samples into a ZIP archive,
//// and allows instant playback directly in the Skred WASM audio engine.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre
import lustre/attribute.{class, href, id, rel, target, type_}
import lustre/effect.{type Effect}
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import mod_to_skode/converter
import mod_to_skode/mod_parser
import mod_to_skode/types.{
  type ConversionResult, type Instrument, type ModFile, type Model, type Msg,
  ConversionCompleted, ConvertClicked, DownloadZipClicked, EngineStatusChanged,
  FileDropped, LoadDemo, MasterVolumeChanged, ModArchiveFetchFailed,
  ModArchiveFetchStarted, ModArchiveInfo, ModArchiveLoaded, Model, PanicClicked,
  PauseClicked, PlayClicked, PlaybackEnded, PlaybackStepChanged,
  PreviewSampleClicked, RandomModArchiveClicked, ResetClicked, ResumeClicked,
  StereoAmiga, StereoHeadphone, StereoModeChanged, StereoMono, StopClicked,
  TabSelected,
}

// ---------------------------------------------------------------------------
// JavaScript FFI Declarations
// ---------------------------------------------------------------------------

@external(javascript, "./skred_ffi.mjs", "initEngine")
fn js_init_engine(callback: fn(Bool, String) -> Nil) -> Nil

@external(javascript, "./skred_ffi.mjs", "registerFileDrop")
fn js_register_file_drop(callback: fn(String, BitArray) -> Nil) -> Nil

@external(javascript, "./skred_ffi.mjs", "loadUrlMod")
fn js_load_url_mod(
  url: String,
  filename: String,
  callback: fn(String, BitArray) -> Nil,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "fetchRandomModArchive")
fn js_fetch_random_modarchive(
  on_start: fn(String, String, Int) -> Nil,
  on_success: fn(String, BitArray, Int, String, String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "checkInitialUrl")
fn js_check_initial_url(
  on_start: fn(String, String, Int) -> Nil,
  on_success: fn(String, BitArray, Int, String, String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "loadAndPlaySkode")
fn js_load_and_play_skode(
  main_sk: String,
  samples: List(#(String, BitArray)),
  total_rows: Int,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "pausePlayback")
fn js_pause_playback() -> Nil

@external(javascript, "./skred_ffi.mjs", "resumePlayback")
fn js_resume_playback() -> Nil

@external(javascript, "./skred_ffi.mjs", "stopPlayback")
fn js_stop_playback() -> Nil

@external(javascript, "./skred_ffi.mjs", "panicEngine")
fn js_panic_engine() -> Nil

@external(javascript, "./skred_ffi.mjs", "previewSample")
fn js_preview_sample(wav: BitArray) -> Nil

@external(javascript, "./skred_ffi.mjs", "registerPlaybackListener")
fn js_register_playback_listener(
  on_step: fn(Int, Int) -> Nil,
  on_end: fn() -> Nil,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "downloadZip")
fn js_download_zip(
  main_sk: String,
  samples: List(#(String, BitArray)),
  filename: String,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "sendCommand")
fn js_send_command(cmd: String) -> Nil

@external(javascript, "./skred_ffi.mjs", "setMasterVolume")
fn js_set_master_volume(db: Int) -> Nil

// ---------------------------------------------------------------------------
// Lustre Effects
// ---------------------------------------------------------------------------

fn send_command_effect(cmd: String) -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_send_command(cmd) })
}

fn set_master_volume_effect(db: Int) -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_set_master_volume(db) })
}

fn init_engine_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_init_engine(fn(success, version) {
      dispatch(EngineStatusChanged(success, version))
    })
  })
}

fn register_file_drop_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_register_file_drop(fn(filename, data) {
      dispatch(FileDropped(filename, data))
    })
  })
}

fn register_playback_listener_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_register_playback_listener(
      fn(step, total) { dispatch(PlaybackStepChanged(step, total)) },
      fn() { dispatch(PlaybackEnded) },
    )
  })
}

fn load_demo_effect(url: String, filename: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_load_url_mod(url, filename, fn(name, data) {
      dispatch(FileDropped(name, data))
    })
  })
}

fn random_modarchive_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_fetch_random_modarchive(
      fn(title, artist, id) {
        dispatch(ModArchiveFetchStarted(title, artist, id))
      },
      fn(filename, data, id, title, artist) {
        dispatch(ModArchiveLoaded(filename, data, id, title, artist))
      },
      fn(err) { dispatch(ModArchiveFetchFailed(err)) },
    )
  })
}

fn check_initial_url_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_check_initial_url(
      fn(title, artist, id) {
        dispatch(ModArchiveFetchStarted(title, artist, id))
      },
      fn(filename, data, id, title, artist) {
        dispatch(ModArchiveLoaded(filename, data, id, title, artist))
      },
      fn(err) { dispatch(ModArchiveFetchFailed(err)) },
    )
  })
}

fn play_effect(
  main_sk: String,
  samples: List(#(String, BitArray)),
  total_rows: Int,
) -> Effect(Msg) {
  effect.from(fn(_dispatch) {
    js_load_and_play_skode(main_sk, samples, total_rows)
  })
}

fn pause_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_pause_playback() })
}

fn resume_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_resume_playback() })
}

fn stop_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_stop_playback() })
}

fn panic_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_panic_engine() })
}

fn preview_sample_effect(wav: BitArray) -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_preview_sample(wav) })
}

fn download_zip_effect(
  main_sk: String,
  samples: List(#(String, BitArray)),
  filename: String,
) -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_download_zip(main_sk, samples, filename) })
}

// ---------------------------------------------------------------------------
// Model Initialization & Update
// ---------------------------------------------------------------------------

pub fn init(_) -> #(Model, Effect(Msg)) {
  let model =
    Model(
      engine_ready: False,
      engine_version: "0.82.0",
      is_playing: False,
      is_paused: False,
      current_step: 0,
      active_file: None,
      conversion: None,
      is_converting: False,
      error_message: None,
      status_text: "Ready. Drag and drop any .mod file to convert.",
      active_tab: "info",
      modarchive_info: None,
      stereo_mode: StereoHeadphone,
      master_volume: -6,
    )

  let effects =
    effect.batch([
      init_engine_effect(),
      register_file_drop_effect(),
      register_playback_listener_effect(),
      check_initial_url_effect(),
    ])

  #(model, effects)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    EngineStatusChanged(ready, version) -> {
      let status = case ready {
        True -> "Skred " <> version <> " WASM engine ready."
        False -> "Failed to initialize Skred WASM."
      }
      #(
        Model(..model, engine_ready: ready, engine_version: version, status_text: status),
        effect.none(),
      )
    }

    FileDropped(filename, data) -> {
      let stop_eff = stop_effect()
      case mod_parser.parse(filename, data) {
        Error(err) -> {
          #(
            Model(
              ..model,
              is_playing: False,
              is_paused: False,
              current_step: 0,
              error_message: Some(err),
              is_converting: False,
              modarchive_info: None,
              status_text: "Parse error: " <> err,
            ),
            stop_eff,
          )
        }
        Ok(mod_file) -> {
          case
            converter.convert_with_options(
              mod_file,
              converter.ConvertOptions(stereo_mode: model.stereo_mode),
            )
          {
            Error(err) -> {
              #(
                Model(
                  ..model,
                  is_playing: False,
                  is_paused: False,
                  current_step: 0,
                  active_file: Some(mod_file),
                  error_message: Some(err),
                  is_converting: False,
                  modarchive_info: None,
                  status_text: "Conversion error: " <> err,
                ),
                stop_eff,
              )
            }
            Ok(conv_res) -> {
              #(
                Model(
                  ..model,
                  is_playing: False,
                  is_paused: False,
                  current_step: 0,
                  active_file: Some(mod_file),
                  conversion: Some(conv_res),
                  is_converting: False,
                  modarchive_info: None,
                  error_message: None,
                  status_text: "Successfully converted "
                    <> filename
                    <> " ("
                    <> converter.format_duration(conv_res.duration_seconds)
                    <> ", "
                    <> int.to_string(conv_res.total_rows)
                    <> " rows).",
                ),
                stop_eff,
              )
            }
          }
        }
      }
    }

    ConvertClicked -> {
      case model.active_file {
        Some(mod_file) -> {
          case
            converter.convert_with_options(
              mod_file,
              converter.ConvertOptions(stereo_mode: model.stereo_mode),
            )
          {
            Error(err) -> {
              #(
                Model(
                  ..model,
                  error_message: Some(err),
                  status_text: "Conversion error: " <> err,
                ),
                effect.none(),
              )
            }
            Ok(conv_res) -> {
              #(
                Model(
                  ..model,
                  conversion: Some(conv_res),
                  error_message: None,
                  status_text: "Converted successfully.",
                ),
                effect.none(),
              )
            }
          }
        }
        None -> #(model, effect.none())
      }
    }

    ConversionCompleted(res) -> {
      case res {
        Ok(conv_res) -> {
          #(
            Model(..model, conversion: Some(conv_res), is_converting: False),
            effect.none(),
          )
        }
        Error(err) -> {
          #(
            Model(..model, error_message: Some(err), is_converting: False),
            effect.none(),
          )
        }
      }
    }

    PlayClicked -> {
      case model.conversion {
        Some(res) -> {
          #(
            Model(
              ..model,
              is_playing: True,
              is_paused: False,
              current_step: 0,
              status_text: "Playing in Skred WASM...",
            ),
            play_effect(res.skode_text, res.samples, res.total_rows),
          )
        }
        None -> #(model, effect.none())
      }
    }

    PauseClicked -> {
      case model.is_playing {
        True -> #(
          Model(
            ..model,
            is_paused: True,
            status_text: "Playback paused at step "
              <> int.to_string(model.current_step + 1)
              <> ".",
          ),
          pause_effect(),
        )
        False -> #(model, effect.none())
      }
    }

    ResumeClicked -> {
      case model.is_playing {
        True -> #(
          Model(..model, is_paused: False, status_text: "Playback resumed."),
          resume_effect(),
        )
        False -> #(model, effect.none())
      }
    }

    StopClicked -> {
      #(
        Model(
          ..model,
          is_playing: False,
          is_paused: False,
          current_step: 0,
          status_text: "Playback stopped.",
        ),
        stop_effect(),
      )
    }

    PlaybackStepChanged(step, _total) -> {
      case model.is_playing {
        True -> #(Model(..model, current_step: step), effect.none())
        False -> #(model, effect.none())
      }
    }

    PlaybackEnded -> {
      #(
        Model(
          ..model,
          is_playing: False,
          is_paused: False,
          current_step: 0,
          status_text: "Playback finished.",
        ),
        stop_effect(),
      )
    }

    PreviewSampleClicked(id) -> {
      case model.is_playing {
        True -> #(model, effect.none())
        False -> {
          case model.conversion {
            Some(conv) -> {
              let target_name = "samples/inst_" <> int.to_string(id) <> ".wav"
              case list.find(conv.samples, fn(item) { item.0 == target_name }) {
                Ok(#(_name, wav)) -> #(
                  Model(
                    ..model,
                    status_text: "Auditioning instrument #"
                      <> int.to_string(id)
                      <> "...",
                  ),
                  preview_sample_effect(wav),
                )
                Error(_) -> #(model, effect.none())
              }
            }
            None -> #(model, effect.none())
          }
        }
      }
    }

    PanicClicked -> {
      #(
        Model(
          ..model,
          is_playing: False,
          is_paused: False,
          current_step: 0,
          status_text: "Engine silenced (S-1).",
        ),
        panic_effect(),
      )
    }

    DownloadZipClicked -> {
      case model.conversion, model.active_file {
        Some(res), Some(mod_file) -> {
          let skode_text = case
            converter.convert_with_options(
              mod_file,
              converter.ConvertOptions(stereo_mode: model.stereo_mode),
            )
          {
            Ok(new_res) -> new_res.skode_text
            Error(_) -> res.skode_text
          }
          let zip_name = clean_zip_name(mod_file.filename)
          #(
            Model(..model, status_text: "Downloading " <> zip_name <> "..."),
            download_zip_effect(skode_text, res.samples, zip_name),
          )
        }
        _, _ -> #(model, effect.none())
      }
    }

    ResetClicked -> {
      #(
        Model(
          ..model,
          active_file: None,
          conversion: None,
          is_playing: False,
          is_paused: False,
          current_step: 0,
          error_message: None,
          modarchive_info: None,
          status_text: "Ready. Drag and drop any .mod file to convert.",
        ),
        stop_effect(),
      )
    }

    TabSelected(tab) -> {
      #(Model(..model, active_tab: tab), effect.none())
    }

    LoadDemo(url, filename) -> {
      #(
        Model(
          ..model,
          is_playing: False,
          is_paused: False,
          current_step: 0,
          is_converting: True,
          modarchive_info: None,
          status_text: "Downloading & converting demo " <> filename <> "...",
        ),
        effect.batch([stop_effect(), load_demo_effect(url, filename)]),
      )
    }

    RandomModArchiveClicked -> {
      case model.is_converting {
        True -> #(model, effect.none())
        False -> #(
          Model(
            ..model,
            is_playing: False,
            is_paused: False,
            current_step: 0,
            is_converting: True,
            error_message: None,
            status_text: "Selecting random Amiga module from ModArchive...",
          ),
          effect.batch([stop_effect(), random_modarchive_effect()]),
        )
      }
    }

    ModArchiveFetchStarted(title, artist, id) -> {
      #(
        Model(
          ..model,
          status_text: "Downloading \""
            <> title
            <> "\" by "
            <> artist
            <> " from ModArchive (#"
            <> int.to_string(id)
            <> ")...",
        ),
        effect.none(),
      )
    }

    ModArchiveFetchFailed(err) -> {
      #(
        Model(
          ..model,
          is_converting: False,
          error_message: Some(err),
          status_text: "ModArchive download failed: " <> err,
        ),
        effect.none(),
      )
    }

    ModArchiveLoaded(filename, data, id, title, artist) -> {
      let stop_eff = stop_effect()
      case mod_parser.parse(filename, data) {
        Error(err) -> {
          #(
            Model(
              ..model,
              is_playing: False,
              is_paused: False,
              current_step: 0,
              error_message: Some(err),
              is_converting: False,
              modarchive_info: None,
              status_text: "Parse error on " <> filename <> ": " <> err,
            ),
            stop_eff,
          )
        }
        Ok(mod_file) -> {
          case
            converter.convert_with_options(
              mod_file,
              converter.ConvertOptions(stereo_mode: model.stereo_mode),
            )
          {
            Error(err) -> {
              #(
                Model(
                  ..model,
                  is_playing: False,
                  is_paused: False,
                  current_step: 0,
                  active_file: Some(mod_file),
                  error_message: Some(err),
                  is_converting: False,
                  modarchive_info: Some(ModArchiveInfo(
                    id: id,
                    title: title,
                    artist: artist,
                  )),
                  status_text: "Conversion error on " <> filename <> ": " <> err,
                ),
                stop_eff,
              )
            }
            Ok(conv_res) -> {
              #(
                Model(
                  ..model,
                  is_playing: False,
                  is_paused: False,
                  current_step: 0,
                  active_file: Some(mod_file),
                  conversion: Some(conv_res),
                  is_converting: False,
                  modarchive_info: Some(ModArchiveInfo(
                    id: id,
                    title: title,
                    artist: artist,
                  )),
                  error_message: None,
                  status_text: "Loaded \""
                    <> title
                    <> "\" by "
                    <> artist
                    <> " ("
                    <> converter.format_duration(conv_res.duration_seconds)
                    <> ", "
                    <> int.to_string(conv_res.total_rows)
                    <> " rows).",
                ),
                stop_eff,
              )
            }
          }
        }
      }
    }

    StereoModeChanged(new_mode) -> {
      let live_eff = case model.active_file {
        Some(mod_file) -> {
          let cmd =
            converter.build_live_stereo_command(mod_file.num_channels, new_mode)
          send_command_effect(cmd)
        }
        None -> effect.none()
      }

      let mode_desc = case new_mode {
        StereoHeadphone -> "Stereo separation: 🎧 Headphone (75%)."
        StereoAmiga -> "Stereo separation: 🔊 Authentic Amiga Hardware (100%)."
        StereoMono -> "Stereo separation: 📻 Mono (0%)."
      }

      #(Model(..model, stereo_mode: new_mode, status_text: mode_desc), live_eff)
    }

    MasterVolumeChanged(vol) -> {
      let formatted_db = case vol > 0 {
        True -> "+" <> int.to_string(vol)
        False -> int.to_string(vol)
      }
      #(
        Model(
          ..model,
          master_volume: vol,
          status_text: "Master volume: " <> formatted_db <> " dB",
        ),
        set_master_volume_effect(vol),
      )
    }
  }
}

fn clean_zip_name(filename: String) -> String {
  case
    string.ends_with(filename, ".mod") || string.ends_with(filename, ".MOD")
  {
    True -> string.slice(filename, 0, string.length(filename) - 4) <> ".zip"
    False -> filename <> ".zip"
  }
}

// ---------------------------------------------------------------------------
// Lustre Views
// ---------------------------------------------------------------------------

pub fn view(model: Model) -> Element(Msg) {
  html.div([class("app-shell")], [
    view_header(model),
    html.main([class("main-content")], [
      case model.active_file {
        None -> view_drop_zone(model)
        Some(mod_file) -> view_dashboard(model, mod_file)
      },
    ]),
    view_footer(model),
  ])
}

fn view_header(model: Model) -> Element(Msg) {
  html.header([class("app-header")], [
    html.div([class("brand")], [
      html.h1([], [text("MOD TO SKODE")]),
      html.span([class("badge-version")], [text("v0.2.0")]),
      html.span([class("badge-engine")], [text("Skred v" <> model.engine_version)]),
    ]),
    html.div([class("header-controls")], [
      html.div([class("engine-status")], [
        html.span(
          [
            class(case model.engine_ready {
              True -> "status-dot status-ready"
              False -> "status-dot status-loading"
            }),
          ],
          [],
        ),
        html.span([class("status-label")], [
          text(case model.engine_ready {
            True -> "Audio Engine Ready"
            False -> "Loading WASM..."
          }),
        ]),
      ]),
      html.button(
        [class("btn btn-danger btn-sm"), event.on_click(PanicClicked)],
        [
          text("PANIC"),
        ],
      ),
    ]),
  ])
}

fn view_drop_zone(model: Model) -> Element(Msg) {
  html.div([class("welcome-container")], [
    html.div([class("drop-box"), id("drop-zone")], [
      html.div([class("drop-icon")], [text("🎛️")]),
      html.h2([class("drop-title")], [text("Drop your Amiga .MOD file here")]),
      html.p([class("drop-subtitle")], [
        text(
          "FastTracker / ProTracker 1..32 channel module conversion with complete pitch bend, vibrato & volume envelope preservation.",
        ),
      ]),
      html.div([class("file-select-wrapper")], [
        html.label([class("btn btn-primary btn-lg")], [
          text("Select .MOD File"),
          html.input([
            type_("file"),
            id("file-input"),
            attribute.accept([".mod", ".MOD"]),
            class("hidden-file-input"),
          ]),
        ]),
      ]),
      html.div([class("demo-section")], [
        html.span([class("demo-label")], [
          text("Or try an instant demo module:"),
        ]),
        html.div([class("demo-buttons")], [
          html.button(
            [
              class("btn btn-secondary btn-sm"),
              event.on_click(LoadDemo(
                "demos/space_debris.mod",
                "space_debris.mod",
              )),
              attribute.disabled(model.is_converting),
            ],
            [text("🚀 Space Debris (Captain)")],
          ),
          html.button(
            [
              class("btn btn-secondary btn-sm"),
              event.on_click(LoadDemo("demos/4k_intro.mod", "4k_intro.mod")),
              attribute.disabled(model.is_converting),
            ],
            [text("⚡ 4K Intro Tune")],
          ),
          html.button(
            [
              class("btn btn-modarchive btn-sm"),
              event.on_click(RandomModArchiveClicked),
              attribute.disabled(model.is_converting),
            ],
            [text("🎲 Random from ModArchive")],
          ),
        ]),
      ]),
    ]),
    html.div([class("public-sources-card")], [
      html.div([class("sources-header")], [
        html.h3([class("sources-title")], [text("Need MOD files to try out?")]),
        html.p([class("sources-subtitle")], [
          text(
            "Download thousands of classic Commodore Amiga, demoscene, and tracker music modules from these public archives:",
          ),
        ]),
      ]),
      html.div([class("sources-grid")], [
        html.a(
          [
            class("source-card"),
            href("https://modarchive.org/"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [
            html.div([class("source-badge")], [text("100K+ Tracks")]),
            html.h4([class("source-name")], [text("The Mod Archive ↗")]),
            html.p([class("source-desc")], [
              text(
                "The largest tracker music repository. Search by artist, genre, charts, or staff favorites.",
              ),
            ]),
          ],
        ),
        html.a(
          [
            class("source-card"),
            href("https://amp.dhs.nu/"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [
            html.div([class("source-badge")], [text("Curated Amiga")]),
            html.h4([class("source-name")], [
              text("Amiga Music Preservation ↗"),
            ]),
            html.p([class("source-desc")], [
              text(
                "High-accuracy archive of historical Commodore Amiga demoscene, game, and disk-magazine modules.",
              ),
            ]),
          ],
        ),
        html.a(
          [
            class("source-card"),
            href("https://aminet.net/mods"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [
            html.div([class("source-badge")], [text("Historic Archive")]),
            html.h4([class("source-name")], [text("Aminet (mods) ↗")]),
            html.p([class("source-desc")], [
              text(
                "The official archive of software and music for Amiga computers since 1992.",
              ),
            ]),
          ],
        ),
      ]),
    ]),
    html.div([class("developer-embed-card")], [
      html.div([class("developer-card-header")], [
        html.div([class("developer-badge")], [text("DEVELOPER GUIDE")]),
        html.h3([class("developer-title")], [
          text("Embed Skred & Converted Modules in Your Web App"),
        ]),
        html.p([class("developer-subtitle")], [
          text(
            "Every converted .mod file produces a standalone .zip (main.sk + 16-bit WAVs). You can embed the Skred WebAssembly engine into your own games, web apps, or creative sites with just a few lines of code:",
          ),
        ]),
      ]),
      html.pre([class("developer-code-preview")], [
        html.code([], [
          text(
            "// 1. Include coi-serviceworker.js and vendor/skred/skred_api.js\n// 2. Fetch the generated .zip and write to Emscripten VFS:\nModule.FS.writeFile('/song.zip', new Uint8Array(await zipResponse.arrayBuffer()));\n// 3. Mount and trigger playback:\nModule.ccall('skred_command', 'number', ['string'], ['%z [song.zip]; play']);",
          ),
        ]),
      ]),
    ]),
    html.div([class("features-grid")], [
      feature_card(
        "⚡ 100% Client-Side",
        "Runs entirely inside your browser via WebAssembly & Web Audio. Zero uploads to external servers.",
      ),
      feature_card(
        "🎵 Dual-Track Audio",
        "Unrolls MOD patterns with sub-tick accuracy and adaptive word-budget optimization for Skred.",
      ),
      feature_card(
        "📦 Ready-to-Play ZIP",
        "Generates main.sk alongside 16-bit 16574Hz WAV samples packaged directly in an in-memory ZIP archive.",
      ),
    ]),
    html.div([class("welcome-author-bar")], [
      html.span([], [
        text("Created by "),
        html.a(
          [
            class("author-inline-link"),
            href("https://josephestewart.com"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [text("Joseph Stewart (CV)")],
        ),
        text(" · "),
        html.a(
          [
            class("author-inline-link"),
            href("https://www.youtube.com/@octetta"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [text("YouTube (@octetta) ↗")],
        ),
        text(" · Made with ❤️ in "),
        html.a(
          [
            class("author-inline-link gleam-inline"),
            href("https://gleam.run"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [text("Gleam")],
        ),
        text(" & "),
        html.a(
          [
            class("author-inline-link lustre-inline"),
            href("https://lustre.build"),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [text("Lustre")],
        ),
      ]),
    ]),
  ])
}

fn feature_card(title: String, desc: String) -> Element(Msg) {
  html.div([class("feature-card")], [
    html.h3([], [text(title)]),
    html.p([], [text(desc)]),
  ])
}

fn view_dashboard(model: Model, mod_file: ModFile) -> Element(Msg) {
  html.div([class("dashboard-container")], [
    view_transport_bar(model, mod_file),
    view_metadata_bar(model, mod_file),
    view_tabs_navigation(model),
    view_tab_content(model, mod_file),
  ])
}

fn view_transport_bar(model: Model, _mod_file: ModFile) -> Element(Msg) {
  let play_pause_btn = case model.is_playing {
    False ->
      html.button(
        [
          class("btn btn-success btn-lg"),
          event.on_click(PlayClicked),
          attribute.disabled(model.conversion == None),
        ],
        [text("▶ Play in Skred")],
      )
    True -> {
      case model.is_paused {
        False ->
          html.button(
            [
              class("btn btn-warning btn-lg"),
              event.on_click(PauseClicked),
            ],
            [text("⏸ Pause")],
          )
        True ->
          html.button(
            [
              class("btn btn-success btn-lg pulse-paused"),
              event.on_click(ResumeClicked),
            ],
            [text("▶ Resume")],
          )
      }
    }
  }

  let stop_btn = case model.is_playing {
    True ->
      html.button(
        [
          class("btn btn-danger btn-lg"),
          event.on_click(StopClicked),
        ],
        [text("⏹ Stop")],
      )
    False ->
      html.button(
        [
          class("btn btn-secondary btn-lg"),
          attribute.disabled(True),
        ],
        [text("⏹ Stop")],
      )
  }

  let progress_section = case model.conversion {
    Some(conv) -> {
      let total_rows = conv.total_rows
      let cur_step = case model.is_playing {
        True -> int.min(model.current_step, total_rows - 1)
        False -> 0
      }
      let elapsed_sec = case model.is_playing {
        True -> {
          case dict.get(conv.step_times, cur_step) {
            Ok(t) -> t
            Error(_) -> conv.duration_seconds
          }
        }
        False -> 0.0
      }
      let pct = case conv.duration_seconds >. 0.0 && model.is_playing {
        True -> {
          float.min(
            100.0,
            float.max(0.0, elapsed_sec /. conv.duration_seconds *. 100.0),
          )
        }
        False -> 0.0
      }

      let status_badge = case model.is_playing {
        False ->
          html.span([class("playback-status-badge badge-stopped")], [
            text("STOPPED"),
          ])
        True ->
          case model.is_paused {
            True ->
              html.span([class("playback-status-badge badge-paused")], [
                text("PAUSED"),
              ])
            False ->
              html.span([class("playback-status-badge badge-playing")], [
                text("PLAYING"),
              ])
          }
      }

      html.div([class("playback-tracker")], [
        html.div([class("playback-info-row")], [
          html.div([class("step-counter")], [
            status_badge,
            html.span([class("step-numbers")], [
              text(
                "Step "
                <> case model.is_playing {
                  True -> int.to_string(cur_step + 1)
                  False -> "0"
                }
                <> " / "
                <> int.to_string(total_rows),
              ),
            ]),
          ]),
          html.div([class("time-counter")], [
            text(
              converter.format_duration(elapsed_sec)
              <> " / "
              <> converter.format_duration(conv.duration_seconds),
            ),
          ]),
        ]),
        html.div([class("playback-progress-track")], [
          html.div(
            [
              class(case model.is_playing && !model.is_paused {
                True -> "playback-progress-fill is-active"
                False -> "playback-progress-fill"
              }),
              attribute.style("width", converter.format_float(pct, 1) <> "%"),
            ],
            [],
          ),
        ]),
      ])
    }
    None -> html.div([], [])
  }

  html.div([class("transport-container")], [
    html.div([class("transport-bar")], [
      html.div([class("transport-buttons")], [
        play_pause_btn,
        stop_btn,
        html.button(
          [
            class("btn btn-primary btn-lg"),
            event.on_click(DownloadZipClicked),
            attribute.disabled(model.conversion == None),
          ],
          [text("💾 Download .ZIP")],
        ),
        html.button(
          [
            class("btn btn-modarchive btn-lg"),
            event.on_click(RandomModArchiveClicked),
            attribute.disabled(model.is_converting),
          ],
          [text("🎲 Random MOD")],
        ),
        html.button(
          [class("btn btn-secondary btn-lg"), event.on_click(ResetClicked)],
          [text("⟲ New File")],
        ),
      ]),
      html.div([class("transport-controls-right")], [
        view_volume_slider(model),
        view_stereo_selector(model),
      ]),
    ]),
    progress_section,
  ])
}

fn view_volume_slider(model: Model) -> Element(Msg) {
  let vol_icon = case model.master_volume {
    v if v <= -30 -> "🔈"
    v if v <= -12 -> "🔉"
    _ -> "🔊"
  }
  let vol_str = case model.master_volume > 0 {
    True -> "+" <> int.to_string(model.master_volume) <> " dB"
    False -> int.to_string(model.master_volume) <> " dB"
  }

  html.div([class("volume-control-group")], [
    html.span([class("volume-icon")], [text(vol_icon)]),
    html.span([class("volume-label")], [text("VOL")]),
    html.input([
      type_("range"),
      attribute.min("-40"),
      attribute.max("6"),
      attribute.step("1"),
      attribute.value(int.to_string(model.master_volume)),
      attribute.title("Master volume (" <> vol_str <> ") - Skode V# command"),
      class("volume-slider"),
      event.on_input(fn(val_str) {
        case int.parse(val_str) {
          Ok(v) -> MasterVolumeChanged(v)
          Error(_) -> MasterVolumeChanged(-6)
        }
      }),
    ]),
    html.span([class("volume-value-badge")], [text(vol_str)]),
  ])
}

fn view_stereo_selector(model: Model) -> Element(Msg) {
  html.div([class("stereo-control-group")], [
    html.span([class("stereo-label")], [text("STEREO")]),
    html.div([class("segmented-control")], [
      html.button(
        [
          class(case model.stereo_mode {
            StereoHeadphone -> "segment-btn active"
            _ -> "segment-btn"
          }),
          event.on_click(StereoModeChanged(StereoHeadphone)),
          attribute.title(
            "Headphone separation (75%) - Prevents ear fatigue on headphones/earbuds",
          ),
        ],
        [text("🎧 75%")],
      ),
      html.button(
        [
          class(case model.stereo_mode {
            StereoAmiga -> "segment-btn active"
            _ -> "segment-btn"
          }),
          event.on_click(StereoModeChanged(StereoAmiga)),
          attribute.title(
            "Authentic Paula Hardware (100% L-R-R-L) - True Amiga separation",
          ),
        ],
        [text("🔊 Amiga 100%")],
      ),
      html.button(
        [
          class(case model.stereo_mode {
            StereoMono -> "segment-btn active"
            _ -> "segment-btn"
          }),
          event.on_click(StereoModeChanged(StereoMono)),
          attribute.title("Mono (0%) - Centers all channels"),
        ],
        [text("📻 Mono")],
      ),
    ]),
  ])
}

fn view_metadata_bar(model: Model, mod_file: ModFile) -> Element(Msg) {
  let clean_title = case string.trim(mod_file.title) {
    "" -> "(Untitled)"
    t -> t
  }

  let duration_str = case model.conversion {
    Some(conv) -> converter.format_duration(conv.duration_seconds)
    None -> "--:--"
  }

  let rows_str = case model.conversion {
    Some(conv) -> int.to_string(conv.total_rows) <> " rows"
    None -> int.to_string(mod_file.song_length) <> " patterns"
  }

  let source_items = case model.modarchive_info {
    Some(info) -> [
      html.div([class("meta-item meta-item-modarchive")], [
        html.span([class("meta-label")], [text("MODARCHIVE")]),
        html.a(
          [
            class("meta-link-modarchive"),
            href("https://modarchive.org/module.php?" <> int.to_string(info.id)),
            target("_blank"),
            rel("noopener noreferrer"),
          ],
          [
            text("#" <> int.to_string(info.id) <> " by " <> info.artist <> " ↗"),
          ],
        ),
      ]),
    ]
    None -> []
  }

  let stereo_str = case model.stereo_mode {
    StereoHeadphone -> "75% (Headphones)"
    StereoAmiga -> "100% (Amiga HW)"
    StereoMono -> "Mono"
  }

  let vol_display = case model.master_volume > 0 {
    True -> "+" <> int.to_string(model.master_volume) <> " dB"
    False -> int.to_string(model.master_volume) <> " dB"
  }

  let base_items = [
    meta_item("TITLE", clean_title),
    meta_item("FILE", mod_file.filename),
    meta_item("CHANNELS", int.to_string(mod_file.num_channels) <> " CH"),
    meta_item("STEREO", stereo_str),
    meta_item("MASTER VOL", vol_display),
    meta_item("DURATION", duration_str),
    meta_item("LENGTH", rows_str),
    meta_item("PATTERNS", int.to_string(list.length(mod_file.patterns))),
    meta_item("VERSION", "v0.2.0"),
  ]

  html.div([class("meta-bar")], list.append(base_items, source_items))
}

fn meta_item(label: String, val: String) -> Element(Msg) {
  html.div([class("meta-item")], [
    html.span([class("meta-label")], [text(label)]),
    html.span([class("meta-value")], [text(val)]),
  ])
}

fn view_tabs_navigation(model: Model) -> Element(Msg) {
  html.div([class("tabs-nav")], [
    tab_button("info", "Instruments & Samples", model.active_tab),
    tab_button("skode", "Generated Skode (main.sk)", model.active_tab),
    tab_button("samples", "WAV Sample Blobs", model.active_tab),
    tab_button("embed", "Embed in Your Page 🛠️", model.active_tab),
  ])
}

fn tab_button(
  tab_id: String,
  label: String,
  active_tab: String,
) -> Element(Msg) {
  let is_active = tab_id == active_tab
  html.button(
    [
      class(case is_active {
        True -> "tab-btn active"
        False -> "tab-btn"
      }),
      event.on_click(TabSelected(tab_id)),
    ],
    [text(label)],
  )
}

fn view_tab_content(model: Model, mod_file: ModFile) -> Element(Msg) {
  case model.active_tab {
    "info" -> view_instruments_table(mod_file.instruments, model.is_playing)
    "skode" -> view_skode_code(model.conversion)
    "samples" -> view_samples_list(model.conversion)
    "embed" -> view_embed_guide(model, mod_file)
    _ -> view_instruments_table(mod_file.instruments, model.is_playing)
  }
}

fn view_embed_guide(_model: Model, mod_file: ModFile) -> Element(Msg) {
  let zip_name = clean_zip_name(mod_file.filename)
  html.div([class("embed-guide-container")], [
    html.div([class("embed-header-card")], [
      html.h3([class("embed-title")], [
        text("Embed " <> zip_name <> " in Your Web Application"),
      ]),
      html.p([class("embed-desc")], [
        text(
          "Follow these three steps to integrate the Skred audio engine and play this converted module on your own website.",
        ),
      ]),
    ]),
    embed_step_card(
      "1. Assets & Project Files",
      "Save the converted ZIP archive and include the vendored Skred WebAssembly runtime files:",
      [
        html.ul([class("embed-steps-list")], [
          html.li([], [
            text("Download the converted archive as "),
            html.code([class("inline-code")], [text(zip_name)]),
            text(" (using the 'Download .ZIP' button in the toolbar above)."),
          ]),
          html.li([], [
            text("Copy "),
            html.code([class("inline-code")], [
              text("vendor/skred/skred_api.js"),
            ]),
            text(" and "),
            html.code([class("inline-code")], [
              text("vendor/skred/skred_api.wasm"),
            ]),
            text(" into your web app directory."),
          ]),
          html.li([], [
            text("Include "),
            html.code([class("inline-code")], [text("coi-serviceworker.js")]),
            text(
              " to enable SharedArrayBuffer multi-threading without requiring specialized server headers.",
            ),
          ]),
        ]),
      ],
    ),
    embed_step_card(
      "2. HTML Header Setup",
      "Include the coi-serviceworker and configure window.Module.locateFile before loading skred_api.js:",
      [
        html.pre([class("code-block")], [
          html.code([], [
            text(
              "<!-- 1. Enable SharedArrayBuffer isolation via Service Worker -->\n<script src=\"coi-serviceworker.js\"></script>\n\n<!-- 2. Configure Emscripten Module locateFile -->\n<script>\n  window.Module = {\n    locateFile: (path) => `./vendor/skred/${path}`,\n    print: (msg) => console.log('[Skred]', msg),\n    printErr: (msg) => console.error('[Skred ERR]', msg),\n  };\n</script>\n\n<!-- 3. Load Skred WebAssembly Audio Engine -->\n<script src=\"vendor/skred/skred_api.js\"></script>",
            ),
          ]),
        ]),
      ],
    ),
    embed_step_card(
      "3. JavaScript Playback Controller",
      "Unlock audio on first user gesture, mount the ZIP into the virtual filesystem, and trigger playback:",
      [
        html.pre([class("code-block")], [
          html.code([], [
            text(
              "// Start Audio on User Interaction (Click or Tap)\ndocument.getElementById('play-btn').addEventListener('click', async () => {\n  const M = window.Module;\n  \n  // Resume Web Audio Context if suspended\n  if (M.audioContext && M.audioContext.state === 'suspended') {\n    await M.audioContext.resume();\n  }\n  \n  // Start hardware audio device (128 buffer size, 256 voices)\n  if (typeof M._skred_start === 'function') {\n    M._skred_enumerate_devices?.(0);\n    M._skred_audio_select?.(0, 0);\n    M._skred_audio_select?.(1, -2);\n    M._skred_start(128, 256, -1);\n  }\n  \n  // Clean previous playback, unmount zip, clear patterns and voices\n  M.ccall('skred_command', 'number', ['string'], ['stop']);\n  M.ccall('skred_command', 'number', ['string'], ['%zu']);\n  M.ccall('skred_command', 'number', ['string'], ['Y-1']);\n  M.ccall('skred_command', 'number', ['string'], ['S-1']);\n\n  // Fetch and mount "
              <> zip_name
              <> " into Skred Virtual File System\n  const res = await fetch('./"
              <> zip_name
              <> "');\n  const zipBuf = await res.arrayBuffer();\n  M.FS.writeFile('/song.zip', new Uint8Array(zipBuf));\n  \n  // Mount zip via Skode VFS (%z) and load script\n  M.ccall('skred_command', 'number', ['string'], ['%z [song.zip];']);\n  M.ccall('skred_command', 'number', ['string'], ['play']);\n});\n\n// Stop, unmount, clear patterns, and silence audio\ndocument.getElementById('stop-btn').addEventListener('click', () => {\n  const M = window.Module;\n  M.ccall('skred_command', 'number', ['string'], ['stop']);\n  M.ccall('skred_command', 'number', ['string'], ['%zu']);\n  M.ccall('skred_command', 'number', ['string'], ['Y-1']);\n  M.ccall('skred_command', 'number', ['string'], ['S-1']);\n});",
            ),
          ]),
        ]),
      ],
    ),
  ])
}

fn embed_step_card(
  title: String,
  desc: String,
  children: List(Element(Msg)),
) -> Element(Msg) {
  html.div([class("embed-step-card")], [
    html.h4([class("embed-step-title")], [text(title)]),
    html.p([class("embed-step-desc")], [text(desc)]),
    html.div([class("embed-step-body")], children),
  ])
}

fn view_instruments_table(
  instruments: List(Instrument),
  is_playing: Bool,
) -> Element(Msg) {
  html.div([class("table-container")], [
    html.table([class("tracker-table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [text("#")]),
          html.th([], [text("Audition")]),
          html.th([], [text("Sample Name")]),
          html.th([], [text("Length (bytes)")]),
          html.th([], [text("Volume (0..64)")]),
          html.th([], [text("Finetune / Cents")]),
          html.th([], [text("Loop")]),
        ]),
      ]),
      html.tbody(
        [],
        list.map(instruments, fn(ins) { view_instrument_row(ins, is_playing) }),
      ),
    ]),
  ])
}

fn view_instrument_row(ins: Instrument, is_playing: Bool) -> Element(Msg) {
  let id_str = case ins.id < 10 {
    True -> "0" <> int.to_string(ins.id)
    False -> int.to_string(ins.id)
  }
  let loop_info = case ins.wants_loop {
    True ->
      int.to_string(ins.loop_start)
      <> " .. "
      <> int.to_string(ins.loop_start + ins.loop_len)
    False -> "None"
  }

  let audition_elem = case ins.len > 2 {
    True ->
      html.button(
        [
          class("btn btn-secondary btn-sm audition-btn"),
          event.on_click(PreviewSampleClicked(ins.id)),
          attribute.disabled(is_playing),
          attribute.title(case is_playing {
            True -> "Preview disabled while playing"
            False -> "Preview instrument #" <> int.to_string(ins.id)
          }),
        ],
        [text("🔊 Play")],
      )
    False -> html.span([class("audition-empty")], [text("-")])
  }

  html.tr(
    [
      class(case ins.len > 2 {
        True -> "row-active"
        False -> "row-empty"
      }),
    ],
    [
      html.td([class("td-id")], [text(id_str)]),
      html.td([class("td-audition")], [audition_elem]),
      html.td([class("td-name")], [text(ins.name)]),
      html.td([], [text(int.to_string(ins.len))]),
      html.td([], [text(int.to_string(ins.vol))]),
      html.td([], [
        text(
          int.to_string(ins.finetune)
          <> " ("
          <> converter.format_float(ins.cents, 1)
          <> "c)",
        ),
      ]),
      html.td([], [text(loop_info)]),
    ],
  )
}

fn view_skode_code(conv_opt: option.Option(ConversionResult)) -> Element(Msg) {
  case conv_opt {
    Some(conv) -> {
      let preview_text = get_preview_lines(conv.skode_text, 500)
      html.div([class("code-container")], [
        html.pre([class("skode-view")], [
          html.code([], [text(preview_text)]),
        ]),
      ])
    }
    None ->
      html.div([class("empty-notice")], [text("No converted script available.")])
  }
}

fn get_preview_lines(content: String, max_lines: Int) -> String {
  let lines = string.split(content, "\n")
  let total = list.length(lines)
  case total > max_lines {
    True -> {
      let preview =
        lines
        |> list.take(max_lines)
        |> string.join("\n")
      preview
      <> "\n\n// ... [Showing first "
      <> int.to_string(max_lines)
      <> " lines of "
      <> int.to_string(total)
      <> " total lines. Download the complete .ZIP to view the entire main.sk script] ...\n"
    }
    False -> content
  }
}

fn view_samples_list(
  conv_opt: option.Option(ConversionResult),
) -> Element(Msg) {
  case conv_opt {
    Some(conv) -> {
      html.div([class("samples-grid")], [
        html.table([class("tracker-table")], [
          html.thead([], [
            html.tr([], [
              html.th([], [text("Target File Path")]),
              html.th([], [text("Sample Rate")]),
              html.th([], [text("Bit Depth")]),
              html.th([], [text("Channels")]),
            ]),
          ]),
          html.tbody(
            [],
            list.map(conv.samples, fn(item) {
              html.tr([], [
                html.td([class("td-name")], [text(item.0)]),
                html.td([], [text("16,574 Hz")]),
                html.td([], [text("16-bit PCM")]),
                html.td([], [text("Mono (1 ch)")]),
              ])
            }),
          ),
        ]),
      ])
    }
    None -> html.div([class("empty-notice")], [text("No samples generated.")])
  }
}

fn view_footer(model: Model) -> Element(Msg) {
  html.footer([class("app-footer")], [
    html.span([class("status-message")], [text(model.status_text)]),
    html.div([class("footer-links")], [
      html.a(
        [
          class("footer-link"),
          href("https://josephestewart.com"),
          target("_blank"),
          rel("noopener noreferrer"),
          attribute.title("Joseph Stewart - CV & Projects"),
        ],
        [text("Joseph Stewart (CV)")],
      ),
      html.span([class("footer-separator")], [text("·")]),
      html.a(
        [
          class("footer-link"),
          href("https://www.youtube.com/@octetta"),
          target("_blank"),
          rel("noopener noreferrer"),
          attribute.title("YouTube (@octetta)"),
        ],
        [text("YouTube ↗")],
      ),
      html.span([class("footer-separator")], [text("·")]),
      html.span([class("footer-love")], [
        html.span([class("heart-icon")], [text("❤️ ")]),
        html.a(
          [
            class("footer-link gleam-link"),
            href("https://gleam.run"),
            target("_blank"),
            rel("noopener noreferrer"),
            attribute.title(
              "Gleam: A friendly language for building type-safe systems that scale",
            ),
          ],
          [text("Gleam")],
        ),
        text(" & "),
        html.a(
          [
            class("footer-link lustre-link"),
            href("https://lustre.build"),
            target("_blank"),
            rel("noopener noreferrer"),
            attribute.title(
              "Lustre: A fast, delightful frontend framework for Gleam",
            ),
          ],
          [text("Lustre")],
        ),
      ]),
      html.span([class("footer-separator")], [text("·")]),
      html.a(
        [
          class("footer-link"),
          href("https://modarchive.org/"),
          target("_blank"),
          rel("noopener noreferrer"),
        ],
        [text("ModArchive ↗")],
      ),
      html.span([class("footer-separator")], [text("·")]),
      html.span([class("version-tag")], [text("v0.2.0")]),
    ]),
  ])
}

// ---------------------------------------------------------------------------
// Main Application Entry Point
// ---------------------------------------------------------------------------

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
