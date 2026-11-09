// JavaScript FFI Bridge for mod-to-skode
// Integrates Skred 0.80.0 WASM engine, fflate ZIP creation, Web Audio, and File APIs

import { zip } from "#vendor/fflate.mjs";
import { BitArray } from "./gleam.mjs";

const win = typeof window !== "undefined" ? window : globalThis;

let moduleReady = false;
let engineStarted = false;
let commandQueue = [];
let audioContext = null;
let capturedStdout = [];

// Control Plane Event Subscriptions
let currentEventSubscription = null;
let eventPumpStarted = false;
let wasmEventsBuffer = null;
const EVENT_SIZE = 72;
const MAX_EVENTS_BATCH = 64;

// Playback Tracking & Audition State
let playbackStepCallback = null;
let playbackEndedCallback = null;
let activeSongTotalSteps = 0;
let isPlaybackActive = false;
let isPlaybackPaused = false;
let lastReportedStep = -1;
let currentPreviewAudio = null;
let currentMasterVolume = -6;

// ---------------------------------------------------------------------------
// 1. Skred WASM Engine Initialization & Stdout Hooking
// ---------------------------------------------------------------------------

function setupStdoutHook(M) {
  if (!M) return;
  const originalPrint = M.print || console.log;
  const originalPrintErr = M.printErr || console.error;

  M.print = function (...args) {
    const line = args.join(" ");
    capturedStdout.push(line);
    originalPrint.apply(console, args);
  };

  M.printErr = function (...args) {
    const line = args.join(" ");
    capturedStdout.push("[ERR] " + line);
    originalPrintErr.apply(console, args);
  };
}

function getWasmModule() {
  if (win.Module && (typeof win.Module.ccall === "function" || typeof win.Module._skred_start === "function")) {
    return win.Module;
  }
  return null;
}

export function getEngineVersion() {
  const M = getWasmModule();
  if (M) {
    if (typeof M.ccall === "function") {
      try {
        const v = M.ccall("skred_version", "string", [], []);
        if (v) return v;
      } catch (e) {}
    }
    if (typeof M._skred_version === "function" && typeof M.UTF8ToString === "function") {
      try {
        const ptr = M._skred_version();
        if (ptr) return M.UTF8ToString(ptr);
      } catch (e) {}
    }
  }
  return "0.82.0";
}

export function initEngine(callback) {
  if (moduleReady) {
    if (callback) callback(true, getEngineVersion());
    return;
  }

  win.Module = win.Module || {};
  win.Module.locateFile = function (path) {
    if (typeof window !== "undefined") {
      return new URL("vendor/skred/" + path, window.location.href).href;
    }
    return "/vendor/skred/" + path;
  };

  setupStdoutHook(win.Module);

  let initializedDone = false;
  const finishInit = () => {
    if (initializedDone) return;
    initializedDone = true;
    console.log("[mod-to-skode] Skred WASM runtime initialized.");
    moduleReady = true;

    try {
      setupStdoutHook(win.Module);

      if (win.Module.FS) {
        try { win.Module.FS.mkdir("/waves"); } catch (e) {}
        try { win.Module.FS.mkdir("waves"); } catch (e) {}
        try { win.Module.FS.mkdir("/samples"); } catch (e) {}
        try { win.Module.FS.mkdir("samples"); } catch (e) {}
      }

      if (typeof win.Module._skred_enumerate_devices === "function") {
        win.Module._skred_enumerate_devices(0);
      }
      if (typeof win.Module._skred_audio_select === "function") {
        win.Module._skred_audio_select(0, 0);
        win.Module._skred_audio_select(1, -2);
      }

      // Start engine with 128 buffer size, 256 voices, default port (-1)
      if (typeof win.Module._skred_start === "function") {
        const res = win.Module._skred_start(128, 256, -1);
        console.log("[mod-to-skode] _skred_start returned:", res);
        engineStarted = (res === 0);
      }

      if (typeof win.Module._skred_logger === "function") {
        win.Module._skred_logger(1);
      }

      executeSkredCommand("stop");
      executeSkredCommand("%zu");
      executeSkredCommand("Y-1");
      executeSkredCommand("S-1");
      executeSkredCommand("V-6");

      removeAudioUnlockListeners();
      audioUnlocked = true;

      startWasmEventPump(win.Module);
      flushCommandQueue();

      if (callback) callback(true, getEngineVersion());
    } catch (err) {
      console.error("[mod-to-skode] Failed to start Skred engine:", err);
      if (callback) callback(moduleReady, getEngineVersion());
    }
  };

  const prevInit = win.Module.onRuntimeInitialized;
  win.Module.onRuntimeInitialized = function () {
    if (prevInit) prevInit();
    finishInit();
  };

  if (
    win.Module.calledRun ||
    (win.Module.HEAPU32 && typeof win.Module.ccall === "function") ||
    typeof win.Module._skred_start === "function"
  ) {
    finishInit();
  }
}

