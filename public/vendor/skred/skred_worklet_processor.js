// Standalone Single-Threaded Skred AudioWorkletProcessor
// Runs the pure DSP engine on the browser's real-time audio thread
// Completely isolated from UI rendering, GC pauses, and main-thread load
// Zero SharedArrayBuffer requirement — 100% compatible with itch.io iframes

// Polyfill TextDecoder and TextEncoder in AudioWorkletGlobalScope if not present
if (typeof TextDecoder === "undefined") {
  globalThis.TextDecoder = class TextDecoder {
    constructor(encoding = "utf-8") { this.encoding = encoding; }
    decode(uint8array) {
      if (!uint8array || uint8array.length === 0) return "";
      let s = "";
      let i = 0;
      while (i < uint8array.length) {
        let b = uint8array[i++];
        if (b < 128) {
          s += String.fromCharCode(b);
        } else if (b > 191 && b < 224) {
          s += String.fromCharCode(((b & 31) << 6) | (uint8array[i++] & 63));
        } else if (b > 223 && b < 240) {
          s += String.fromCharCode(((b & 15) << 12) | ((uint8array[i++] & 63) << 6) | (uint8array[i++] & 63));
        } else {
          let cp = (((b & 7) << 18) | ((uint8array[i++] & 63) << 12) | ((uint8array[i++] & 63) << 6) | (uint8array[i++] & 63)) - 0x10000;
          s += String.fromCharCode((cp >> 10) + 0xD800, (cp & 0x3FF) + 0xDC00);
        }
      }
      return s;
    }
  };
}

if (typeof TextEncoder === "undefined") {
  globalThis.TextEncoder = class TextEncoder {
    encode(string) {
      const utf8 = [];
      for (let i = 0; i < string.length; i++) {
        let charcode = string.charCodeAt(i);
        if (charcode < 0x80) utf8.push(charcode);
        else if (charcode < 0x800) {
          utf8.push(0xc0 | (charcode >> 6), 0x80 | (charcode & 0x3f));
        } else if (charcode < 0xd800 || charcode >= 0xe000) {
          utf8.push(0xe0 | (charcode >> 12), 0x80 | ((charcode >> 6) & 0x3f), 0x80 | (charcode & 0x3f));
        } else {
          i++;
          charcode = 0x10000 + (((charcode & 0x3ff) << 10) | (string.charCodeAt(i) & 0x3ff));
          utf8.push(0xf0 | (charcode >> 18), 0x80 | ((charcode >> 12) & 0x3f), 0x80 | ((charcode >> 6) & 0x3f), 0x80 | (charcode & 0x3f));
        }
      }
      return new Uint8Array(utf8);
    }
  };
}

import createModule from "./skred_worklet_engine.js";

const MAX_EVENTS_BATCH = 64;
const EVENT_SIZE = 72;

class SkredWorkletProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super(options);
    this.module = null;
    this.leftPtr = 0;
    this.rightPtr = 0;
    this.eventsBuffer = 0;
    this.ready = false;
    this.commandQueue = [];
    this.sampleRate = (options && options.processorOptions && options.processorOptions.sampleRate) || 48000;
    this.cmdBufferPtr = 0;
    this.cmdBufferSize = 4096;

    this.port.onmessage = (event) => {
      this.handleMessage(event.data);
    };

    const initialBinary = options && options.processorOptions && options.processorOptions.wasmBinary;
    this.init(initialBinary);
  }

  async init(wasmBinary) {
    try {
      const moduleConfig = {};
      if (wasmBinary) {
        moduleConfig.wasmBinary = wasmBinary;
      } else {
        moduleConfig.locateFile = (path) => {
          return new URL(path, import.meta.url).href;
        };
      }
      this.module = await createModule(moduleConfig);
      const startRes = this.module._skred_start_headless(128, Math.floor(this.sampleRate));
      this.leftPtr = this.module._malloc(128 * 4);
      this.rightPtr = this.module._malloc(128 * 4);
      this.cmdBufferPtr = this.module._malloc(this.cmdBufferSize);
      if (typeof this.module._skred_control_event_poll === "function") {
        this.eventsBuffer = this.module._malloc(MAX_EVENTS_BATCH * EVENT_SIZE);
      }
      this.ready = (startRes === 0);
      if (typeof this.module._skred_logger === "function") {
        try { this.module._skred_logger(1); } catch (e) {}
      }

      this.port.postMessage({
        type: "ready",
        version: this.getVersion(),
        sampleRate: this.sampleRate,
      });

      // Drain any commands queued before initialization completed
      while (this.commandQueue.length > 0) {
        const item = this.commandQueue.shift();
        if (typeof item === "string") {
          this.executeCommand(item);
        } else if (item && item.type === "script") {
          this.writeScript(item.script, item.cmd);
        } else if (item && item.type === "file") {
          this.writeFile(item.path, item.data, item.cmd);
        }
      }
    } catch (err) {
      console.error("[SkredWorklet] Initialization error:", err);
      this.port.postMessage({ type: "error", error: String(err) });
    }
  }

  getVersion() {
    if (!this.module || typeof this.module._skred_version !== "function") return "1.3.16";
    try {
      const ptr = this.module._skred_version();
      return ptr ? this.module.UTF8ToString(ptr) : "1.3.16";
    } catch (e) {
      return "1.3.16";
    }
  }

  handleMessage(data) {
    if (!data) return;
    if (data.type === "cmd") {
      if (this.ready) {
        this.executeCommand(data.text);
      } else {
        this.commandQueue.push(data.text);
      }
    } else if (data.type === "script") {
      if (this.ready) {
        this.writeScript(data.script, data.cmd);
      } else {
        this.commandQueue.push(data);
      }
    } else if (data.type === "file") {
      if (this.ready) {
        this.writeFile(data.path, data.data, data.cmd);
      } else {
        this.commandQueue.push(data);
      }
    } else if (data.type === "features") {
      const ptr = (this.module && typeof this.module._skred_features === "function") ? this.module._skred_features() : 0;
      const text = ptr ? this.module.UTF8ToString(ptr) : "";
      this.port.postMessage({ type: "features", text });
    } else if (data.type === "graph") {
      const ptr = (this.module && typeof this.module._skred_voice_graph === "function")
        ? this.module._skred_voice_graph(data.voice || 0, 1, data.depth || 0) : 0;
      const text = ptr ? this.module.UTF8ToString(ptr) : "";
      this.port.postMessage({ type: "graph", text });
    } else if (data.type === "init" && !this.ready) {
      this.init(data.wasmBinary);
    }
  }

  writeFile(filePath, data, followUpCmd) {
    if (!this.module) return;
    try {
      if (this.module.FS && filePath && data) {
        const cleanPath = filePath.startsWith("/") ? filePath : "/" + filePath;
        const relPath = filePath.replace(/^\/+/, "");
        try { this.module.FS.writeFile(cleanPath, data); } catch (e) {}
        try { this.module.FS.writeFile(relPath, data); } catch (e) {}
      }
      if (followUpCmd) {
        this.executeCommand(followUpCmd);
      }
    } catch (err) {
      console.error("[SkredWorklet] Error writing file to VFS:", err);
      this.port.postMessage({ type: "error", error: String(err) });
    }
  }

  writeScript(script, followUpCmd) {
    if (!this.module) return;
    try {
      if (this.module.FS) {
        try { this.module.FS.writeFile("/song.sk", script); } catch (e) {}
        try { this.module.FS.writeFile("song.sk", script); } catch (e) {}
      }
      if (followUpCmd) {
        this.executeCommand(followUpCmd);
      }
    } catch (err) {
      console.error("[SkredWorklet] Error writing script to VFS:", err);
      this.port.postMessage({ type: "error", error: String(err) });
    }
  }

  executeCommand(cmd) {
    if (!this.module || !cmd) return;
    try {
      this.module.stringToUTF8(cmd, this.cmdBufferPtr, this.cmdBufferSize);
      this.module._skred_command(this.cmdBufferPtr);
      if (typeof this.module._skred_log === "function" && typeof this.module.UTF8ToString === "function") {
        const logPtr = this.module._skred_log();
        if (logPtr) {
          const text = this.module.UTF8ToString(logPtr);
          if (text && text.trim().length > 0) {
            this.port.postMessage({ type: "log", text: text.trim() });
          }
        }
      }
    } catch (err) {
      console.error("[SkredWorklet] Command error:", err);
      this.port.postMessage({ type: "error", error: String(err) });
    }
  }

  process(inputs, outputs, parameters) {
    if (!this.ready || !this.module) {
      return true;
    }

    // Drain queued commands
    while (this.commandQueue.length > 0) {
      const item = this.commandQueue.shift();
      if (typeof item === "string") {
        this.executeCommand(item);
      } else if (item && item.type === "script") {
        this.writeScript(item.script, item.cmd);
      } else if (item && item.type === "file") {
        this.writeFile(item.path, item.data, item.cmd);
      }
    }

    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const outLeft = output[0];
    const outRight = output[1] || output[0];
    const frameCount = outLeft.length;

    if (frameCount === 128) {
      this.module._skred_process_stereo(this.leftPtr, this.rightPtr, 128);
      const heap = this.module.HEAPF32;
      const leftIdx = this.leftPtr >> 2;
      const rightIdx = this.rightPtr >> 2;
      for (let i = 0; i < 128; i++) {
        outLeft[i] = heap[leftIdx + i];
        outRight[i] = heap[rightIdx + i];
      }
    } else {
      let offset = 0;
      while (offset < frameCount) {
        const chunk = Math.min(128, frameCount - offset);
        this.module._skred_process_stereo(this.leftPtr, this.rightPtr, chunk);
        const heap = this.module.HEAPF32;
        const leftIdx = this.leftPtr >> 2;
        const rightIdx = this.rightPtr >> 2;
        for (let i = 0; i < chunk; i++) {
          outLeft[offset + i] = heap[leftIdx + i];
          outRight[offset + i] = heap[rightIdx + i];
        }
        offset += chunk;
      }
    }

    // Poll control / step events and dispatch to main thread
    if (this.eventsBuffer && typeof this.module._skred_control_event_poll === "function") {
      const count = this.module._skred_control_event_poll(this.eventsBuffer, MAX_EVENTS_BATCH);
      if (count > 0) {
        const events = [];
        if (!this.eventsDataView || this.eventsDataView.buffer !== this.module.HEAPU8.buffer) {
          this.eventsDataView = new DataView(this.module.HEAPU8.buffer, this.eventsBuffer, MAX_EVENTS_BATCH * EVENT_SIZE);
        }
        const view = this.eventsDataView;
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
        }
        this.port.postMessage({ type: "events", events });
      }
    }

    return true;
  }
}

registerProcessor("skred-worklet-processor", SkredWorkletProcessor);
