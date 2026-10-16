# Spike — berhenti bersih `cbs-api` (O-025, T-024)

Tanggal: 15 Oktober 2026. Lingkungan: macOS arm64, Nim 2.2.12, Mummy 0.4.8, `--mm:orc --threads:on`.

## Gejala yang tercatat

O-025 mencatat `server.close()` pada Mummy 0.4.8 + ORC mematikan proses (SIGSEGV di `destroy`),
sehingga test tidak menutup server dan "restart/deploy yang butuh shutdown bersih belum terverifikasi".

## Fakta yang diamati hari ini

1. **Tidak ada penangan sinyal sama sekali.** `main.nim` hanya memanggil `serveApi(...)`, yang
   memblokir di `server.serve(...)`; tidak ada `signal`, tidak ada `setControlCHook`. Akibatnya
   `SIGTERM` mematikan proses sebagai sinyal (kode 143) tanpa jalur penutupan apa pun.
2. **Prosesnya bocor.** Dua proses `cbs-api` berumur **16 jam** ditemukan masih mendengarkan port
   8096/8097 (sisa alat pengujian sebelumnya). Tidak ada mekanisme yang menghentikannya; pembersihan
   memerlukan `kill -9`.
3. **`server.close()` tidak reput di bentuk minimal.** Probe terpisah (`mummy` + ORC, server di
   thread, satu handler): `srv.close()` kembali normal, proses keluar 0 — **tidak ada SIGSEGV**.
   Jadi laporan O-025 bergantung konteks (kemungkinan teardown di dalam proses test yang masih hidup,
   bersama pool DB dan thread pump); bentuk persisnya tidak dapat direproduksi dari catatan yang ada.

## Keputusan

Berhenti bersih **tidak membutuhkan `server.close()`**:

- Handler sinyal (`SIGINT`/`SIGTERM`) hanya menyimpan satu flag atomik — seminimal mungkin, aman
  dipanggil dari konteks sinyal (tanpa I/O, tanpa menyentuh DB/Mummy).
- Thread penunggu (`watchStop`) melihat flag itu, menghentikan pump realtime (menunggu loopnya
  selesai maksimum 2 detik), menulis satu baris log, lalu `quit(0)`.
- `server.close()` sengaja dihindari: jalur itu yang dilaporkan bermasalah, dan berhenti bersih tidak
  memerlukannya. Karena itu O-025 **diperkecil** menjadi pertanyaan teardown *in-process* (test
  harness), bukan syarat shutdown produksi.

Batas yang diketahui dan dicatat (O-047): permintaan HTTP yang sedang berjalan **dipotong** saat
proses keluar — belum ada drain. Karena `serveApi` tidak mengembalikan `Server`, drain menuntut
perubahan `server.nim`; itu pekerjaan tersendiri, bukan bagian T-024.

**Diperbarui (T-032):** drain sudah ada (`drain.nim` + pembungkus handler di `server.nim` +
`watchStop` menunggu maksimum 10 detik + `/readyz` gagal saat berhenti). Yang masih terpotong:
koneksi yang sudah diterima tetapi belum masuk ke handler, dan soket realtime (ditutup oleh keluarnya
proses; klien menyambung ulang).

## Diperbarui (T-042, 16 Okt 2026): repro deterministik + urutan aman

Gejala SIGSEGV **berhasil direproduksi deterministik** di tree saat ini (macOS arm64, Nim 2.2.12,
Mummy 0.4.8, `--mm:orc --threads:on`). Pemicunya bukan pool/pump/WebSocket, melainkan **thread tempat
`destroy` berjalan**:

| Varian | Bangun server | `serve()` | `close()` dipanggil dari | Hasil |
|---|---|---|---|---|
| 1 (pola harness lama) | thread utama | thread lain | thread utama | **SIGSEGV** di `mummy.nim:1143` (`=destroy(server[])`) → `orc.nim nimDecRefIsLastCyclicDyn`/`unregisterCycle` |
| 5 | thread utama | thread utama | thread lain | aman |
| 6 | thread lain | thread lain (sama) | thread utama | aman |
| 7 = 6 + klien WebSocket hidup | thread lain | thread lain (sama) | thread utama | aman (3× berturut) |

**Sebab:** `Server` dialokasikan `allocShared0`, tetapi closure handler-nya (mis. `requestHandler(app)`)
adalah nilai yang dikelola ORC. `destroy(true)` memanggil `=destroy(server[])` di **thread yang
melayani**; ORC menyimpan pembukuan siklus **per-thread**, jadi menghancurkan closure yang
dialokasikan thread lain membaca state yang salah → SIGSEGV. Server minimal (handler tanpa capture)
tidak memicunya karena tidak ada siklus yang dikelola ORC — itu sebabnya probe 15 Okt tidak reput.

**Urutan aman (dipakai `apps/api/tests/itapi_teardown.nim`):** bangun **dan** layani server di **thread
yang sama**; `close()` boleh dipanggil dari thread lain (ia hanya memicu sinyal shutdown; `destroy`
tetap berjalan di thread pelayan). Setelah `joinThread`, baru tutup pool. Shutdown produksi
(T-024/D-031) tidak memanggil `close()` sama sekali (sinyal → hentikan pump → `quit(0)`), jadi tidak
terpengaruh.

**Batas yang tetap ada:** `Server` yang ditutup `close()` menjadi `ptr` menggantung — jangan dipakai
lagi setelahnya. Upgrade Mummy belum diambil: batas versi masih `>= 0.4.8 & < 0.5.0` (D-037) dan
belum ada bukti perbaikan hulu; mengubahnya butuh keputusan terpisah.

Bukti: `apps/api/tests/itapi_teardown.nim` (2 uji: siklus penuh + siklus kedua) — `[OK]`. Dengan
urutan lama (bangun di thread uji, layani di thread lain) berkas yang sama `SIGSEGV`.

## Bukti

- Manual: `.build/bin/cbs-api --role=api --port=8095` lalu `kill -TERM` → `EXIT_CODE=0`, log
  `cbs-api: berhenti dengan tenang (SIGINT/SIGTERM)`, port langsung bebas.
- Otomatis: `apps/web/tests/e2e/shutdown.spec.ts` (spawn biner, tunggu `/healthz`, kirim SIGTERM,
  harapkan `code = 0` dan `signal = null`). Daya tangkap: penangan sinyal dilepas sementara → test
  **GAGAL**; dikembalikan → lulus (3,7 detik).