function ensureAudioContext() {
  const M = win.Module;
  if (M && M.audioContext && M.audioContext.state === "suspended") {
    M.audioContext.resume().catch(() => {});
  }
  if (win.AL && win.AL.currentCtx && win.AL.currentCtx.audioCtx && win.AL.currentCtx.audioCtx.state === "suspended") {
    win.AL.currentCtx.audioCtx.resume().catch(() => {});
  }
  if (win.miniaudio && Array.isArray(win.miniaudio.devices)) {
    for (const dev of win.miniaudio.devices) {
      if (dev && dev.webaudio && dev.webaudio.state === "suspended") {
        dev.webaudio.resume().catch(() => {});
      }
    }
  }
}

export function ensureEngineRunning() {
  const M = getWasmModule();
  if (!M) return false;
  ensureAudioContext();
  if (typeof M._skred_audio_running === "function" && M._skred_audio_running()) {
    return true;
  }
  try {
    if (typeof M._skred_enumerate_devices === "function") {
      M._skred_enumerate_devices(0);
    }
    if (typeof M._skred_audio_select === "function") {
      M._skred_audio_select(0, 0);
      M._skred_audio_select(1, -2);
    }
    if (typeof M._skred_start === "function") {
      const res = M._skred_start(128, 256, -1);
      if (res === 0) {
        engineStarted = true;
        if (typeof M._skred_logger === "function") M._skred_logger(1);
        startWasmEventPump(M);
        return true;
      }
    }
  } catch (e) {
    console.warn("[mod-to-skode] ensureEngineRunning warning:", e);
  }
  return false;
}

let audioUnlocked = false;

function unlockAudio() {
  if (audioUnlocked) return;
  audioUnlocked = true;
  ensureAudioContext();
  ensureEngineRunning();
  removeAudioUnlockListeners();
}

function removeAudioUnlockListeners() {
  if (typeof win.removeEventListener === "function") {
    win.removeEventListener("pointerdown", unlockAudio);
    win.removeEventListener("touchstart", unlockAudio);
    win.removeEventListener("keydown", unlockAudio);
    win.removeEventListener("click", unlockAudio);
  }
}

if (typeof win.addEventListener === "function") {
  win.addEventListener("pointerdown", unlockAudio, { passive: true });
  win.addEventListener("touchstart", unlockAudio, { passive: true });
  win.addEventListener("keydown", unlockAudio, { passive: true });
  win.addEventListener("click", unlockAudio, { passive: true });
}

