import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import { expect, test } from "@playwright/test";

/**
 * Berhenti bersih (T-024, O-025): `SIGTERM` harus membuat proses berhenti dengan **kode 0**, bukan
 * dibunuh sinyal. Sebelum perbaikan, `cbs-api` tidak memasang penangan sinyal sama sekali sehingga
 * SIGTERM menghasilkan kode 143 tanpa jalur penutupan apa pun — dan prosesnya bisa tertinggal
 * berjam-jam (dua proses sisa berumur 16 jam ditemukan saat mengerjakan task ini).
 *
 * Berkas ini sengaja memakai instance API **kedua** di port bebas: `webServer` Playwright (8099)
 * tidak boleh diganggu, dan pengujian ini tidak butuh UI. Biner dibangun `./task e2e` lebih dulu.
 */

test.skip(!process.env.CBS_DATABASE_URL, "CBS_DATABASE_URL kosong — API tidak dijalankan");

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const probe = createServer();
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      if (address !== null && typeof address === "object") {
        const port = address.port;
        probe.close(() => resolve(port));
      } else {
        reject(new Error("tidak dapat menentukan port bebas"));
      }
    });
  });
}

test("SIGTERM → proses berhenti bersih (kode 0) dan port dilepas", async () => {
  const port = await freePort();
  // `exec` supaya PID yang dikirimi sinyal adalah proses API-nya, bukan shell-nya. `.local/dev.env`
  // di-source di dalam shell karena `DYLD_*` tidak diwarisi lewat spawner (D-026).
  const child = spawn(
    "sh",
    [
      "-lc",
      `set -a; [ -f ../../.local/dev.env ] && . ../../.local/dev.env; set +a; ` +
        `exec ../../.build/bin/cbs-api --role=api --port=${port} --address=127.0.0.1`,
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  let output = "";
  child.stdout?.on("data", (chunk: Buffer) => (output += String(chunk)));
  child.stderr?.on("data", (chunk: Buffer) => (output += String(chunk)));

  const deadline = Date.now() + 20_000;
  let ready = false;
  while (Date.now() < deadline && !ready) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/healthz`);
      ready = response.status === 200;
    } catch {
      ready = false; // belum menerima koneksi
    }
    if (!ready) await sleep(200);
  }
  expect(ready, `API tidak siap pada port ${port}; keluaran:\n${output}`).toBe(true);

  const exited = new Promise<{ code: number | null; signal: string | null }>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  child.kill("SIGTERM");
  const status = await exited;

  expect(status.signal, `proses dibunuh sinyal; keluaran:\n${output}`).toBeNull();
  expect(status.code, `kode keluar bukan 0; keluaran:\n${output}`).toBe(0);
  expect(output).toContain("berhenti dengan tenang");
});
