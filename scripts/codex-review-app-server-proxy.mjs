#!/usr/bin/env node

import fs from "node:fs";
import net from "node:net";
import { spawn } from "node:child_process";

const argv = process.argv.slice(2);
let endpoint = "";
let readyFile = "";
let statusFile = "";
let codexPath = "";
const configs = [];

for (let index = 0; index < argv.length; index += 1) {
  const arg = argv[index];
  if (arg === "--endpoint" || arg === "--ready-file" || arg === "--status-file" || arg === "--codex" || arg === "--config") {
    const value = argv[index + 1];
    if (!value) {
      throw new Error(`${arg} requires a value`);
    }
    if (arg === "--endpoint") endpoint = value;
    if (arg === "--ready-file") readyFile = value;
    if (arg === "--status-file") statusFile = value;
    if (arg === "--codex") codexPath = value;
    if (arg === "--config") configs.push(value);
    index += 1;
    continue;
  }
  throw new Error(`unknown argument: ${arg}`);
}

if ((!endpoint.startsWith("unix:") && !endpoint.startsWith("pipe:")) || !readyFile || !codexPath) {
  throw new Error("usage: codex-review-app-server-proxy.mjs --endpoint unix:/path|pipe:<name> --ready-file PATH --codex PATH [--config key=value ...]");
}

const listenPath = endpoint.slice(endpoint.indexOf(":") + 1);
if (!listenPath) {
  throw new Error("endpoint path is empty");
}

const server = net.createServer();
let child = null;
let client = null;
let clientEnded = false;
let stopping = false;
let exitPromise = null;

function removePath(filePath) {
  try {
    fs.unlinkSync(filePath);
  } catch (error) {
    if (error?.code !== "ENOENT") {
      // Cleanup is best effort; the parent still verifies process termination.
    }
  }
}

function writeExitStatus(exitCode) {
  if (statusFile) {
    try {
      fs.writeFileSync(statusFile, `${exitCode}\n`);
    } catch {
      // The wrapper still observes the proxy's nonzero exit if status storage
      // itself is unavailable.
    }
  }
}

function waitForChildExit(timeoutMs) {
  if (!child || child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, timeoutMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

async function stop(exitCode = 0) {
  if (stopping) {
    return exitPromise;
  }
  stopping = true;
  exitPromise = (async () => {
    if (client) {
      client.destroy();
      client = null;
    }
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      await waitForChildExit(1000);
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
        await waitForChildExit(1000);
      }
    }
    await new Promise((resolve) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close(() => resolve());
    });
    removePath(listenPath);
    removePath(readyFile);
    writeExitStatus(exitCode);
    process.exitCode = exitCode;
  })();
  return exitPromise;
}

server.on("connection", (socket) => {
  if (client) {
    socket.destroy();
    return;
  }
  client = socket;
  socket.on("close", () => {
    if (client === socket) client = null;
  });
  socket.on("end", () => {
    clientEnded = true;
  });
  if (child?.stdout && child?.stdin) {
    socket.pipe(child.stdin);
    child.stdout.pipe(socket);
  }
});

server.on("error", () => {
  void stop(1);
});

child = spawn(codexPath, ["app-server", ...configs.flatMap((value) => ["-c", value]), "--stdio"], {
  stdio: ["pipe", "pipe", "pipe"],
  env: process.env
});
child.stderr.on("data", (chunk) => process.stderr.write(chunk));
child.on("error", () => {
  void stop(1);
});
child.on("exit", (code, signal) => {
  if (!stopping) {
    // A clean child exit is expected only after the client has ended its
    // request stream. An unexplained exit (including code zero) is a failed
    // review transport. Wrapper-requested stop() is handled separately.
    const cleanExit = clientEnded && !signal && code === 0;
    void stop(cleanExit ? 0 : 1);
  }
});

process.on("SIGTERM", () => {
  void stop(0);
});
process.on("SIGINT", () => {
  void stop(130);
});

server.listen(listenPath, () => {
  // Do not publish readiness in the same turn as listen(): a child that exits
  // immediately (for example, a failed Codex startup) must be observed before
  // the wrapper launches the official companion.
  const readyDelayMs = Number(process.env.CODEX_REVIEW_PROXY_READY_DELAY_MS ?? "25");
  setTimeout(() => {
    if (stopping || !child || child.exitCode !== null || child.signalCode !== null) {
      void stop(1);
      return;
    }
    fs.writeFileSync(readyFile, `${endpoint}\n`);
  }, Number.isFinite(readyDelayMs) && readyDelayMs >= 0 ? readyDelayMs : 25);
});
