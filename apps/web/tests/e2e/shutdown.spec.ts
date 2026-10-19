import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import { expect, test } from "@playwright/test";

/**
 * Berhenti bersih (T-024, O-025) dan drain permintaan berjalan (T-032, O-047): `SIGTERM` harus
 * membuat proses berhenti dengan **kode 0** dan menyelesaikan permintaan yang sudah masuk ke
 * handler. Sebelum T-024 `kran-api` tidak memasang penangan sinyal sama sekali sehingga SIGTERM
 * menghasilkan kode 143 tanpa jalur penutupan apa pun; sebelum T-032 proses keluar seketika,
 * sehingga respons yang sedang dihitung terpotong.
 *
 * Berkas ini sengaja memakai instance API **kedua** di port bebas: `webServer` Playwright (8099)
 * tidak boleh diganggu, dan pengujian ini tidak butuh UI. Biner dibangun `./task e2e` lebih dulu.
 */

test.skip(!process.env.KRAN_DATABASE_URL, "KRAN_DATABASE_URL kosong — API tidak dijalankan");

const DEV_USER = { username: "dev.maker", password: "rahasia-panjang-123" };

type ApiInstance = {
  child: ChildProcess;
  port: number;
  output: () => string;
  exited: Promise<{ code: number | null; signal: string | null }>;
};

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

type StartOptions = {
  /** Rute yang dipakai untuk menunggu kesiapan (default `/healthz`). */
  healthPath?: string;
  /** Batas tunggu kesiapan dalam milidetik (default 20 detik). */
  readyTimeoutMs?: number;
};

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Jalankan satu instance API di port bebas dan tunggu sampai `/healthz` menjawab. */
async function startApi(options: StartOptions = {}): Promise<ApiInstance> {
  const { healthPath = "/healthz", readyTimeoutMs = 20_000 } = options;
  const port = await freePort();
  // `exec` supaya PID yang dikirimi sinyal adalah proses API-nya, bukan shell-nya. `.local/dev.env`
  // di-source di dalam shell karena `DYLD_*` tidak diwarisi lewat spawner (D-026).
  const child = spawn(
    "sh",
    [
      "-lc",
      `set -a; [ -f ../../.local/dev.env ] && . ../../.local/dev.env; set +a; ` +
        `exec ../../.build/bin/kran-api --role=api --port=${port} --address=127.0.0.1`,
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  let output = "";
  child.stdout?.on("data", (chunk: Buffer) => (output += String(chunk)));
  child.stderr?.on("data", (chunk: Buffer) => (output += String(chunk)));
  const exited = new Promise<{ code: number | null; signal: string | null }>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });

  const deadline = Date.now() + readyTimeoutMs;
  let ready = false;
  while (Date.now() < deadline && !ready) {
    try {
      // Abort per percobaan: `fetch` tanpa batas bisa menggantung bila peer menerima TCP tetapi
      // tidak menjawab, sehingga loop kesiapan tidak pernah memeriksa `deadline` (T-044 H1).
      const remaining = Math.max(1, deadline - Date.now());
      const response = await fetch(`http://127.0.0.1:${port}${healthPath}`, {
        signal: AbortSignal.timeout(Math.min(remaining, 1_000)),
      });
      ready = response.status === 200;
    } catch {
      ready = false; // belum menerima koneksi
    }
    if (!ready) await sleep(200);
  }
  if (!ready) {
    // T-062: pemanggil belum memegang handle anak saat helper ini melempar, jadi `finally` di test
    // tidak akan membunuhnya. Bersihkan di sini, lalu lempar galat yang membawa PID untuk diperiksa.
    child.kill("SIGKILL");
    await exited;
    throw Object.assign(
      new Error(`API tidak siap pada port ${port}; keluaran:\n${output}`),
      { pid: child.pid },
    );
  }

  return { child, port, output: () => output, exited };
}

test("SIGTERM → proses berhenti bersih (kode 0) dan port dilepas", async () => {
  const api = await startApi();
  try {
    api.child.kill("SIGTERM");
    const status = await api.exited;

    expect(status.signal, `proses dibunuh sinyal; keluaran:\n${api.output()}`).toBeNull();
    expect(status.code, `kode keluar bukan 0; keluaran:\n${api.output()}`).toBe(0);
    expect(api.output()).toContain("berhenti dengan tenang");
  } finally {
    api.child.kill("SIGKILL");
  }
});

test("SIGTERM menunggu permintaan yang sedang berjalan selesai (drain)", async () => {
  const api = await startApi();
  try {
    // Login = permintaan yang benar-benar lambat di sini: verifikasi PBKDF2 600.000 iterasi
    // (parameter dev) di depan DB yang ada di server lain. Tidak ada `sleep` buatan yang perlu
    // ditambahkan supaya test terasa "lambat" — bebannya nyata.
    const login = fetch(`http://127.0.0.1:${api.port}/api/v1/auth/login`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(DEV_USER),
    }).catch((error: unknown) => error as Error);

    // Beri waktu permintaan masuk ke handler sebelum sinyal dikirim.
    await sleep(300);
    api.child.kill("SIGTERM");

    const response = await login;
    expect(response, "permintaan dipotong saat proses berhenti (belum ada drain)").not.toBeInstanceOf(
      Error,
    );
    const http = response as Response;
    expect(http.status, `permintaan tidak selesai dengan 200; keluaran:\n${api.output()}`).toBe(200);

    const status = await api.exited;
    expect(status.code, `kode keluar bukan 0; keluaran:\n${api.output()}`).toBe(0);
    // Drain-nya terlihat di log, bukan hanya disimpulkan dari respons.
    expect(api.output()).toContain("permintaan berjalan selesai");
  } finally {
    api.child.kill("SIGKILL");
  }
});

test("kesiapan gagal → proses anak tidak ditinggalkan (T-062)", async () => {
  // Rute 404 membuat readiness tidak pernah tercapai; batas 1,5 s supaya test tetap cepat.
  const failure = (await startApi({ healthPath: "/rute-tidak-ada", readyTimeoutMs: 1_500 }).catch(
    (error: unknown) => error,
  )) as Error & { pid?: number };

  expect(failure).toBeInstanceOf(Error);
  expect(failure.message).toContain("API tidak siap");
  expect(failure.pid, "helper gagal tanpa menyebut PID anak").toBeGreaterThan(0);
  expect(isAlive(failure.pid as number), "proses kran-api yatim tertinggal").toBe(false);
});
