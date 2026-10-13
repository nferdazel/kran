# Spike ADR-002 — HTTP server Nim: Mummy vs Prologue vs hand-rolled asyncnet

- **Tanggal**: 2026-10-13
- **Task**: T-014 (memblokir T-008 contract test, T-009 SSE hub, T-012 end-to-end)
- **Status**: **spike selesai — menunggu keputusan pemilik** (`docs/ESCALATIONS.md` E-001)
- **Pertanyaan yang dijawab**: server HTTP mana yang dipakai CBS, dan bagaimana realtime
  (`§19.1 SSE`) disajikan?

Artefak prototipe (dijalankan di mesin lokal, hasil di bawah): `docs/spikes/adr002/`.

## 1. Kebutuhan CBS yang mengikat

| Kebutuhan | Sumber |
|---|---|
| REST/JSON `/api/v1/...`, `application/problem+json` untuk error | spec §13 |
| **Realtime satu arah ke UI** (`GET /api/v1/events/stream`, resume `Last-Event-ID`) | spec §13, §19.1–19.2 |
| Handler boleh memanggil Postgres **sinkron** (`db_connector` + SQL eksplisit) | spec §12.1, §5.3 |
| Dibungkus `shared/platform-lib/http` agar bisa diganti | spec §12.1 |
| `--mm:orc`, `--threads:on` | spec §12.1 |
| Ekosistem Nim kecil → minim dependensi, pin versi | spec §12.1, §24 |

## 2. Fakta yang diukur (bukan dikutip dari README)

Metode: tiga server prototipe dengan permukaan sama (`GET /api/v1/ping` JSON, SSE/stream,
404 `application/problem+json`), di-compile `nim c -d:release --mm:orc --threads:on`
(Prologue: `--threads:on` bawaan, 8 thread). Beban: `hey -n 10000 -c 50` (keep-alive).

| Kandidat | Versi | RPS (hey, c=50) | Rata-rata | Ukuran binary | Dependensi langsung |
|---|---|---|---|---|---|
| **Mummy** | 0.4.8 | **54.341** | 0,9 ms | 267 KB | `zippy`, `webby`, `crunchy` |
| **Prologue** | 0.6.8 | 46.094 | 1,1 ms | 788 KB | `regex`, `nimcrypto`, `cookiejar`, `httpx`, `logue` (+ transitif: `unicodedb`, …) |
| **asyncnet hand-rolled** (pola `fond`) | — | 18.824 | 2,6 ms | 220 KB | — |

Catatan kejujuran atas angka:

- Klien keep-alive membuat prototipe hand-rolled terhukum: ia menutup koneksi tiap request
  (`Connection: close`, sama seperti `fond` D-17), jadi angka 18,8k termasuk biaya
  handshake TCP per request. Dengan klien asyncio Python yang sama, ketiganya ~7,7–8,3k
  rps ⇒ **batas atas pengukuran relatif adalah kliennya**; angka `hey` di atas yang dipakai
  sebagai pembanding utama.
- Mesin uji = laptop ini (Apple Silicon), bukan server VPS. Angka absolut tidak boleh
  dipakai sebagai janji kapasitas; yang relevan adalah **selisih antar kandidat**.
- `ab` gagal pada Mummy **dan** Prologue: keduanya mengirim status-line tanpa reason-phrase
  (`HTTP/1.1 200`, sah menurut RFC 7230) dan ApacheBench 2.3 menolaknya (timeout).
  Diverifikasi byte-exact:
  `b'HTTP/1.1 200\r\nContent-Type: application/json...'` (Mummy) vs
  `b'HTTP/1.1 200 OK\r\n...'` (prototipe hand-rolled).

## 3. Temuan yang menentukan keputusan

1. **Mummy 0.4.8 tidak bisa menyajikan SSE.** Tidak ada API streaming/chunked response;
   respons dikirim utuh dari memori (README-nya sendiri: *"sends in-memory responses"*).
   Bukti empiris: endpoint `/api/v1/events/stream` hanya bisa menjawab `501`.
   Yang **didukung first-class**: WebSocket (`request.upgradeToWebSocket`, `websocket.send`,
   ada handler event Open/Message/Error/Close).
2. **Mummy adalah model thread-per-request** (socket IO di satu thread, handler di worker
   pool). Konsekuensi besar yang menguntungkan CBS: handler **boleh blocking** → panggilan
   `db_connector` sinkron (spec §12.1) tidak perlu di-offload ke threadpool. Sebaliknya,
   server async (Prologue/`asynchttpserver`/hand-rolled) akan **membekukan seluruh API**
   saat satu handler menunggu query Postgres atau stream panjang.
3. **Pelajaran produksi dari `fond` (repo Nim Anda, `apps/api/src/http.nim`, keputusan D-17).**
   `std/asynchttpserver` sengaja ditinggalkan karena `acceptRequest` menggabungkan
   "terima koneksi" dengan "proses seluruh siklus hidup koneksi": satu koneksi panjang
   (SSE / tab browser yang menahan keep-alive) **membekukan seluruh API**; percobaan
   `asyncCheck acceptRequest` malah menghasilkan busy-spin 100% CPU. `fond` akhirnya
   menulis server sendiri di atas `std/asyncnet` (~22 KB `http.nim`, plus batas header/body,
   timeout, batas koneksi) — dan itulah harga "SSE native tanpa dependensi".
   Prologue memakai keluarga server yang sama (`httpx`, turunan httpbeast/asynchttpserver),
   jadi kelas risiko ini relevan untuk Prologue.
4. **SSE bekerja pada prototipe hand-rolled** (diverifikasi: `id: 0` / `data: {"n":0}`
   mengalir per 200 ms tanpa menunggu request selesai) — jadi opsi spec-literal memang
   mungkin, tapi harus kita pelihara sendiri.
