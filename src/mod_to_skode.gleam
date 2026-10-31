//// # Mod-to-Skode In-Browser Audio Converter & Tracker Web App
////
//// Runs client-side in the browser, converts Amiga / ProTracker MOD files
//// to Skode 0.80.0 scripts, packages them with WAV samples into a ZIP archive,
//// and allows instant playback directly in the Skred WASM audio engine.

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
  FileDropped, LoadDemo, Model, PanicClicked, PlayClicked, ResetClicked,
  StopClicked, TabSelected,
}

// ---------------------------------------------------------------------------
// JavaScript FFI Declarations
// ---------------------------------------------------------------------------

@external(javascript, "./skred_ffi.mjs", "initEngine")
fn js_init_engine(callback: fn(Bool) -> Nil) -> Nil

@external(javascript, "./skred_ffi.mjs", "registerFileDrop")
fn js_register_file_drop(callback: fn(String, BitArray) -> Nil) -> Nil

@external(javascript, "./skred_ffi.mjs", "loadUrlMod")
fn js_load_url_mod(
  url: String,
  filename: String,
  callback: fn(String, BitArray) -> Nil,
) -> Nil

@external(javascript, "./skred_ffi.mjs", "loadAndPlaySkode")
fn js_load_and_play_skode(
  main_sk: String,
  samples: List(#(String, BitArray)),
) -> Nil

@external(javascript, "./skred_ffi.mjs", "stopPlayback")
fn js_stop_playback() -> Nil

@external(javascript, "./skred_ffi.mjs", "panicEngine")
fn js_panic_engine() -> Nil

@external(javascript, "./skred_ffi.mjs", "downloadZip")
fn js_download_zip(
  main_sk: String,
  samples: List(#(String, BitArray)),
  filename: String,
) -> Nil

// ---------------------------------------------------------------------------
// Lustre Effects
// ---------------------------------------------------------------------------

fn init_engine_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_init_engine(fn(success) { dispatch(EngineStatusChanged(success)) })
  })
}

fn register_file_drop_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_register_file_drop(fn(filename, data) {
      dispatch(FileDropped(filename, data))
    })
  })
}

fn load_demo_effect(url: String, filename: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    js_load_url_mod(url, filename, fn(name, data) {
      dispatch(FileDropped(name, data))
    })
  })
}

fn play_effect(
  main_sk: String,
  samples: List(#(String, BitArray)),
) -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_load_and_play_skode(main_sk, samples) })
}

fn stop_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_stop_playback() })
}

