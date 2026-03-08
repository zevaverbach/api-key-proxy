#!/usr/bin/env node
//
// api-key-proxy: zero-dependency reverse proxy that injects API keys.
//
// Reads a JSON routes config (array), starts one HTTP listener per route.
// Keys come from env vars at startup and are immediately scrubbed from
// process.env so neither printenv nor /proc/self/environ (via child
// processes) can leak them.
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
// Snapshot keys then scrub from env
// ---------------------------------------------------------------------------

const keys = {};
for (const route of routes) {
  const val = process.env[route.keyEnv];
  if (!val) {
    console.error(`Missing env var: ${route.keyEnv}`);
    process.exit(1);
  }
  keys[route.keyEnv] = val;
  delete process.env[route.keyEnv];
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
    // Strip any incoming auth and replace with the real key
    delete headers.authorization;
    headers["authorization"] = "Bearer " + apiKey;

    const proxyReq = httpModule.request(target, {
      method: req.method,
      headers: headers,
    }, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
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
