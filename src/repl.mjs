// Interactive Skred REPL Console for mod-to-skode
// Accessible via Ctrl+~ (or Ctrl+`) and UI button
import { executeSkredCommand, ensureEngineRunning, seekToStep } from "./skred_ffi.mjs";

let replContainer = null;
let replOutput = null;
let replInput = null;
let isOpen = false;

// History state with LocalStorage persistence
const HISTORY_KEY = "mod_skred_repl_history";
let history = [];
try {
  const saved = localStorage.getItem(HISTORY_KEY);
  if (saved) history = JSON.parse(saved);
} catch (e) {}

let historyIndex = -1;
let currentDraft = "";

export function isReplOpen() {
  return isOpen;
}

export function openRepl() {
  if (!replContainer) createReplDom();
  ensureEngineRunning();
  replContainer.classList.add("active");
  isOpen = true;
  if (replInput) {
    setTimeout(() => {
      replInput.focus();
    }, 50);
  }
}

export function closeRepl() {
  if (replContainer) {
    replContainer.classList.remove("active");
  }
  isOpen = false;
}

export function toggleRepl() {
  if (isOpen) {
    closeRepl();
  } else {
    openRepl();
  }
}

export function appendReplOutput(type, text) {
  if (!replOutput) {
    if (!replContainer) createReplDom();
  }
  if (!replOutput) return;

  const line = document.createElement("div");
  line.className = `repl-line repl-line-${type}`;
  line.textContent = text;
  replOutput.appendChild(line);
  replOutput.scrollTop = replOutput.scrollHeight;
}

function handleCommand(cmd) {
  cmd = cmd.trim();
  if (!cmd) return;

  // Echo command
  appendReplOutput("cmd", `skred> ${cmd}`);

  // Save to history
  if (history.length === 0 || history[history.length - 1] !== cmd) {
    history.push(cmd);
    if (history.length > 100) history.shift();
    try {
      localStorage.setItem(HISTORY_KEY, JSON.stringify(history));
    } catch (e) {}
  }
  historyIndex = -1;
  currentDraft = "";

  // Handle special REPL meta-commands
  const lower = cmd.toLowerCase();
  const seekMatch = cmd.match(/^(-?seek|goto)\s+(\d+)$/i);
  if (seekMatch) {
    const targetStep = parseInt(seekMatch[2], 10);
    seekToStep(targetStep);
    appendReplOutput("success", `✓ Seeked song to Step ${targetStep + 1} (step index ${targetStep})`);
    return;
  }

  if (lower === "-help" || lower === "-?") {
    appendReplOutput(
      "info",
      `=== SKRED v0.83.0 COMMAND REFERENCE ===
• Voices & Waves:
  v<0..255>       Select voice (e.g. 'v0')
  w<0..999>       Set waveform / sample:
                  w100..w131: MOD PCM Waves (loaded via %z zip)
                  w15: DWG Strings, w16: DWG Clarinet, w18: DWG EPiano
                  w300..w304: Ksynth Bandlimited SID Waves
                  w6: Live White Noise (Continuous Audio RNG)
  a<db>           Set voice amplitude in dB (e.g. 'a0', 'a-6')
  t<a,d,s,r>      Set ADSR envelope (e.g. 't0.001,0.01,1.0,0.05')
  p<pan>          Set stereo pan -1.0 (L) to 1.0 (R), 0.0 = center
  n<note>         Trigger MIDI note number (0..127, e.g. 'n60' = C4)
  f<hz>           Set frequency in Hz (e.g. 'f440')
  l<0|1>          Gate & Attack: l1 = Gate ON (Attack), l0 = Gate OFF (Release)
  c1,<duty>       CZ Phase-Distortion PWM (-0.98 to +0.98)
  s-1             Reset all voices to silence

• Realtime Biquad Filter:
  j<0..5>         Filter mode (0=off, 1=LP, 2=HP, 3=BP, 4=Notch, 5=All)
  k<hz>           Cutoff frequency (e.g. 'k1200')
  q<q>            Resonance Q factor (e.g. 'q2.5')

• Master & Transport:
  V <db>          Master volume (e.g. 'V -6')
  M <bpm> <divs>  Tempo (e.g. 'M 125 96')
  play / stop     Start / halt pattern playback
  Z2 / Z3         Pause / resume playback
  zg <step>       Jump active pattern step (e.g. 'zg 16')
  -seek <step>    Seek song across all tracks to step (e.g. '-seek 64')
  Y-1             Reset all pattern tracks
  %z [file.zip]   Mount zip archive containing song.sk and waves

• REPL Meta-Commands (prefixed with '-'):
  -help / -?      Show this cheat sheet
  -clear / -cls   Clear terminal screen
  -status         Show engine status
  -seek <step>    Seek song across all channels to step
  -panic          Emergency silence (S-1; Y-1; stop)`
    );
    return;
  }

  if (lower === "-clear" || lower === "-cls") {
    if (replOutput) replOutput.innerHTML = "";
    return;
  }

  if (lower === "-panic") {
    executeSkredCommand("stop; %zu; S-1; Y-1");
    appendReplOutput("warn", "Engine silenced (stop; %zu; S-1; Y-1).");
    return;
  }

  if (lower === "-status") {
    appendReplOutput(
      "info",
      `Engine active: ${ensureEngineRunning() ? "YES" : "NO"} | REPL history: ${history.length} commands`
    );
    return;
  }

  // Execute Skred command via WASM
  try {
    ensureEngineRunning();
    const prevStdoutCount = typeof window !== "undefined" && window.__skredStdout ? window.__skredStdout.length : 0;
    const ret = executeSkredCommand(cmd);

    // If Skred did not emit stdout, explain the command outcome clearly
    const newStdoutCount = typeof window !== "undefined" && window.__skredStdout ? window.__skredStdout.length : 0;
    if (newStdoutCount === prevStdoutCount) {
      const explanation = explainSkodeCommand(cmd, ret);
      appendReplOutput("success", explanation);
    }
  } catch (err) {
    appendReplOutput("error", `Error: ${err.message || err}`);
  }
}

