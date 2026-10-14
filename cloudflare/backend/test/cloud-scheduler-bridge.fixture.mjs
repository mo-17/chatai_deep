// Actual installed SDK/native SQLite in a child runtime. Container network is Node loopback.
import { createRequire } from "node:module";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "../../..");
const repoRequire = createRequire(root + "/package.json");
const require = createRequire(repoRequire.resolve("wrangler/package.json"));
const { Miniflare } = require("miniflare"),
  { build } = require("esbuild");
const publicUrl = process.env.C3B_PUBLIC_URL,
  privateUrl = process.env.C3B_PRIVATE_URL;
for (const value of [publicUrl, privateUrl]) {
  const u = new URL(value);
  if (u.protocol !== "http:" || u.hostname !== "127.0.0.1")
    throw Error("only_synthetic_loopback");
}
const dir = await mkdtemp("/tmp/chatai-C3b-bridge-");
let mf;
const calls = [];
try {
  const bundle = await build({
    entryPoints: [
      resolve(import.meta.dirname, "cloud-scheduler-runtime.fixture.mjs"),
    ],
    bundle: true,
    write: false,
    format: "esm",
    platform: "neutral",
    external: ["cloudflare:workers"],
    logLevel: "silent",
    metafile: true,
  });
  if (process.env.C3B_BRIDGE_BUNDLE) {
    await writeFile(process.env.C3B_BRIDGE_BUNDLE, bundle.outputFiles[0].text);
    await writeFile(
      process.env.C3B_BRIDGE_BUNDLE + ".meta.json",
      JSON.stringify(bundle.metafile, null, 2),
    );
  }
  mf = new Miniflare({
    modules: true,
    script: bundle.outputFiles[0].text,
    compatibilityDate: "2026-07-11",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: {
      BACKEND: { className: "SyntheticBackend", useSQLite: true },
    },
    durableObjectsPersist: dir + "/do",
    defaultPersistRoot: dir + "/runtime",
    cachePersist: false,
    kvPersist: false,
    r2Persist: false,
    serviceBindings: {
      BRIDGE: async (req) => {
        const headers = new Headers(req.headers),
          port = headers.get("x-fixture-port");
        headers.delete("x-fixture-port");
        headers.delete("content-length");
        headers.delete("transfer-encoding");
        const from = new URL(req.url),
          target = new URL(port === "3101" ? privateUrl : publicUrl);
        target.pathname = from.pathname;
        target.search = from.search;
        calls.push({ port, path: from.pathname });
        let response;
        try {
          response = await fetch(target, {
            method: req.method,
            headers,
            body: req.method === "POST" ? await req.arrayBuffer() : undefined,
            redirect: "error",
            signal: AbortSignal.timeout(8000),
          });
        } catch (e) {
          calls[calls.length - 1].failure = {
            name: e.name,
            code: e.cause?.code ?? null,
          };
          throw e;
        }
        calls[calls.length - 1].status = response.status;
        return response;
      },
    },
  });
  process.send?.({ code: "SDK_BRIDGE_READY" });
  process.on("message", async (m) => {
    if (m?.op === "close") {
      await mf.dispose();
      await rm(dir, { recursive: true, force: true });
      process.send?.({ code: "SDK_BRIDGE_CLOSED", calls, cleanupAbsent: true });
      process.disconnect();
      return;
    }
    try {
      const r = await mf.dispatchFetch("http://public.invalid" + m.path, {
        method: m.body === undefined ? "GET" : "POST",
        headers: m.headers ?? { "Content-Type": "application/json" },
        body: m.body === undefined ? undefined : JSON.stringify(m.body),
      });
      process.send?.({ id: m.id, status: r.status, body: await r.json() });
    } catch {
      process.send?.({
        id: m.id,
        status: 503,
        body: { code: "synthetic_bridge_failure" },
      });
    }
  });
} catch {
  await mf?.dispose();
  await rm(dir, { recursive: true, force: true });
  process.exitCode = 1;
  process.disconnect?.();
}