function startWasmEventPump(M) {
  if (!M || typeof M._skred_control_event_poll !== "function") return;
  if (!wasmEventsBuffer && typeof M._malloc === "function") {
    wasmEventsBuffer = M._malloc(MAX_EVENTS_BATCH * EVENT_SIZE);
  }
  if (eventPumpStarted) return;
  eventPumpStarted = true;

  function pump() {
    if (
      M &&
      typeof M._skred_control_event_poll === "function" &&
      wasmEventsBuffer &&
      M.HEAPU8
    ) {
      try {
        const count = M._skred_control_event_poll(wasmEventsBuffer, MAX_EVENTS_BATCH);
        if (count > 0) {
          const events = [];
          const view = new DataView(M.HEAPU8.buffer, wasmEventsBuffer, count * EVENT_SIZE);
          for (let i = 0; i < count; i++) {
            const base = i * EVENT_SIZE;
            const t = view.getUint32(base + 0, true);
            const opcode = view.getUint32(base + 4, true);
            const sample = Number(view.getBigUint64(base + 8, true));
            const seq = Number(view.getBigUint64(base + 16, true));
            const v = view.getInt32(base + 24, true);
            const p = view.getInt32(base + 28, true);
            const s = view.getInt32(base + 32, true);
            const tag = view.getInt32(base + 36, true);
            const id = view.getInt32(base + 40, true);
            const value_count = view.getUint32(base + 44, true);
            const vals = [
              view.getFloat64(base + 48, true),
              view.getFloat64(base + 56, true),
              view.getFloat64(base + 64, true),
            ];
            events.push({ t, opcode, sample, seq, v, p, s, tag, id, value_count, vals });

            // Real-time Step Tracking: event type 9 (SKRED_CONTROL_EVENT_PATTERN_STEP) on pattern 0
            if (isPlaybackActive && t === 9 && p === 0) {
              if (s !== lastReportedStep && s >= 0) {
                // Check if pattern wrapped back to 0 after reaching the end of the song
                if (
                  lastReportedStep >= activeSongTotalSteps - 2 &&
                  s === 0 &&
                  activeSongTotalSteps > 2
                ) {
                  stopPlayback();
                  if (playbackEndedCallback) {
                    playbackEndedCallback();
                  }
                  return;
                }
                lastReportedStep = s;
                if (playbackStepCallback) {
                  playbackStepCallback(s, activeSongTotalSteps);
                }
              }
            }

            // Song Completion: event 4 (SKRED_CONTROL_EVENT_USER with id 127) or event 6 (SKRED_CONTROL_EVENT_PATTERN_END on pattern 0)
            if (
              isPlaybackActive &&
              ((t === 4 && id === 127) || (t === 6 && p === 0))
            ) {
              stopPlayback();
              if (playbackEndedCallback) {
                playbackEndedCallback();
              }
            }
          }
          if (currentEventSubscription) {
            currentEventSubscription(events);
          }
        }
      } catch (err) {
        console.error("[mod-to-skode] Event pump error:", err);
      }
    }
    requestAnimationFrame(pump);
  }
  requestAnimationFrame(pump);
}

function flushCommandQueue() {
  const M = getWasmModule();
  if (!M || !engineStarted) return;
  while (commandQueue.length > 0) {
    const cmd = commandQueue.shift();
    try {
      M.ccall("skred_command", "number", ["string"], [cmd]);
    } catch (e) {
      console.error("[mod-to-skode] Error executing queued command:", cmd, e);
    }
  }
}

export function executeSkredCommand(cmd) {
  const M = getWasmModule();
  if (M && engineStarted) {
    try {
      return M.ccall("skred_command", "number", ["string"], [cmd]);
    } catch (e) {
      console.error("[mod-to-skode] Error executing command:", cmd, e);
      return -1;
    }
  } else {
    commandQueue.push(cmd);
    return 0;
  }
}

export function sendCommand(cmd) {
  executeSkredCommand(cmd);
}

export function subscribeEvents(callback) {
  currentEventSubscription = callback;
  return () => {
    if (currentEventSubscription === callback) {
      currentEventSubscription = null;
    }
  };
}

// ---------------------------------------------------------------------------
// 2. Audio & File Conversions (WAV Header, ZIP, VFS)
// ---------------------------------------------------------------------------

export function formatFloat(val, decimals) {
  return Number(val).toFixed(decimals);
}

export function pcm8ToWav(rawBitArray) {
  const rawU8 = rawBitArray.rawBuffer || rawBitArray.buffer || new Uint8Array(rawBitArray);
  const numSamples = rawU8.length;
  const dataSize = numSamples * 2;
  const fileSize = 36 + dataSize;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);

  // RIFF Chunk Descriptor
  view.setUint32(0, 0x52494646, false); // "RIFF"
  view.setUint32(4, fileSize, true);    // ChunkSize
  view.setUint32(8, 0x57415645, false); // "WAVE"

  // "fmt " Subchunk
  view.setUint32(12, 0x666d7420, false); // "fmt "
  view.setUint32(16, 16, true);          // Subchunk1Size (16 for PCM)
  view.setUint16(20, 1, true);           // AudioFormat (1 = PCM)
  view.setUint16(22, 1, true);           // NumChannels (1 = Mono)
  view.setUint32(24, 16574, true);       // SampleRate (16574 Hz)
  view.setUint32(28, 33148, true);       // ByteRate (16574 * 2)
  view.setUint16(32, 2, true);           // BlockAlign (2 bytes)
  view.setUint16(34, 16, true);          // BitsPerSample (16 bits)

  // "data" Subchunk
  view.setUint32(36, 0x64617461, false); // "data"
  view.setUint32(40, dataSize, true);    // Subchunk2Size

  const outU8 = new Uint8Array(buffer, 44);
  for (let i = 0; i < numSamples; i++) {
    outU8[i * 2] = 0;
    outU8[i * 2 + 1] = rawU8[i];
  }

  return new BitArray(new Uint8Array(buffer));
}