function explainSkodeCommand(cmd, exitCode) {
  if (exitCode !== 0 && exitCode !== undefined && exitCode !== null) {
    return `✗ Skred returned error code: ${exitCode}`;
  }

  const parts = cmd.split(/[\s;]+/);
  const details = [];

  let currentVoice = null;
  let sawAction = false;

  for (const part of parts) {
    if (!part) continue;

    if (/^v\d+$/i.test(part)) {
      currentVoice = part.toLowerCase();
      sawAction = true;
    } else if (/^vt$/i.test(part)) {
      details.push("Voice Text Set (vt)");
      sawAction = true;
    } else if (/^l[01]$/i.test(part)) {
      details.push(part === "l1" ? "Gate ON (l1)" : "Gate OFF (l0)");
      sawAction = true;
    } else if (/^n(\d+)$/i.test(part)) {
      details.push(`Note: ${part.slice(1)}`);
      sawAction = true;
    } else if (/^f([0-9.]+)$/i.test(part)) {
      const hz = parseFloat(part.slice(1));
      details.push(`Freq: ${hz.toFixed(2)} Hz`);
      sawAction = true;
    } else if (/^w(\d+)$/i.test(part)) {
      const wId = parseInt(part.slice(1), 10);
      let desc = `w${wId}`;
      if (wId >= 100) {
        desc = `Sample Wave ${wId}`;
      } else {
        const wNames = {
          1: "Square",
          2: "Sawtooth",
          4: "Triangle",
          5: "Noise",
          6: "Live Noise",
          15: "DWG Strings (w15)",
          16: "DWG Clarinet (w16)",
          18: "DWG EPiano (w18)",
          300: "SID Triangle (w300)",
          301: "SID Sawtooth (w301)",
          302: "SID Pulse (w302)",
        };
        desc = wNames[wId] || `w${wId}`;
      }
      details.push(`Wave: ${desc}`);
      sawAction = true;
    } else if (/^a([+-]?\d+)$/i.test(part)) {
      details.push(`Amp: ${part.slice(1)} dB`);
      sawAction = true;
    } else if (/^c1,([+-]?[0-9.]+)$/i.test(part)) {
      details.push(`PWM: ${part.slice(3)}`);
      sawAction = true;
    } else if (/^t([0-9.,]+)$/i.test(part)) {
      details.push(`ADSR: ${part.slice(1)}`);
      sawAction = true;
    } else if (/^p([+-]?[0-9.]+)$/i.test(part)) {
      details.push(`Pan: ${part.slice(1)}`);
      sawAction = true;
    } else if (/^j([0-5])$/i.test(part)) {
      const mNames = ["Off", "Lowpass", "Highpass", "Bandpass", "Notch", "Allpass"];
      details.push(`Filter: ${mNames[parseInt(part.slice(1), 10)] || "Active"}`);
      sawAction = true;
    } else if (/^k([0-9.]+)$/i.test(part)) {
      details.push(`Cutoff: ${part.slice(1)} Hz`);
      sawAction = true;
    } else if (/^q([0-9.]+)$/i.test(part)) {
      details.push(`Resonance Q: ${part.slice(1)}`);
      sawAction = true;
    } else if (/^V\s*([+-]?\d+)$/i.test(part) || /^V([+-]?\d+)$/i.test(part)) {
      const db = part.replace(/^V\s*/i, "");
      details.push(`Master Volume: ${db} dB`);
      sawAction = true;
    } else if (part.toLowerCase() === "play") {
      return "✓ Playback: Started";
    } else if (part.toLowerCase() === "stop") {
      return "✓ Playback: Stopped";
    } else if (part.toLowerCase() === "z2") {
      return "✓ Playback: Paused (Z2)";
    } else if (part.toLowerCase() === "z3") {
      return "✓ Playback: Resumed (Z3)";
    } else if (/^zg\s*(\d+)$/i.test(part) || /^zg(\d+)$/i.test(part)) {
      const step = part.replace(/^zg\s*/i, "");
      details.push(`Jump Pattern Step: ${step} (zg)`);
      sawAction = true;
    } else if (part.toLowerCase() === "s-1") {
      return "✓ Silenced all voices (S-1)";
    } else if (part.toLowerCase() === "y-1") {
      return "✓ Reset all pattern tracks (Y-1)";
    }
  }

  if (currentVoice && details.length > 0) {
    return `✓ [${currentVoice}] ${details.join(" · ")}`;
  } else if (details.length > 0) {
    return `✓ ${details.join(" · ")}`;
  } else if (sawAction) {
    return `✓ Executed in Skred (exit: 0)`;
  }
  return `✓ Skred executed: ${cmd} (exit: ${exitCode ?? 0})`;
}

