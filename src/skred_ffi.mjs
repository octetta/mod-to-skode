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

export function initEngine(callback) {
  if (moduleReady) {
    if (callback) callback(true);
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

      executeSkredCommand("S-1");
      executeSkredCommand("V0");

      startWasmEventPump(win.Module);
      flushCommandQueue();

      if (callback) callback(true);
    } catch (err) {
      console.error("[mod-to-skode] Failed to start Skred engine:", err);
      if (callback) callback(moduleReady);
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

if (typeof win.addEventListener === "function") {
  const unlock = () => {
    ensureAudioContext();
    ensureEngineRunning();
  };
  win.addEventListener("pointerdown", unlock, { passive: true });
  win.addEventListener("touchstart", unlock, { passive: true });
  win.addEventListener("keydown", unlock, { passive: true });
  win.addEventListener("click", unlock, { passive: true });
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
      currentEventSubscription &&
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
            const t = view.getInt32(base, true);
            const seq = view.getInt32(base + 4, true);
            const v = view.getInt32(base + 8, true);
            const p = view.getInt32(base + 12, true);
            const s = view.getInt32(base + 16, true);
            const id = view.getInt32(base + 20, true);
            const vals = [];
            for (let j = 0; j < 8; j++) {
              vals.push(view.getFloat32(base + 24 + j * 4, true));
            }
            events.push({ t, seq, v, p, s, id, vals });
          }
          currentEventSubscription(events);
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
      callback(null);
    } else {
      const blob = new Blob([data], { type: "application/zip" });
      callback(blob);
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

export function loadAndPlaySkode(mainSkText, samplesList) {
  ensureEngineRunning();
  const M = getWasmModule();
  if (!M || !M.FS) {
    console.warn("[mod-to-skode] WASM FS not ready for playback.");
    return;
  }

  try {
    try { M.FS.mkdir("/samples"); } catch (e) {}
    try { M.FS.mkdir("samples"); } catch (e) {}

    // Mount all samples in Emscripten VFS
    for (const item of samplesList) {
      const path = item[0];
      const bitArr = item[1];
      const u8 = bitArr.rawBuffer || bitArr.buffer || new Uint8Array(bitArr);
      try { M.FS.writeFile("/" + path, u8); } catch (e) {}
      try { M.FS.writeFile(path, u8); } catch (e) {}
    }

    // Mount main.sk
    const enc = new TextEncoder();
    const skBytes = enc.encode(mainSkText);
    try { M.FS.writeFile("/main.sk", skBytes); } catch (e) {}
    try { M.FS.writeFile("main.sk", skBytes); } catch (e) {}

    // Reset voices, load script, trigger playback
    executeSkredCommand("S-1");
    executeSkredCommand("[main.sk] /ls");
    executeSkredCommand("play");
  } catch (err) {
    console.error("[mod-to-skode] Error during loadAndPlaySkode:", err);
  }
}

export function stopPlayback() {
  executeSkredCommand("stop");
  executeSkredCommand("S-1");
}

export function panicEngine() {
  executeSkredCommand("S-1");
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

