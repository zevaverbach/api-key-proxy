#!/usr/bin/env node
//
// api-key-proxy: zero-dependency reverse proxy that injects API keys.
//
// Reads a JSON routes config (array), starts one HTTP listener per route.
// Keys come from env vars at startup and are immediately scrubbed from
// process.env so neither printenv nor /proc/self/environ (via child
// processes) can leak them.
//
// Logs per-request usage and cost to ~/.api-proxy-logs/usage-YYYY-MM-DD.jsonl.
//
// Usage:
//   MOONSHOT_API_KEY=sk-... OPENAI_API_KEY=sk-... \
//     node proxy.js routes.json

"use strict";

const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const configPath = process.argv[2];
if (!configPath) {
  console.error("Usage: node proxy.js <routes.json>");
  process.exit(1);
}

const routes = JSON.parse(fs.readFileSync(path.resolve(configPath), "utf8"));

// ---------------------------------------------------------------------------
// Pricing (USD per token)
// ---------------------------------------------------------------------------

const PRICING = {
  moonshot: {
    input:  0.60 / 1e6,
    output: 3.00 / 1e6,
  },
  openai: {
    input:  2.50 / 1e6,
    output: 10.00 / 1e6,
  },
};

// ---------------------------------------------------------------------------
// Usage logging
// ---------------------------------------------------------------------------

const LOG_DIR = path.join(process.env.HOME || "/tmp", ".api-proxy-logs");
fs.mkdirSync(LOG_DIR, { recursive: true });

function logUsage(routeName, model, usage, cost) {
  const date = new Date().toISOString().split("T")[0];
  const file = path.join(LOG_DIR, `usage-${date}.jsonl`);
  const entry = JSON.stringify({
    t: Date.now(),
    route: routeName,
    model: model,
    input: usage.prompt_tokens || 0,
    output: usage.completion_tokens || 0,
    total: usage.total_tokens || 0,
    cost: +cost.toFixed(6),
  });
  fs.appendFile(file, entry + "\n", () => {});
  console.log(
    `[${routeName}] ${model || "?"}: $${cost.toFixed(4)} ` +
    `(in:${usage.prompt_tokens || 0} out:${usage.completion_tokens || 0})`
  );
}

function calculateCost(routeName, usage) {
  const p = PRICING[routeName] || PRICING.moonshot;
  const inp = usage.prompt_tokens || 0;
  const out = usage.completion_tokens || 0;
  return inp * (p.input || 0) + out * (p.output || 0);
}

// Extract usage from buffered response data (handles JSON and SSE)
function extractUsage(data) {
  const text = data.toString("utf8");

  // Try plain JSON response first
  try {
    const parsed = JSON.parse(text);
    if (parsed.usage) return { usage: parsed.usage, model: parsed.model };
  } catch (_) {}

  // SSE: scan for the last chunk with usage (typically the final data: line)
  let lastUsage = null;
  let model = null;
  const lines = text.split("\n");
  for (const line of lines) {
    if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
    try {
      const chunk = JSON.parse(line.slice(6));
      if (chunk.model) model = chunk.model;
      if (chunk.usage) lastUsage = chunk.usage;
    } catch (_) {}
  }
  if (lastUsage) return { usage: lastUsage, model };
  return null;
}

// ---------------------------------------------------------------------------
// Snapshot keys then scrub ALL env vars
// ---------------------------------------------------------------------------

const keys = {};
for (const route of routes) {
  const val = process.env[route.keyEnv];
  if (!val) {
    console.error(`Missing env var: ${route.keyEnv}`);
    process.exit(1);
  }
  keys[route.keyEnv] = val;
}

const keepEnv = new Set(["HOME", "PATH", "NODE_PATH", "TMPDIR", "TZ", "LANG", "USER"]);
for (const key of Object.keys(process.env)) {
  if (!keepEnv.has(key)) {
    delete process.env[key];
  }
}

// ---------------------------------------------------------------------------
// Start one listener per route
// ---------------------------------------------------------------------------

for (const route of routes) {
  const { port, upstream, keyEnv, name } = route;
  const label = name || upstream;
  const apiKey = keys[keyEnv];
  const upstreamUrl = new URL(upstream);
  const isHttps = upstreamUrl.protocol === "https:";
  const httpModule = isHttps ? https : http;

  const server = http.createServer((req, res) => {
    const target = new URL(req.url, upstream);

    const headers = Object.assign({}, req.headers);
    delete headers.host;
    delete headers.authorization;
    headers["authorization"] = "Bearer " + apiKey;

    const proxyReq = httpModule.request(target, {
      method: req.method,
      headers: headers,
    }, (proxyRes) => {
      // Stream response to client while also accumulating for usage extraction
      res.writeHead(proxyRes.statusCode, proxyRes.headers);

      const chunks = [];
      proxyRes.on("data", (chunk) => {
        res.write(chunk);
        chunks.push(chunk);
      });

      proxyRes.on("end", () => {
        res.end();
        // Extract usage asynchronously (don't block the response)
        try {
          const result = extractUsage(Buffer.concat(chunks));
          if (result) {
            const cost = calculateCost(label, result.usage);
            logUsage(label, result.model || "", result.usage, cost);
          }
        } catch (_) {}
      });
    });

    proxyReq.on("error", (err) => {
      console.error(`[${label}] proxy error: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502);
        res.end("Bad Gateway");
      }
    });

    req.pipe(proxyReq);
  });

  server.listen(port, "127.0.0.1", () => {
    console.log(`[${label}] 127.0.0.1:${port} -> ${upstream}`);
  });
}