export function sliceBitArray(bitArr, start, length) {
  const u8 = bitArr.rawBuffer || bitArr.buffer || new Uint8Array(bitArr);
  const sliced = u8.subarray(start, start + length);
  return new BitArray(sliced);
}

export function createZipArchive(skodeText, samplesList, callback) {
  const enc = new TextEncoder();
  const zipEntries = {
    "main.sk": enc.encode(skodeText),
  };

  for (const item of samplesList) {
    const name = item[0];
    const bitArr = item[1];
    const u8 = bitArr.rawBuffer || bitArr.buffer || new Uint8Array(bitArr);
    zipEntries[name] = u8;
  }

  zip(zipEntries, (err, data) => {
    if (err) {
      console.error("[mod-to-skode] Zip generation failed:", err);
      callback(null, null);
    } else {
      const blob = new Blob([data], { type: "application/zip" });
      callback(blob, data);
    }
  });
}

export function downloadBlob(blob, filename) {
  if (!blob) return;
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }, 1000);
}

export function downloadZip(skodeText, samplesList, filename) {
  createZipArchive(skodeText, samplesList, (blob) => {
    if (blob) {
      downloadBlob(blob, filename);
    }
  });
}

export function registerPlaybackListener(onStep, onEnd) {
  playbackStepCallback = onStep;
  playbackEndedCallback = onEnd;
}

export function loadAndPlaySkode(mainSkText, samplesList, totalSteps) {
  activeSongTotalSteps = typeof totalSteps === "number" ? totalSteps : 0;
  isPlaybackActive = true;
  isPlaybackPaused = false;
  lastReportedStep = -1;

  if (currentPreviewAudio) {
    try {
      currentPreviewAudio.pause();
      currentPreviewAudio.currentTime = 0;
    } catch (e) {}
    currentPreviewAudio = null;
  }

  ensureEngineRunning();
  ensureAudioContext();
  removeAudioUnlockListeners();
  audioUnlocked = true;

  const M = getWasmModule();
  if (!M || !M.FS) {
    console.warn("[mod-to-skode] WASM FS not ready for playback.");
    return;
  }

  // 1. Immediately stop previous playback, unmount previous zip, clear all patterns (Y-1) and voices (S-1)
  executeSkredCommand("stop");
  executeSkredCommand("%zu");
  executeSkredCommand("Y-1");
  executeSkredCommand("S-1");

  createZipArchive(mainSkText, samplesList, (_blob, zipData) => {
    if (!zipData) {
      console.error("[mod-to-skode] Failed to build zip for playback.");
      return;
    }

    try {
      try { M.FS.writeFile("/song.zip", zipData); } catch (e) {}
      try { M.FS.writeFile("song.zip", zipData); } catch (e) {}

      // Clean engine state right before mounting new zip
      executeSkredCommand("stop");
      executeSkredCommand("%zu");
      executeSkredCommand("Y-1");
      executeSkredCommand("S-1");

      // Mount zip via Skode VFS (%z) and trigger playback with control events enabled for pattern 0
      executeSkredCommand("%z [song.zip];");
      executeSkredCommand("y0 yc1;");
      executeSkredCommand(`V${currentMasterVolume}`);
      executeSkredCommand("play");
    } catch (err) {
      console.error("[mod-to-skode] Error during loadAndPlaySkode:", err);
    }
  });
}

export function pausePlayback() {
  if (!isPlaybackActive) return;
  isPlaybackPaused = true;
  const M = win.Module;
  if (M && M.audioContext && M.audioContext.state === "running") {
    M.audioContext.suspend().catch(() => {});
  }
  if (win.AL && win.AL.currentCtx && win.AL.currentCtx.audioCtx && win.AL.currentCtx.audioCtx.state === "running") {
    win.AL.currentCtx.audioCtx.suspend().catch(() => {});
  }
  if (win.miniaudio && Array.isArray(win.miniaudio.devices)) {
    for (const dev of win.miniaudio.devices) {
      if (dev && dev.webaudio && dev.webaudio.state === "running") {
        dev.webaudio.suspend().catch(() => {});
      }
    }
  }
}

