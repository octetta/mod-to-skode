// JavaScript FFI Bridge for QuickJS CLI
// Native binary file I/O, zip packaging, arguments, and stdio

import * as std from "std";
import * as os from "os";
import { zipSync, strToU8 } from "#vendor/fflate.mjs";
import { BitArray, toList, Ok, Error } from "./gleam.mjs";

export function getArgs() {
  if (typeof scriptArgs !== "undefined" && Array.isArray(scriptArgs)) {
    return toList(scriptArgs.slice(1));
  }
  return toList([]);
}

export function readFileBinary(path) {
  try {
    const f = std.open(path, "rb");
    if (!f) {
      return new Error("Could not open file: " + path);
    }
    f.seek(0, std.SEEK_END);
    const size = f.tell();
    f.seek(0, std.SEEK_SET);
    const buf = new ArrayBuffer(size);
    const readBytes = f.read(buf, 0, size);
    f.close();
    if (readBytes !== size) {
      return new Error(
        "Failed to read complete file (" + readBytes + "/" + size + " bytes): " + path
      );
    }
    return new Ok(new BitArray(new Uint8Array(buf)));
  } catch (err) {
    return new Error(String(err));
  }
}

export function writeTextFile(path, content) {
  try {
    const f = std.open(path, "w");
    if (!f) {
      return new Error("Could not open file for writing: " + path);
    }
    f.puts(content);
    f.close();
    return new Ok(undefined);
  } catch (err) {
    return new Error(String(err));
  }
}

export function writeBinaryFile(path, bitArray) {
  try {
    const f = std.open(path, "wb");
    if (!f) {
      return new Error("Could not open file for binary writing: " + path);
    }
    const u8 = bitArray.rawBuffer || bitArray.buffer || new Uint8Array(bitArray);
    const ab = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength);
    f.write(ab, 0, ab.byteLength);
    f.close();
    return new Ok(undefined);
  } catch (err) {
    return new Error(String(err));
  }
}

export function createZipArchive(mainSkText, samplesList) {
  try {
    const zipEntries = {
      "main.sk": strToU8(mainSkText),
    };
    for (const item of samplesList) {
      const name = item[0];
      const bitArr = item[1];
      const u8 = bitArr.rawBuffer || bitArr.buffer || new Uint8Array(bitArr);
      zipEntries[name] = u8;
    }
    const zipData = zipSync(zipEntries);
    return new Ok(new BitArray(zipData));
  } catch (err) {
    return new Error(String(err));
  }
}

export function makeDir(path) {
  try {
    os.mkdir(path, 0o755);
    return new Ok(undefined);
  } catch (_err) {
    return new Ok(undefined);
  }
}

export function printStdout(text) {
  std.out.puts(text);
  std.out.flush();
}

export function printStderr(text) {
  std.err.puts(text);
  std.err.flush();
}

export function exitProcess(code) {
  std.exit(code);
}