5. **Biaya nyata memelihara server sendiri terlihat dalam 30 menit prototipe**: bug flush/
   close (data hilang bila soket ditutup sebelum dispatcher menulis), semantik keep-alive
   (klien keep-alive menganggap koneksi putus sebagai error), parsing header, batas ukuran.
   `fond` sudah membayar semua itu; memakai ulang polanya = memelihara ~600+ baris kode
   server di CBS, di luar domani bisnis CBS.
6. **Prologue tidak mengekspos SSE** lewat API publiknya (`Context`/`Response` hanya
   `resp(...)`); menambah SSE berarti menulis langsung ke soket mentah → kembali ke
   risiko kelas D-17, sambil tetap membawa 6 dependensi langsung + framework magic.

## 4. Opsi dan konsekuensi

### Opsi A — **Mummy** untuk REST + **WebSocket** untuk realtime _(rekomendasi)_

- REST + router (`mummy/routers`) + gzip + keep-alive dari Mummy.
- Realtime: `GET /api/v1/events/stream` di-upgrade ke WebSocket; pesan berbentuk
  `{id, topic, payload}`; resume dengan token (`Last-Event-ID` di spec §19.2 menjadi
  parameter `?since=` saat `onopen`, atau header `Last-Event-ID` yang dikirim klien).
  Frontend memakai shim kecil (~40 baris TS) yang menirukan `EventSource` supaya komponen
  tidak peduli transportnya.
- **Konsekuensi**: satu-satunya deviasi dari spec — §19.1 (SSE) dan §13 (nama endpoint
  boleh tetap sama, transportnya WS). Wajib: update spec + catat di DECISIONS, dan frontend
  memakai shim agar deviasi terkapsul.
- Biaya: 3 dependensi kecil terpelihara; tidak ada async coloring; handler sinkron.

### Opsi B — hand-rolled `std/asyncnet` (pola `fond`) + SSE sesuai spec

- Spec-literal, nol dependensi HTTP, SSE native.
- **Konsekuensi**: memelihara server HTTP sendiri (~600+ baris: parsing, batas, timeout,
  keep-alive, batas koneksi, TLS opsional); panggilan `db_connector` sinkron **wajib**
  di-offload (threadpool/worker) atau API membeku; throughput keep-alive lebih rendah
  pada prototipe.

### Opsi C — **Prologue**

- Framework lengkap: router, middleware, plugin (openapi, session, i18n, CORS).
- **Konsekuensi**: SSE tidak tersedia → tetap menulis soket mentah (risiko kelas D-17);
  6+ dependensi langsung; ukuran binary 3×; interop `ab` gagal (tidak fatal, tapi sinyal).

### Opsi D — Mummy untuk REST + proses kedua khusus SSE

Ditolak: dua listener/port, dua jalur auth, kompleks tanpa manfaat proporsional.

## 5. Rekomendasi

**Opsi A**: Mummy sebagai HTTP server di balik `shared/platform-lib/http`, realtime lewat
WebSocket dengan endpoint & resume-token yang menirukan `EventSource`.

Alasan utama, berurutan: (1) handler sinkron cocok dengan `db_connector` yang diwajibkan
spec, sehingga tidak ada risiko "API membeku" seperti yang sudah dialami `fond`; (2) Mummy
adalah satu-satunya kandidat yang membawa jalur realtime yang benar-benar didukung, alih-alih
jalur yang harus kita tambal sendiri; (3) `--mm:orc --threads:on` sudah jadi syarat spec;
(4) performa terukur terbaik; (5) dependensinya paling sedikit dan paling kecil.

Kalau pemilik menolak deviasi SSE → **Opsi B** (spec-literal), dengan kesadaran biaya
pemeliharaan tertulis di atas; jangan Opsi C (menambah framework tanpa menutup kebutuhan SSE).

Yang **tidak** berubah apa pun pilihannya: `shared/platform-lib/http` tetap tipis dan
menyembunyikan server terpilih, sehingga ADR-002 bisa ditinjau ulang tanpa menyentuh modul.

## 6. Cara mengulang pengukuran

```sh
cd docs/spikes/adr002
nim c --mm:orc --threads:on -d:release -o:mummy_srv   mummy_srv.nim && ./mummy_srv &
nim c --mm:orc              -d:release -o:prologue_srv prologue_srv.nim && ./prologue_srv &
nim c --mm:orc --threads:on -d:release -o:asyncnet_srv asyncnet_srv.nim && ./asyncnet_srv &
hey -n 10000 -c 50 http://127.0.0.1:8081/api/v1/ping   # Mummy
hey -n 10000 -c 50 http://127.0.0.1:8082/api/v1/ping   # Prologue
hey -n 10000 -c 50 http://127.0.0.1:8083/api/v1/ping   # hand-rolled
curl -s -N --max-time 2 http://127.0.0.1:8083/api/v1/events/stream   # SSE (hanya asyncnet)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/api/v1/events/stream  # Mummy -> 501
```

## 7. Yang belum diverifikasi (jujur)

- Belum ada uji WebSocket end-to-end (klien WS belum dipasang di mesin ini) → risiko
  terbesar Opsi A: perilaku WS lewat Caddy + reconnect/resume belum diuji di produksi.
- Belum diukur di VPS (2 vCPU, 3,5 GB RAM) — angka laptop tidak boleh dipakai sebagai janji.
- Belum diuji beban SSE dengan ratusan koneksi simultan (hanya 20 koneksi SSE + beban ping,
  dan pengukuran itu sendiri tercemar semantik keep-alive → tidak dipakai sebagai bukti).
- ADR-007 (RLS) & ADR-013 (mesin PDF) tetap terbuka, tidak terkait spike ini.