export function createReplDom() {
  if (typeof document === "undefined" || replContainer) return;

  const M = (typeof window !== "undefined" && window.Module) || (typeof globalThis !== "undefined" && globalThis.Module);
  let engineVer = "0.83.0";
  if (M && typeof M.ccall === "function") {
    try {
      const v = M.ccall("skred_version", "string", [], []);
      if (v) engineVer = v;
    } catch (e) {}
  }

  const drawer = document.createElement("div");
  drawer.id = "skred-repl-drawer";
  drawer.innerHTML = `
    <div class="repl-header">
      <div class="repl-title">
        <span class="repl-prompt-symbol">&gt;_</span>
        <span class="repl-title-text">SKRED v${engineVer} REPL</span>
        <span class="repl-key-badge">Ctrl+~ or Esc</span>
      </div>
      <div class="repl-actions">
        <button id="repl-clear-btn" class="repl-btn" title="Clear console">Clear</button>
        <button id="repl-close-btn" class="repl-btn repl-close-btn" title="Close REPL (Esc)">✕</button>
      </div>
    </div>
    <div id="skred-repl-output" class="repl-output"></div>
    <div class="repl-chips">
      <span class="repl-chip-label">Quick:</span>
      <button class="repl-chip" data-cmd="v0 w1 a0 f440 l1">Test Tone (A440)</button>
      <button class="repl-chip" data-cmd="v0 l0">Gate OFF</button>
      <button class="repl-chip" data-cmd="v0 w100 a0 f440 l1">Sample w100</button>
      <button class="repl-chip" data-cmd="V -6">V -6</button>
      <button class="repl-chip" data-cmd="play">play</button>
      <button class="repl-chip" data-cmd="stop">stop</button>
      <button class="repl-chip" data-cmd="-seek 0">seek 0</button>
      <button class="repl-chip" data-cmd="S-1">S-1</button>
      <button class="repl-chip" data-cmd="-status">-status</button>
      <button class="repl-chip" data-cmd="-panic">-panic</button>
      <button class="repl-chip" data-cmd="-help">-help</button>
    </div>
    <form id="skred-repl-form" class="repl-input-row" autocomplete="off">
      <span class="repl-prompt-prefix">skred&gt;</span>
      <input type="text" id="skred-repl-input" class="repl-input" placeholder="Type a Skred command (e.g. 'v0 w100 a0 n60 l1', 'V -6', '-help')..." spellcheck="false" autocomplete="off" autocapitalize="off" />
      <button type="submit" class="repl-run-btn">Run ↵</button>
    </form>
  `;

  document.body.appendChild(drawer);
  replContainer = drawer;
  replOutput = drawer.querySelector("#skred-repl-output");
  replInput = drawer.querySelector("#skred-repl-input");

  // Initial welcome message
  appendReplOutput(
    "system",
    `Skred v${engineVer} Audio Engine Console — Ready. Type '-help' for REPL guide. Press ↑ / ↓ for history.`
  );

  // Wire up close & clear buttons
  drawer.querySelector("#repl-close-btn").addEventListener("click", closeRepl);
  drawer.querySelector("#repl-clear-btn").addEventListener("click", () => {
    if (replOutput) replOutput.innerHTML = "";
  });

  // Wire up chip buttons
  drawer.querySelectorAll(".repl-chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      const cmd = chip.getAttribute("data-cmd");
      if (cmd && replInput) {
        replInput.value = cmd;
        replInput.focus();
      }
    });
  });

  // Form submit
  drawer.querySelector("#skred-repl-form").addEventListener("submit", (e) => {
    e.preventDefault();
    if (!replInput) return;
    const cmd = replInput.value;
    replInput.value = "";
    handleCommand(cmd);
  });

  // History navigation with ArrowUp and ArrowDown
  replInput.addEventListener("keydown", (e) => {
    if (e.key === "ArrowUp") {
      e.preventDefault();
      if (history.length === 0) return;
      if (historyIndex === -1) {
        currentDraft = replInput.value;
        historyIndex = history.length - 1;
      } else if (historyIndex > 0) {
        historyIndex--;
      }
      replInput.value = history[historyIndex];
      replInput.selectionStart = replInput.selectionEnd = replInput.value.length;
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      if (historyIndex === -1) return;
      if (historyIndex < history.length - 1) {
        historyIndex++;
        replInput.value = history[historyIndex];
      } else {
        historyIndex = -1;
        replInput.value = currentDraft;
      }
      replInput.selectionStart = replInput.selectionEnd = replInput.value.length;
    }
  });
}

// Global hotkey: Ctrl+~ or Ctrl+` or Backquote
if (typeof window !== "undefined") {
  window.addEventListener("keydown", (e) => {
    if (e.ctrlKey && (e.key === "~" || e.key === "`" || e.code === "Backquote")) {
      e.preventDefault();
      toggleRepl();
    } else if (e.key === "Escape" && isOpen) {
      e.preventDefault();
      closeRepl();
    }
  });
  window.toggleSkredRepl = toggleRepl;
  window.openSkredRepl = openRepl;
  window.closeSkredRepl = closeRepl;
  window.appendReplOutput = appendReplOutput;
  window.__onSkredPrint = (type, text) => {
    appendReplOutput(type, text);
  };
}