fn panic_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { js_panic_engine() })
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
      is_playing: False,
      active_file: None,
      conversion: None,
      is_converting: False,
      error_message: None,
      status_text: "Ready. Drag and drop any .mod file to convert.",
      active_tab: "info",
    )

  let effects =
    effect.batch([
      init_engine_effect(),
      register_file_drop_effect(),
    ])

  #(model, effects)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    EngineStatusChanged(ready) -> {
      let status = case ready {
        True -> "Skred 0.80.0 WASM engine ready."
        False -> "Failed to initialize Skred WASM."
      }
      #(Model(..model, engine_ready: ready, status_text: status), effect.none())
    }

    FileDropped(filename, data) -> {
      case mod_parser.parse(filename, data) {
        Error(err) -> {
          #(
            Model(
              ..model,
              error_message: Some(err),
              is_converting: False,
              status_text: "Parse error: " <> err,
            ),
            effect.none(),
          )
        }
        Ok(mod_file) -> {
          case converter.convert(mod_file) {
            Error(err) -> {
              #(
                Model(
                  ..model,
                  active_file: Some(mod_file),
                  error_message: Some(err),
                  is_converting: False,
                  status_text: "Conversion error: " <> err,
                ),
                effect.none(),
              )
            }
            Ok(conv_res) -> {
              #(
                Model(
                  ..model,
                  active_file: Some(mod_file),
                  conversion: Some(conv_res),
                  is_converting: False,
                  error_message: None,
                  status_text: "Successfully converted "
                    <> filename
                    <> " ("
                    <> int.to_string(conv_res.total_rows)
                    <> " rows).",
                ),
                effect.none(),
              )
            }
          }
        }
      }
    }

    ConvertClicked -> {
      case model.active_file {
        Some(mod_file) -> {
          case converter.convert(mod_file) {
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
              status_text: "Playing in Skred WASM...",
            ),
            play_effect(res.skode_text, res.samples),
          )
        }
        None -> #(model, effect.none())
      }
    }

    StopClicked -> {
      #(
        Model(..model, is_playing: False, status_text: "Playback stopped."),
        stop_effect(),
      )
    }

    PanicClicked -> {
      #(
        Model(..model, is_playing: False, status_text: "Engine silenced (S-1)."),
        panic_effect(),
      )
    }

    DownloadZipClicked -> {
      case model.conversion, model.active_file {
        Some(res), Some(mod_file) -> {
          let zip_name = clean_zip_name(mod_file.filename)
          #(
            Model(..model, status_text: "Downloading " <> zip_name <> "..."),
            download_zip_effect(res.skode_text, res.samples, zip_name),
          )
        }
        _, _ -> #(model, effect.none())
      }
    }

    ResetClicked -> {
      let eff = case model.is_playing {
        True -> stop_effect()
        False -> effect.none()
      }
      #(
        Model(
          ..model,
          active_file: None,
          conversion: None,
          is_playing: False,
          error_message: None,
          status_text: "Ready. Drag and drop any .mod file to convert.",
        ),
        eff,
      )
    }

    TabSelected(tab) -> {
      #(Model(..model, active_tab: tab), effect.none())
    }

    LoadDemo(url, filename) -> {
      #(
        Model(
          ..model,
          is_converting: True,
          status_text: "Downloading & converting demo " <> filename <> "...",
        ),
        load_demo_effect(url, filename),
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
      html.span([class("badge-version")], [text("Skred v0.80.0")]),
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
            "// 1. Include coi-serviceworker.js and vendor/skred/skred_api.js\n// 2. Fetch the generated .zip and write to Emscripten VFS:\nModule.FS.writeFile('/song.zip', new Uint8Array(await zipResponse.arrayBuffer()));\n// 3. Mount and trigger playback:\nModule.ccall('skred_command', 'number', ['string'], ['%z /song.zip; [main.sk] /ls; play']);",
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
        "Unrolls MOD patterns with sub-tick accuracy and adaptive word-budget optimization for Skred 0.80.0.",
      ),
      feature_card(
        "📦 Ready-to-Play ZIP",
        "Generates main.sk alongside 16-bit 16574Hz WAV samples packaged directly in an in-memory ZIP archive.",
      ),
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
  html.div([class("transport-bar")], [
    html.div([class("transport-buttons")], [
      case model.is_playing {
        False ->
          html.button(
            [
              class("btn btn-success btn-lg"),
              event.on_click(PlayClicked),
              attribute.disabled(model.conversion == None),
            ],
            [text("▶ Play in Skred")],
          )
        True ->
          html.button(
            [
              class("btn btn-warning btn-lg pulse-playing"),
              event.on_click(StopClicked),
            ],
            [text("⏹ Stop")],
          )
      },
      html.button(
        [
          class("btn btn-primary btn-lg"),
          event.on_click(DownloadZipClicked),
          attribute.disabled(model.conversion == None),
        ],
        [text("💾 Download .ZIP")],
      ),
      html.button(
        [class("btn btn-secondary btn-lg"), event.on_click(ResetClicked)],
        [
          text("⟲ New File"),
        ],
      ),
    ]),
  ])
}

