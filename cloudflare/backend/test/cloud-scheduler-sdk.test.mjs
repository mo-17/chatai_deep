import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdtemp, rm, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve(import.meta.dirname, "../../..");
const repoRequire = createRequire(root + "/package.json");
const wranglerRequire = createRequire(
  repoRequire.resolve("wrangler/package.json"),
);
const { Miniflare } = wranglerRequire("miniflare"),
  { build } = wranglerRequire("esbuild");
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
if (process.env.C3B_SDK_BUNDLE) {
  await writeFile(process.env.C3B_SDK_BUNDLE, bundle.outputFiles[0].text);
  await writeFile(
    process.env.C3B_SDK_BUNDLE + ".meta.json",
    JSON.stringify(bundle.metafile, null, 2),
  );
}
const evidence = [];
async function harness(fn, disabled = false) {
  const dir = await mkdtemp("/tmp/chatai-C3b-sdk-");
  let mf;
  let openPending,
    openAck,
    openHeld = false;
  const calls = [];
  let gate = { epoch: "0", accepting: false, work: "busy" },
    faults = {};
  const config = {
    modules: true,
    script: bundle.outputFiles[0].text,
    compatibilityDate: "2026-07-11",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: {
      BACKEND: {
        className: disabled ? "DisabledSyntheticBackend" : "SyntheticBackend",
        useSQLite: true,
      },
    },
    durableObjectsPersist: dir + "/do",
    defaultPersistRoot: dir + "/runtime",
    cachePersist: false,
    kvPersist: false,
    r2Persist: false,
    serviceBindings: {
      BRIDGE: async (req) => {
        const body = req.method === "POST" ? await req.text() : null;
        const headers = Object.fromEntries(req.headers.entries());
        const path = new URL(req.url).pathname;
        calls.push({ path, port: headers["x-fixture-port"], headers, body });
        if (headers["x-fixture-port"] === "3000")
          return Response.json(
            { public: true, headers, path },
            { status: 404 },
          );
        if (path === "/_cloud/control") {
          const { op, epoch } = JSON.parse(body);
          if (faults[op]) {
            if (faults[op] === "once") delete faults[op];
            return new Response("synthetic_transport_failure", { status: 503 });
          }
          if (op === "open") {
            gate = { ...gate, epoch, accepting: true };
            if (openHeld) {
              openHeld = false;
              openAck = { ...gate };
              return await new Promise((r) => (openPending = r));
            }
          }
          if (op === "close" && gate.work === "idle") {
            gate = { epoch, accepting: false, work: "idle" };
            if (faults.closeAck) {
              delete faults.closeAck;
              return new Response("ack_unknown", { status: 503 });
            }
          }
          return Response.json(gate);
        }
        return Response.json({
          admitted: true,
          epoch: headers["x-chatai-cloud-epoch"],
        });
      },
    },
  };
  const start = () => {
    mf = new Miniflare(config);
  };
  start();
  const request = (path, body, headers = {}) =>
    mf.dispatchFetch("http://public.invalid" + path, {
      method: body === undefined ? "GET" : "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const inspect = async () => {
    const r = await request("/__fixture/inspect");
    assert.equal(r.status, 200);
    return r.json();
  };
  const arm = () =>
    request("/uapi/cloud-workflows", { fixture: "not real task" });
  try {
    await fn({
      request,
      inspect,
      arm,
      calls,
      gate: () => gate,
      setWork: (v) => (gate.work = v),
      faults,
      holdOpen: () => (openHeld = true),
      openWaiting: () => !!openPending,
      releaseOpen: () => openPending(Response.json(openAck)),
      rebuild: async () => {
        await mf.dispose();
        start();
      },
    });
  } finally {
    await mf?.dispose();
    await rm(dir, { recursive: true, force: true });
    evidence.push({ calls, dir, cleanupAbsent: true });
  }
}
test("installed SDK schedules native SQLite; actual alarm deletes consumed row and keeps a distinct early successor", async () =>
  harness(async (h) => {
    assert.equal((await h.arm()).status, 200);
    const first = await h.inspect();
    assert.equal(first.rows.length, 1);
    const response = await h.request("/__fixture/fire", {});
    assert.equal(response.status, 200);
    const after = await response.json();
    assert.notEqual(after.state.wake.id, after.oldIntent);
    assert.equal(after.rows.length, 1);
    assert.notEqual(after.rows[0].id, first.rows[0].id);
    assert.equal(
      JSON.parse(after.rows[0].payload).intentId,
      after.state.wake.id,
    );
    // Re-delivery of the deleted, same-generation callback reuses the successor.
    for (let n = 0; n < 2; n++) {
      assert.equal(
        (
          await h.request("/__fixture/callback", {
            epoch: after.state.epoch,
            intentId: after.oldIntent,
          })
        ).status,
        200,
      );
      assert.deepEqual((await h.inspect()).rows, after.rows);
    }
    assert.ok(h.calls.some((c) => JSON.parse(c.body ?? "{}").op === "kick"));
  }));
test("schedule failure before INSERT blocks admission; repeated ARMING epochs reclaim real SDK rows", async () =>
  harness(async (h) => {
    for (let n = 0; n < 8; n++) {
      await h.request("/__fixture/fault", { schedule: "before" });
      assert.equal((await h.arm()).status, 503);
      assert.ok((await h.inspect()).rows.length <= 2);
    }
    // Failed PG open/status leaves an actual SDK row, not just an empty fake map.
    h.faults.open = h.faults.status = "always";
    for (let n = 0; n < 8; n++) {
      assert.equal((await h.arm()).status, 503);
      assert.equal((await h.inspect()).rows.length, 1);
    }
    delete h.faults.open;
    delete h.faults.status;
    assert.equal(h.calls.filter((c) => c.path === "/_cloud/admit").length, 0);
    assert.equal((await h.arm()).status, 200);
    assert.equal((await h.inspect()).rows.length, 1);
  }));
test("INSERT succeeded but SDK ACK unknown is queried back and alarm persistence confirmed", async () =>
  harness(async (h) => {
    await h.request("/__fixture/fault", { schedule: "after" });
    assert.equal((await h.arm()).status, 200);
    assert.equal((await h.inspect()).rows.length, 1);
    assert.equal(h.calls.filter((c) => c.path === "/_cloud/admit").length, 1);
  }));
test("whole alarm rejects persistence failure, business callback error is swallowed by real SDK but successor survives", async () =>
  harness(async (h) => {
    await h.arm();
    h.faults.kick = "once";
    assert.equal((await h.request("/__fixture/fire", {})).status, 200);
    assert.equal((await h.inspect()).rows.length, 1);
    await h.request("/__fixture/fault", {
      alarm: "always",
      schedule: "always",
    });
    assert.equal((await h.request("/__fixture/fire", {})).status, 503);
    assert.equal(h.calls.filter((c) => c.path === "/_cloud/admit").length, 1);
    await h.request("/__fixture/fault", {});
    assert.equal((await h.request("/__fixture/alarm", {})).status, 200);
    assert.equal((await h.inspect()).rows.length, 1);
  }));
test("close ACK loss retains successor, later positive close stops finitely", async () =>
  harness(async (h) => {
    await h.arm();
    h.setWork("idle");
    h.faults.closeAck = true;
    assert.equal((await h.request("/__fixture/fire", {})).status, 200);
    assert.equal((await h.inspect()).state.phase, "armed");
    assert.equal((await h.inspect()).rows.length, 1);
    assert.equal((await h.request("/__fixture/fire", {})).status, 200);
    const s = await h.inspect();
    assert.equal(s.state.phase, "idle");
    assert.equal(s.rows.length, 0);
  }));
test("stopped/start-failed container transport keeps durable responsibility; rebuild uses native persistent SQLite", async () =>
  harness(async (h) => {
    h.faults.open = "once";
    h.faults.status = "once";
    assert.equal((await h.arm()).status, 503);
    const before = await h.inspect();
    assert.equal(before.state.phase, "arming");
    assert.equal(before.rows.length, 1);
    await h.rebuild();
    assert.deepEqual(await h.inspect(), before);
    assert.equal((await h.arm()).status, 200);
    assert.equal((await h.inspect()).rows.length, 1);
  }));
test("old and duplicate callback cannot erase new epoch rows; exact reclamation stays <=2", async () =>
  harness(async (h) => {
    h.faults.open = "once";
    h.faults.status = "once";
    await h.arm();
    const old = (await h.inspect()).state;
    await h.arm();
    const current = await h.inspect();
    assert.notEqual(current.state.epoch, old.epoch);
    for (let n = 0; n < 4; n++) {
      assert.equal(
        (
          await h.request("/__fixture/callback", {
            epoch: old.epoch,
            intentId: old.wake.id,
          })
        ).status,
        200,
      );
      assert.deepEqual((await h.inspect()).rows, current.rows);
    }
  }));
test("public Worker and DO force port3000 and strip all client control/port/proxy authority", async () =>
  harness(async (h) => {
    const paths = [
      "/_cloud/control",
      "/%5fcloud/control",
      "//_cloud/control",
      "/uapi/../_cloud/control",
      "/uapi/cloud-workflows/unknown?rewrite=/_cloud/control",
    ];
    for (const path of paths) {
      const r = await h.request(
        path,
        { op: "open", epoch: "999" },
        {
          "cf-container-target-port": "3101",
          "x-chatai-cloud-epoch": "999",
          "x-cloud-workflow-operation": "open",
          "x-original-url": "/_cloud/control",
          "x-rewrite-url": "/_cloud/control",
          "x-forwarded-port": "3101",
          Authorization: "Bearer synthetic-user",
        },
      );
      assert.equal(r.status, 404);
    }
    assert.ok(h.calls.every((c) => c.port === "3000"));
    assert.ok(
      h.calls.every(
        (c) =>
          !("cf-container-target-port" in c.headers) &&
          !("x-chatai-cloud-epoch" in c.headers) &&
          !("x-rewrite-url" in c.headers),
      ),
    );
    assert.equal((await h.inspect()).state, null);
  }));
test("late open ACK cannot supersede new epoch; real SQL rows remain bounded after interleaving", async () =>
  harness(async (h) => {
    h.holdOpen();
    const old = h.arm();
    const end = Date.now() + 1000;
    while (!h.openWaiting()) {
      if (Date.now() > end) throw Error("hold_not_reached");
      await new Promise((r) => setTimeout(r, 1));
    }
    assert.equal((await h.arm()).status, 200);
    const newer = await h.inspect();
    assert.equal(newer.state.epoch, "2");
    assert.equal(newer.rows.length, 1);
    h.releaseOpen();
    assert.equal((await old).status, 503);
    assert.deepEqual(await h.inspect(), newer);
    assert.equal(h.calls.filter((c) => c.path === "/_cloud/admit").length, 1);
  }));
test("production class remains disabled despite forged activation env/header/query; admission stays public3000", async () =>
  harness(async (h) => {
    const r = await h.request(
      "/uapi/cloud-workflows?cloud=true",
      { fixture: true },
      {
        "x-chatai-cloud-enabled": "true",
        "cf-container-target-port": "3101",
        "x-chatai-cloud-epoch": "1",
      },
    );
    assert.equal(r.status, 404);
    assert.ok(h.calls.every((c) => c.port === "3000"));
    assert.equal((await h.inspect()).state, null);
  }, true));

for (const work of ["busy", "idle"])
  test(`running SDK ${work}: future-at-entry waits, pending row survives, subsequent callback progresses`, async () =>
    harness(async (h) => {
      await h.arm();
      h.setWork(work);
      const first = await h.inspect();
      assert.ok(first.rows[0].time * 1000 > Date.now());
      const r = await h.request("/__fixture/running", { rounds: 3 });
      assert.equal(r.status, 200);
      const { cycles } = await r.json();
      h.calls.push({ fixtureCycles: cycles });
      assert.equal(cycles[0].callbacks.length, 0);
      assert.ok(cycles[0].exitedAt >= first.rows[0].time * 1000);
      assert.ok(
        cycles[0].after.rows.some((row) => row.id === first.rows[0].id),
        "future row reached due but never entered callback must survive first return",
      );
      assert.ok(
        cycles[1].callbacks.some((c) => c.nativeId === first.rows[0].id),
        "next SDK enumeration must actually invoke pending callback",
      );
      assert.ok(cycles.every((c) => c.peakRows <= 2));
      assertKickProofs(cycles);
      if (work === "busy") {
        assert.ok(
          cycles[2].callbacks.length >= 2,
          "two real callback/kick cycles must progress",
        );
        const writer = cycles[1].after.rows[0];
        assert.ok(
          cycles[1].exitedAt >= writer.time * 1000,
          "SDK actually waited the successor due after callback",
        );
        assert.ok(cycles[1].after.rows.some((row) => row.id === writer.id));
        assert.equal(
          h.calls.filter((c) => JSON.parse(c.body ?? "{}").op === "kick")
            .length,
          2,
        );
      } else {
        assert.equal(cycles[1].after.state.phase, "idle");
        assert.equal(cycles[1].after.rows.length, 0);
        assert.equal(
          h.calls.filter((c) => JSON.parse(c.body ?? "{}").op === "kick")
            .length,
          1,
        );
      }
    }));

function assertKickProofs(cycles) {
  for (const p of cycles.at(-1).kickProofs) {
    const active = p.callback.nativeId;
    assert.ok(
      p.snapshot.rows.some((r) => r.id === active),
      "true callback row is still present before SDK DELETE",
    );
    const successor = p.snapshot.rows.find(
      (r) => JSON.parse(r.payload).intentId === p.snapshot.state.wake.id,
    );
    assert.ok(successor);
    assert.notEqual(successor.id, active);
    assert.notEqual(
      JSON.parse(successor.payload).intentId,
      p.callback.payload.intentId,
    );
    assert.ok(
      p.alarm > p.at,
      "actual future persisted native alarm exists before every kick",
    );
    assert.ok(p.snapshot.rows.length <= 2);
  }
}
test("running SDK pending due identity survives same-g admissions and further clock advance", async () =>
  harness(async (h) => {
    await h.arm();
    const before = await h.inspect();
    const r = await h.request("/__fixture/running", {
      rounds: 3,
      reenter: true,
    });
    assert.equal(r.status, 200);
    const { cycles } = await r.json();
    h.calls.push({ fixtureCycles: cycles });
    assert.equal(cycles[0].callbacks.length, 0);
    for (const a of cycles[0].admissions) {
      assert.equal(a.status, 200);
      assert.equal(a.snapshot.state.epoch, before.state.epoch);
      assert.deepEqual(a.snapshot.rows, before.rows);
      assert.equal(a.snapshot.state.wake.id, before.state.wake.id);
      assert.ok(a.alarm > cycles[0].exitedAt + 45000);
    }
    assert.ok(cycles[2].callbacks.length >= 2);
    assert.ok(cycles.every((c) => c.peakRows <= 2));
    assertKickProofs(cycles);
  }));
test("missing current native row is not treated as pending; real schedule/alarm is recreated", async () =>
  harness(async (h) => {
    await h.arm();
    const before = await h.inspect();
    await h.request("/__fixture/drop-pending", {});
    assert.equal((await h.inspect()).rows.length, 0);
    assert.equal((await h.request("/__fixture/alarm", {})).status, 200);
    const after = await h.inspect();
    assert.equal(after.rows.length, 1);
    assert.notEqual(after.rows[0].id, before.rows[0].id);
    assert.equal(
      h.calls.filter((c) => JSON.parse(c.body ?? "{}").op === "kick").length,
      0,
    );
  }));
for (const failure of ["kick", "closeAck"])
  test(`running SDK ${failure} failure preserves successor and next callback reachability`, async () =>
    harness(async (h) => {
      await h.arm();
      if (failure === "closeAck") {
        h.setWork("idle");
        h.faults.closeAck = true;
      } else h.faults.kick = "once";
      const r = await h.request("/__fixture/running", { rounds: 3 });
      assert.equal(r.status, 200);
      const { cycles } = await r.json();
      h.calls.push({ fixtureCycles: cycles });
      assert.equal(cycles[0].callbacks.length, 0);
      assert.equal(cycles[1].after.state.phase, "armed");
      assert.ok(cycles[2].callbacks.length >= 2);
      assert.ok(cycles.every((c) => c.peakRows <= 2));
      assertKickProofs(cycles);
      if (failure === "closeAck") {
        assert.equal(cycles[2].after.state.phase, "idle");
        assert.equal(cycles[2].after.rows.length, 0);
      }
    }));

test("running SDK logical at alone cannot pass: failed postflight native alarm rejects whole entry without deleting pending row", async () =>
  harness(async (h) => {
    await h.arm();
    const before = await h.inspect();
    const r = await h.request("/__fixture/running", {
      rounds: 1,
      failPostflight: true,
    });
    assert.equal(r.status, 503);
    const after = await r.json();
    h.calls.push({ failureBoundary: after.alarmFailure });
    assert.equal(after.alarmFailure.callbacks.length, 0);
    assert.ok(after.alarmFailure.alarm <= after.alarmFailure.at);
    assert.ok(
      after.alarmFailure.snapshot.state.wake.at > after.alarmFailure.at,
    );
    assert.deepEqual(after.rows, before.rows);
    assert.equal(
      h.calls.filter((c) => JSON.parse(c.body ?? "{}").op === "kick").length,
      0,
    );
  }));
test.after(async () => {
  if (process.env.C3B_SDK_EVIDENCE)
    await writeFile(
      process.env.C3B_SDK_EVIDENCE,
      JSON.stringify(
        {
          sdk: "0.3.7",
          runtime: "native workerd SQLite; Container transport shim",
          cases: evidence,
        },
        null,
        2,
      ),
    );
});