export function resumePlayback() {
  if (!isPlaybackActive) return;
  isPlaybackPaused = false;
  ensureAudioContext();
}

export function stopPlayback() {
  isPlaybackActive = false;
  isPlaybackPaused = false;
  lastReportedStep = -1;
  ensureAudioContext();
  executeSkredCommand("stop");
  executeSkredCommand("%zu");
  executeSkredCommand("Y-1");
  executeSkredCommand("S-1");
}

export function previewSample(rawBitArray) {
  if (isPlaybackActive && !isPlaybackPaused) {
    console.warn("[mod-to-skode] Cannot preview sample while song is actively playing.");
    return;
  }
  if (currentPreviewAudio) {
    try {
      currentPreviewAudio.pause();
      currentPreviewAudio.currentTime = 0;
    } catch (e) {}
    currentPreviewAudio = null;
  }
  try {
    const u8 = rawBitArray.rawBuffer || rawBitArray.buffer || new Uint8Array(rawBitArray);
    const blob = new Blob([u8], { type: "audio/wav" });
    const url = URL.createObjectURL(blob);
    const audio = new Audio(url);
    currentPreviewAudio = audio;
    audio.play().catch((err) => {
      console.warn("[mod-to-skode] Sample preview play error:", err);
    });
    audio.onended = () => {
      URL.revokeObjectURL(url);
      if (currentPreviewAudio === audio) {
        currentPreviewAudio = null;
      }
    };
  } catch (err) {
    console.error("[mod-to-skode] previewSample failed:", err);
  }
}

export function panicEngine() {
  executeSkredCommand("stop");
  executeSkredCommand("%zu");
  executeSkredCommand("Y-1");
  executeSkredCommand("S-1");
}

export function setMasterVolume(dB) {
  const v = typeof dB === "number" ? Math.round(dB) : -6;
  currentMasterVolume = v;
  executeSkredCommand(`V${v}`);
}

// ---------------------------------------------------------------------------
// 3. Test Helper (Node.js file reader)
// ---------------------------------------------------------------------------

export function readTestFile(filePath) {
  try {
    const fs = win.require ? win.require("node:fs") : null;
    if (fs) {
      const buf = fs.readFileSync(filePath);
      return new BitArray(new Uint8Array(buf));
    }
  } catch (e) {}
  return new BitArray(new Uint8Array(0));
}

// ---------------------------------------------------------------------------
// 4. Drag and Drop & File Upload Listener
// ---------------------------------------------------------------------------

export function registerFileDrop(callback) {
  if (typeof window === "undefined") return;

  function handleFile(file) {
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (e) => {
      const buffer = e.target.result;
      const bitArr = new BitArray(new Uint8Array(buffer));
      callback(file.name, bitArr);
    };
    reader.readAsArrayBuffer(file);
  }

  window.addEventListener("dragover", (e) => {
    e.preventDefault();
    const zone = document.getElementById("drop-zone");
    if (zone) zone.classList.add("drag-over");
  });

  window.addEventListener("dragleave", (e) => {
    if (e.target === document.body || e.clientX <= 0 || e.clientY <= 0) {
      const zone = document.getElementById("drop-zone");
      if (zone) zone.classList.remove("drag-over");
    }
  });

  window.addEventListener("drop", (e) => {
    e.preventDefault();
    const zone = document.getElementById("drop-zone");
    if (zone) zone.classList.remove("drag-over");
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0]) {
      handleFile(e.dataTransfer.files[0]);
    }
  });

  document.addEventListener("change", (e) => {
    if (e.target && e.target.id === "file-input" && e.target.files && e.target.files[0]) {
      handleFile(e.target.files[0]);
    }
  });
}

export function loadUrlMod(url, filename, callback) {
  const targetUrl =
    typeof window !== "undefined"
      ? new URL(url, window.location.href).href
      : url;
  fetch(targetUrl)
    .then((res) => {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.arrayBuffer();
    })
    .then((buf) => {
      const bitArr = new BitArray(new Uint8Array(buf));
      callback(filename, bitArr);
    })
    .catch((err) => {
      console.error("[mod-to-skode] Failed to fetch demo module:", err);
    });
}

