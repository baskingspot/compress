// The browser demo's driver. The wasm module exposes fixed input/output
// regions and two calls: encode(codec, level, len) and decode(codec, len).
// Everything else here is UI and bookkeeping.

const CODECS = [
  { id: 0, name: "snappy", ext: "snappy", mime: "application/x-snappy", levels: null, max: 65536 },
  { id: 1, name: "flate", ext: "deflate", mime: "application/x-deflate", levels: [1, 6] },
  { id: 2, name: "gzip", ext: "gz", mime: "application/gzip", levels: [1, 6] },
  { id: 3, name: "zlib", ext: "zlib", mime: "application/zlib", levels: [1, 6] },
  { id: 4, name: "zstd", ext: "zst", mime: "application/zstd", levels: [1, 3] },
  { id: 5, name: "brotli", ext: "br", mime: "application/x-brotli", levels: null },
];

const SAMPLE =
  "The basking spot is the one feature a vivarium is arranged around. " +
  "It is where energy enters the system. Zig programs are cold-blooded; " +
  "this is where they warm up.\n\n" +
  "Compression is a trade: time for bytes. This page runs the same codecs " +
  "the library ships, compiled to WebAssembly, with the caller-owned buffers " +
  "living in the module's linear memory.\n";

const $ = (id) => document.getElementById(id);
const codecSelect = $("codec");
const levelSelect = $("level");
const levelWrap = $("level-wrap");
const source = $("source");
const result = $("result");
const resultLabel = $("result-label");
const stats = $("stats");
const status = $("status");
const encodeButton = $("encode");
const decodeButton = $("decode");
const downloadButton = $("download");
const sampleButton = $("sample");

let wasm;
let compressed = null;
let compressedCodec = null;
let encodedSource = null;

function view() {
  return new Uint8Array(wasm.memory.buffer);
}

function codecOf(id) {
  return CODECS.find((codec) => codec.id === id);
}

function fail(message) {
  status.textContent = message;
  status.className = "error";
}

function note(message) {
  status.textContent = message;
  status.className = "";
}

function formatBytes(n) {
  return n.toLocaleString("en-US");
}

function hexDump(bytes, limit = 512) {
  const shown = bytes.subarray(0, limit);
  const lines = [];
  for (let i = 0; i < shown.length; i += 16) {
    const chunk = shown.subarray(i, i + 16);
    const hex = Array.from(chunk, (b) => b.toString(16).padStart(2, "0")).join(" ");
    const ascii = Array.from(chunk, (b) => (b >= 32 && b < 127 ? String.fromCharCode(b) : ".")).join("");
    lines.push(`${i.toString(16).padStart(8, "0")}  ${hex.padEnd(47)}  |${ascii}|`);
  }
  if (bytes.length > limit) lines.push(`… ${bytes.length - limit} more bytes`);
  return lines.join("\n");
}

