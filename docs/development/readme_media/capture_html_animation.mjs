import { mkdir, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const [htmlPath, outDir, durationArg = "7200", fpsArg = "10", widthArg = "1280", heightArg = "720"] = process.argv.slice(2);

if (!htmlPath || !outDir) {
  console.error("usage: node capture_html_animation.mjs <html-path> <out-dir> [duration-ms] [fps] [width] [height]");
  process.exit(2);
}

const durationMs = Number(durationArg);
const fps = Number(fpsArg);
const width = Number(widthArg);
const height = Number(heightArg);
const frameCount = Math.ceil((durationMs / 1000) * fps);
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const port = 9333 + Math.floor(Math.random() * 1000);
const profile = `/tmp/keyscribe-chrome-${Date.now()}`;
const url = `file://${htmlPath}`;

await mkdir(outDir, { recursive: true });

const proc = spawn(chrome, [
  "--headless=new",
  "--disable-gpu",
  "--no-first-run",
  "--no-default-browser-check",
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`,
  `--window-size=${width},${height}`,
  "about:blank"
], { stdio: ["ignore", "ignore", "pipe"] });

let stderr = "";
proc.stderr.on("data", (chunk) => { stderr += chunk.toString(); });

async function getJson(path) {
  const response = await fetch(`http://127.0.0.1:${port}${path}`);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

for (let attempt = 0; attempt < 80; attempt += 1) {
  try {
    await getJson("/json/version");
    break;
  } catch {
    if (attempt === 79) throw new Error(`Chrome did not start\n${stderr}`);
    await sleep(100);
  }
}

const tabs = await getJson("/json/list");
const tab = tabs.find((item) => item.type === "page");
if (!tab?.webSocketDebuggerUrl) throw new Error("No debuggable page found");

const socket = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let nextId = 1;
const pending = new Map();
const events = new EventTarget();

socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  } else if (message.method) {
    events.dispatchEvent(new CustomEvent(message.method, { detail: message.params }));
  }
});

function send(method, params = {}) {
  const id = nextId;
  nextId += 1;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

function once(name) {
  return new Promise((resolve) => events.addEventListener(name, resolve, { once: true }));
}

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", {
  width,
  height,
  deviceScaleFactor: 1,
  mobile: false
});
const loaded = once("Page.loadEventFired");
await send("Page.navigate", { url });
await loaded;
await sleep(80);

const start = Date.now();
for (let frame = 0; frame < frameCount; frame += 1) {
  const target = start + Math.round((frame * 1000) / fps);
  const wait = target - Date.now();
  if (wait > 0) await sleep(wait);
  const result = await send("Page.captureScreenshot", { format: "png", fromSurface: true });
  const filename = `${outDir}/frame-${String(frame + 1).padStart(4, "0")}.png`;
  await writeFile(filename, Buffer.from(result.data, "base64"));
}

socket.close();
proc.kill("SIGTERM");
console.log(`captured ${frameCount} frames`);