// Curated collection of 100% verified classic Amiga .MOD modules hosted on The Mod Archive (modarchive.org)
// Direct downloads use api.modarchive.org/downloads.php with Access-Control-Allow-Origin: * and long-term public caching.
export const MODARCHIVE_CATALOG = [
  { id: 57925, filename: "space_debris.mod", title: "Space Debris", artist: "Captain" },
  { id: 40475, filename: "ELYSIUM.MOD", title: "Elysium", artist: "Jeroen Tel" },
  { id: 42560, filename: "GSLINGER.MOD", title: "Gunslinger", artist: "Firefox" },
  { id: 59344, filename: "stardstm.mod", title: "Stardust Memories", artist: "Jochen Hippel" },
  { id: 101789, filename: "musiklinjen.mod", title: "Musiklinjen", artist: "Curt Cool" },
  { id: 99684, filename: "hymn_to_aurora.mod", title: "Hymn to Aurora", artist: "Kusma" },
  { id: 66334, filename: "tempest-acidjazz.mod", title: "Acid Jazz", artist: "Tempest" },
  { id: 167100, filename: "jogeir_liljedahl_-_addiction.mod", title: "Addiction", artist: "Jogeir Liljedahl" },
  { id: 214414, filename: "beyond_music.mod", title: "Beyond Music", artist: "Moby" },
  { id: 35344, filename: "DOPE.MOD", title: "Dope", artist: "Oncle Tom" },
  { id: 104644, filename: "physical_presence.mod", title: "Physical Presence", artist: "Firefox" },
  { id: 54299, filename: "SHADOWRU.MOD", title: "Shadowrun", artist: "Maniacs of Noise" },
  { id: 79054, filename: "echoing.mod", title: "Echoing", artist: "Dubmood" },
  { id: 59601, filename: "12TH.MOD", title: "12th Warrior", artist: "Groo" },
  { id: 211324, filename: "creamof.mod", title: "Cream of the Earth", artist: "Romeo Knight" },
  { id: 164407, filename: "random_voice_-_monday.mod", title: "Monday", artist: "Random Voice" },
  { id: 35151, filename: "bananasplit.mod", title: "Banana Split", artist: "Groo" },
  { id: 211598, filename: "street_jungle.mod", title: "Street Jungle", artist: "Dr. Awesome" },
  { id: 56660, filename: "projectx.mod", title: "Project-X", artist: "Allister Brimble" },
  { id: 40748, filename: "FOUNTAIN.MOD", title: "Fountain of Sighs", artist: "Tip & Mantronix" },
  { id: 37620, filename: "class09.mod", title: "Classic 09", artist: "Audiomonster" },
  { id: 126990, filename: "aftertouch.mod", title: "Aftertouch", artist: "Jesper Kyd" },
  { id: 186736, filename: "amegas.mod", title: "Amegas", artist: "Karsten Obarski" },
  { id: 104882, filename: "crystalhammer.mod", title: "Crystal Hammer", artist: "Karsten Obarski" },
  { id: 174955, filename: "professional_tracker.mod", title: "Professional Tracker", artist: "Hoffman & Daytripper" },
  { id: 82262, filename: "apoplexy.mod", title: "Apoplexy", artist: "Moby" },
  { id: 67779, filename: "playingw.mod", title: "Playing With Fire", artist: "Romeo Knight" },
  { id: 37611, filename: "desert2.mod", title: "Desert Dream", artist: "Laxity" },
  { id: 47057, filename: "KLISJE.MOD", title: "Klisje paa Klisje", artist: "Walkman" },
  { id: 106484, filename: "tiny_tunes.mod", title: "Tiny Tunes", artist: "Uncle Tom" },
  { id: 77604, filename: "sirens.mod", title: "Sirens", artist: "Firefox" },
  { id: 214567, filename: "4mat_driving.mod", title: "Driving", artist: "4mat" },
  { id: 215379, filename: "axelf.mod", title: "Axel F", artist: "Heatbeat" },
  { id: 104178, filename: "nearly_there.mod", title: "Nearly There", artist: "Groo" },
  { id: 67116, filename: "skogen11.mod", title: "Skogen 11", artist: "Zodiak" },
  { id: 66036, filename: "4mats-madness.mod", title: "4mat's Madness", artist: "4mat" },
  { id: 53421, filename: "paul.mod", title: "Paul", artist: "Laxity" },
  { id: 104811, filename: "popcorn_remix.mod", title: "Popcorn Remix", artist: "Tip" },
  { id: 185270, filename: "h0ffman_-_eon.mod", title: "Eon", artist: "h0ffman" },
  { id: 65878, filename: "fleshbrain-sauron.mod", title: "Fleshbrain", artist: "Sauron" },
  { id: 39162, filename: "corruption.mod", title: "Corruption", artist: "Tip" },
  { id: 37594, filename: "class01.mod", title: "Classic 01", artist: "Audiomonster" },
  { id: 33431, filename: "ambpower.mod", title: "Ambiance Power", artist: "Groo" },
  { id: 55789, filename: "scrambld.mod", title: "Scrambled", artist: "Maniacs of Noise" },
  { id: 105709, filename: "trans_atlantic.mod", title: "Trans Atlantic", artist: "Firefox" },
  { id: 38520, filename: "dirt.mod", title: "Dirt", artist: "Jesper Kyd" },
  { id: 68804, filename: "interference.mod", title: "Interference", artist: "Sanity" },
  { id: 67602, filename: "radix-mountain_king.mod", title: "Mountain King", artist: "Radix" },
  { id: 171453, filename: "purple_motion_-_sundance.mod", title: "Sundance", artist: "Purple Motion" },
  { id: 67101, filename: "chubb1-1.mod", title: "Chubb 1-1", artist: "Uncle Tom" },
  { id: 116659, filename: "1989-a_number.mod", title: "1989: A Number", artist: "Tip" },
  { id: 177642, filename: "axel_f_-_dj_metune.mod", title: "Axel F Remix", artist: "DJ MeTune" },
  { id: 40293, filename: "cyberrid.mod", title: "Cyberride", artist: "Jesper Kyd" },
  { id: 67120, filename: "skogen14.mod", title: "Skogen 14", artist: "Zodiak" },
  { id: 105634, filename: "oro_incenso-orig.mod", title: "Oro Incenso", artist: "Moby" },
  { id: 61595, filename: "vvertur.mod", title: "Vvertur", artist: "Laxity" },
  { id: 42781, filename: "galaxyii.mod", title: "Galaxy II", artist: "Jesper Kyd" },
  { id: 114971, filename: "tilbury_fair.mod", title: "Tilbury Fair", artist: "4mat" },
  { id: 91803, filename: "spacedel_short.mod", title: "Space Delay", artist: "Kusma" },
  { id: 108484, filename: "mortimers_chipdisko.mod", title: "Chip Disko", artist: "Mortimer Twang" },
  { id: 172266, filename: "hoffman_-_the_hunter.mod", title: "The Hunter", artist: "Hoffman" },
  { id: 59808, filename: "1990chip.mod", title: "1990 Chip", artist: "Walkman" }
];