fn view_metadata_bar(_model: Model, mod_file: ModFile) -> Element(Msg) {
  let clean_title = case string.trim(mod_file.title) {
    "" -> "(Untitled)"
    t -> t
  }

  html.div([class("meta-bar")], [
    meta_item("TITLE", clean_title),
    meta_item("FILE", mod_file.filename),
    meta_item("CHANNELS", int.to_string(mod_file.num_channels) <> " CH"),
    meta_item("SONG LENGTH", int.to_string(mod_file.song_length) <> " patterns"),
    meta_item("PATTERNS IN FILE", int.to_string(list.length(mod_file.patterns))),
  ])
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
    "info" -> view_instruments_table(mod_file.instruments)
    "skode" -> view_skode_code(model.conversion)
    "samples" -> view_samples_list(model.conversion)
    "embed" -> view_embed_guide(model, mod_file)
    _ -> view_instruments_table(mod_file.instruments)
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
          "Follow these three steps to integrate the Skred v0.80.0 audio engine and play this converted module on your own website.",
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
              "// Start Audio on User Interaction (Click or Tap)\ndocument.getElementById('play-btn').addEventListener('click', async () => {\n  const M = window.Module;\n  \n  // Resume Web Audio Context if suspended\n  if (M.audioContext && M.audioContext.state === 'suspended') {\n    await M.audioContext.resume();\n  }\n  \n  // Start hardware audio device (128 buffer size, 256 voices)\n  if (typeof M._skred_start === 'function') {\n    M._skred_enumerate_devices?.(0);\n    M._skred_audio_select?.(0, 0);\n    M._skred_audio_select?.(1, -2);\n    M._skred_start(128, 256, -1);\n  }\n  \n  // Fetch and mount "
              <> zip_name
              <> " into Skred Virtual File System\n  const res = await fetch('./"
              <> zip_name
              <> "');\n  const zipBuf = await res.arrayBuffer();\n  M.FS.writeFile('/song.zip', new Uint8Array(zipBuf));\n  \n  // Mount zip via Skode VFS (%z) and load script\n  M.ccall('skred_command', 'number', ['string'], ['%z /song.zip']);\n  M.ccall('skred_command', 'number', ['string'], ['[main.sk] /ls']);\n  M.ccall('skred_command', 'number', ['string'], ['play']);\n});\n\n// Stop and silence audio\ndocument.getElementById('stop-btn').addEventListener('click', () => {\n  const M = window.Module;\n  M.ccall('skred_command', 'number', ['string'], ['stop']);\n  M.ccall('skred_command', 'number', ['string'], ['S-1']); // Panic: silence all voices\n});",
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

fn view_instruments_table(instruments: List(Instrument)) -> Element(Msg) {
  html.div([class("table-container")], [
    html.table([class("tracker-table")], [
      html.thead([], [
        html.tr([], [
          html.th([], [text("#")]),
          html.th([], [text("Sample Name")]),
          html.th([], [text("Length (bytes)")]),
          html.th([], [text("Volume (0..64)")]),
          html.th([], [text("Finetune / Cents")]),
          html.th([], [text("Loop")]),
        ]),
      ]),
      html.tbody([], list.map(instruments, view_instrument_row)),
    ]),
  ])
}

fn view_instrument_row(ins: Instrument) -> Element(Msg) {
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

  html.tr(
    [
      class(case ins.len > 2 {
        True -> "row-active"
        False -> "row-empty"
      }),
    ],
    [
      html.td([class("td-id")], [text(id_str)]),
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
      html.div([class("code-container")], [
        html.pre([class("skode-view")], [
          html.code([], [text(conv.skode_text)]),
        ]),
      ])
    }
    None ->
      html.div([class("empty-notice")], [text("No converted script available.")])
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
          href("https://modarchive.org/"),
          target("_blank"),
          rel("noopener noreferrer"),
        ],
        [text("The Mod Archive ↗")],
      ),
      html.span([class("footer-separator")], [text("·")]),
      html.span([], [text("MOD-to-Skode · Octetta")]),
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