function textOf(bytes) {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

function encodeBytes(codec, level, bytes) {
  if (!wasm) throw new Error("the wasm module is still loading");
  if (bytes.length > wasm.inputCap()) {
    throw new Error(`input is ${formatBytes(bytes.length)} bytes; the module takes at most ${formatBytes(wasm.inputCap())}`);
  }
  if (codec.max && bytes.length > codec.max) {
    throw new Error(`${codec.name} takes at most ${formatBytes(codec.max)} bytes per block`);
  }
  const memory = view();
  memory.set(bytes, wasm.inputPtr());
  const n = wasm.encode(codec.id, level, bytes.length);
  if (n < 0) throw new Error(`${codec.name} refused the input (${n})`);
  return memory.slice(wasm.outputPtr(), wasm.outputPtr() + n);
}

function decodeBytes(codec, bytes) {
  if (bytes.length > wasm.inputCap()) {
    throw new Error(`compressed input exceeds the module's ${formatBytes(wasm.inputCap())}-byte input region`);
  }
  const memory = view();
  memory.set(bytes, wasm.inputPtr());
  const n = wasm.decode(codec.id, bytes.length);
  if (n < 0) throw new Error(`${codec.name} refused the stream (${n})`);
  return memory.slice(wasm.outputPtr(), wasm.outputPtr() + n);
}

function refreshLevels() {
  const codec = codecOf(Number(codecSelect.value));
  levelWrap.hidden = !codec.levels;
  levelSelect.replaceChildren(
    ...(codec.levels ?? []).map((level) => {
      const option = document.createElement("option");
      option.value = String(level);
      option.textContent = String(level);
      return option;
    }),
  );
}

function clearCompressed() {
  compressed = null;
  compressedCodec = null;
  encodedSource = null;
  decodeButton.disabled = true;
  downloadButton.disabled = true;
  stats.textContent = "";
}

function selectCodecChange() {
  refreshLevels();
  clearCompressed();
  note("");
}

function loadSample() {
  source.value = SAMPLE;
  clearCompressed();
  note("");
}

function doEncode() {
  try {
    const codec = codecOf(Number(codecSelect.value));
    const level = Number(levelSelect.value || 1);
    const bytes = new TextEncoder().encode(source.value);
    const started = performance.now();
    const out = encodeBytes(codec, level, bytes);
    const elapsed = performance.now() - started;
    compressed = out;
    compressedCodec = codec;
    encodedSource = bytes;
    decodeButton.disabled = false;
    downloadButton.disabled = false;
    const ratio = bytes.length === 0 ? 0 : (100 * out.length) / bytes.length;
    stats.textContent =
      `${formatBytes(bytes.length)} B → ${formatBytes(out.length)} B ` +
      `(${ratio.toFixed(1)}%) in ${elapsed.toFixed(1)} ms`;
    resultLabel.textContent = `${codec.name} output`;
    result.textContent = hexDump(out);
    note("");
  } catch (error) {
    fail(error.message);
  }
}

function doDecode() {
  if (!compressed || !compressedCodec) return;
  try {
    const started = performance.now();
    const out = decodeBytes(compressedCodec, compressed);
    const elapsed = performance.now() - started;
    const text = textOf(out);
    resultLabel.textContent = `${compressedCodec.name} decode`;
    result.textContent = text ?? hexDump(out);
    const identical =
      encodedSource !== null &&
      out.length === encodedSource.length &&
      out.every((byte, index) => byte === encodedSource[index]);
    note(identical ? "round trip: identical to the input." : "decoded; the bytes differ from the input.");
    stats.textContent = `${formatBytes(out.length)} B in ${elapsed.toFixed(1)} ms`;
  } catch (error) {
    fail(error.message);
  }
}

function doDownload() {
  if (!compressed || !compressedCodec) return;
  const blob = new Blob([compressed], { type: compressedCodec.mime });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `output.${compressedCodec.ext}`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function main() {
  codecSelect.replaceChildren(
    ...CODECS.map((codec) => {
      const option = document.createElement("option");
      option.value = String(codec.id);
      option.textContent = codec.name;
      return option;
    }),
  );
  codecSelect.addEventListener("change", selectCodecChange);
  source.addEventListener("input", clearCompressed);
  sampleButton.addEventListener("click", loadSample);
  encodeButton.addEventListener("click", doEncode);
  decodeButton.addEventListener("click", doDecode);
  downloadButton.addEventListener("click", doDownload);
  refreshLevels();

  try {
    const response = await fetch("compress.wasm");
    if (!response.ok) throw new Error(`compress.wasm: ${response.status}`);
    const bytes = await response.arrayBuffer();
    const instance = await WebAssembly.instantiate(bytes, {});
    wasm = instance.instance.exports;
    $("wasm-size").textContent = `${Math.round(bytes.byteLength / 1024)} KB`;
    encodeButton.disabled = false;
    note("Ready. Encode the text on the left.");
    encodeButton.disabled = false;
  } catch (error) {
    fail(`could not load the wasm module: ${error.message}`);
  }
}

main();