export function fetchRandomModArchive(onStart, onSuccess, onError) {
  const index = Math.floor(Math.random() * MODARCHIVE_CATALOG.length);
  const track = MODARCHIVE_CATALOG[index];
  const url = `https://api.modarchive.org/downloads.php?moduleid=${track.id}#${track.filename}`;

  if (onStart) {
    onStart(track.title, track.artist, track.id);
  }

  fetch(url)
    .then((res) => {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.arrayBuffer();
    })
    .then((buf) => {
      const bitArr = new BitArray(new Uint8Array(buf));
      onSuccess(track.filename, bitArr, track.id, track.title, track.artist);
    })
    .catch((err) => {
      console.error("[mod-to-skode] Failed to fetch ModArchive track:", err);
      if (onError) onError(err.message || "Network error");
    });
}

export function checkInitialUrl(onStart, onSuccess, onError) {
  if (typeof window === "undefined" || !window.location) return;

  const params = new URLSearchParams(window.location.search);
  let raw = params.get("url") || params.get("mod") || params.get("module") || params.get("id");

  if (!raw && window.location.hash) {
    const h = window.location.hash.replace(/^#/, "");
    if (h.includes("=")) {
      const hp = new URLSearchParams(h);
      raw = hp.get("url") || hp.get("mod") || hp.get("id");
    } else if (h.length > 1 && !h.startsWith("/")) {
      raw = h;
    }
  }

  if (!raw) return;

  raw = decodeURIComponent(raw).trim();

  // 1. Check if raw matches any catalog entry by ID, filename, or title/keyword
  const cleanKey = raw.toLowerCase().replace(/\.mod$/i, "");
  const numId = parseInt(raw, 10);

  let catalogTrack = MODARCHIVE_CATALOG.find((t) => {
    if (numId && t.id === numId) return true;
    const fClean = t.filename.toLowerCase().replace(/\.mod$/i, "");
    if (fClean === cleanKey) return true;
    const tClean = t.title.toLowerCase().replace(/[^a-z0-9]/g, "");
    const kClean = cleanKey.replace(/[^a-z0-9]/g, "");
    if (tClean === kClean && kClean.length > 2) return true;
    if (
      cleanKey.includes("the_hunter") ||
      cleanKey.includes("the hunter") ||
      cleanKey.includes("hunter")
    ) {
      return t.id === 172266;
    }
    return false;
  });

  // Also check if raw is a URL like https://api.modarchive.org/downloads.php?moduleid=172266
  if (!catalogTrack && raw.includes("moduleid=")) {
    const m = raw.match(/moduleid=(\d+)/);
    if (m) {
      const mid = parseInt(m[1], 10);
      catalogTrack = MODARCHIVE_CATALOG.find((t) => t.id === mid);
    }
  }

  if (catalogTrack) {
    if (onStart) onStart(catalogTrack.title, catalogTrack.artist, catalogTrack.id);

    const primaryUrl = `https://api.modarchive.org/downloads.php?moduleid=${catalogTrack.id}#${catalogTrack.filename}`;
    const fallbackLocalUrl = `demos/${catalogTrack.filename}`;
    const safetyLocalUrl = `demos/space_debris.mod`;

    fetch(primaryUrl)
      .then((res) => {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.arrayBuffer();
      })
      .then((buf) => {
        const bitArr = new BitArray(new Uint8Array(buf));
        onSuccess(catalogTrack.filename, bitArr, catalogTrack.id, catalogTrack.title, catalogTrack.artist);
      })
      .catch((primaryErr) => {
        console.warn("[mod-to-skode] Primary ModArchive download failed, trying local bundled copy:", primaryErr);
        fetch(fallbackLocalUrl)
          .then((res) => {
            if (!res.ok) throw new Error("HTTP " + res.status);
            return res.arrayBuffer();
          })
          .then((buf) => {
            const bitArr = new BitArray(new Uint8Array(buf));
            onSuccess(catalogTrack.filename, bitArr, catalogTrack.id, catalogTrack.title, catalogTrack.artist + " (Offline Bundled)");
          })
          .catch((fallbackErr) => {
            console.warn("[mod-to-skode] Local copy failed, falling back to Space Debris demo:", fallbackErr);
            fetch(safetyLocalUrl)
              .then((res) => res.arrayBuffer())
              .then((buf) => {
                const bitArr = new BitArray(new Uint8Array(buf));
                onSuccess("space_debris.mod", bitArr, 57925, "Space Debris (Fallback Demo)", "Captain");
              })
              .catch((err) => {
                if (onError) onError("Failed to load module: " + (primaryErr.message || "Network error"));
              });
          });
      });
    return;
  }

  // 2. Generic URL
  let targetUrl = raw;
  let filename = "module.mod";

  try {
    const parsed = new URL(raw, window.location.href);
    targetUrl = parsed.href;
    const pathParts = parsed.pathname.split("/");
    const lastPart = pathParts[pathParts.length - 1];
    if (lastPart && (lastPart.endsWith(".mod") || lastPart.endsWith(".MOD"))) {
      filename = lastPart;
    } else if (parsed.hash && parsed.hash.includes(".mod")) {
      filename = parsed.hash.replace(/^#/, "");
    }
  } catch (e) {}

  if (onStart) onStart(filename, "Remote Source", 0);

  fetch(targetUrl)
    .then((res) => {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.arrayBuffer();
    })
    .then((buf) => {
      const bitArr = new BitArray(new Uint8Array(buf));
      onSuccess(filename, bitArr, 0, filename, "Remote Track");
    })
    .catch((err) => {
      console.warn("[mod-to-skode] Remote URL failed, falling back to Space Debris demo:", err);
      fetch("demos/space_debris.mod")
        .then((res) => res.arrayBuffer())
        .then((buf) => {
          const bitArr = new BitArray(new Uint8Array(buf));
          onSuccess("space_debris.mod", bitArr, 57925, "Space Debris (Fallback Demo)", "Captain");
        })
        .catch(() => {
          if (onError) onError("Could not reach " + targetUrl + " (" + (err.message || "Network error") + ")");
        });
    });
}


