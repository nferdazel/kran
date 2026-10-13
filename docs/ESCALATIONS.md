# ESCALATIONS — CBS

Tempat STOP: hal yang **tidak boleh** dilanjutkan dengan menebak (AGENTS.md §8).

Format entri:

```
## E-xxx — <judul singkat>
- Tanggal:
- Task:
- Kategori: ADR terbuka | area kritis HUMAN-REVIEW-REQUIRED | regulasi tidak pasti |
  butuh akses di luar repo | spec ambigu/kontradiktif | gate tampak salah | batas review
- Fakta:
- Opsi + rekomendasi:
- Yang dibutuhkan dari manusia:
- Status: TERBUKA | TERJAWAB (tanggal)
```

---

## E-001 — Keputusan ADR-002: HTTP server Nim (Mummy vs Prologue vs hand-rolled)

- Tanggal: 2026-10-13
- Task: T-014 (memblokir T-008 contract test, T-009 SSE, T-012 end-to-end)
- Kategori: ADR terbuka (AGENTS.md §8 butir 1; spec §25 ADR-002 = "Perlu benchmark")
- Fakta (spike selesai, `docs/spikes/ADR-002-http-server.md`):
  1. **Mummy 0.4.8 tidak bisa SSE** — tidak ada API streaming; bukti: endpoint stream hanya
     bisa menjawab 501. Yang didukung: WebSocket first-class, keep-alive, gzip, worker pool.
  2. Performa terukur (`hey -n 10000 -c 50`, laptop): Mummy **54.341 rps**, Prologue 46.094,
     hand-rolled asyncnet 18.824 (terhukum karena `Connection: close`).
  3. Mummy/Prologue memanggil handler di thread (Mummy) vs async (Prologue). Handler Mummy
     **boleh blocking** → cocok dengan `db_connector` sinkron yang diwajibkan spec §12.1.
     Pada model async, query PG sinkron membekukan seluruh API — persis yang sudah dialami
     `fond` (keputusan D-17 di `~/Projects/fond/apps/api/src/http.nim`).
  4. Prologue juga tidak mengekspos SSE; menambahkannya = menulis soket mentah (kelas risiko
     D-17) sambil tetap membawa 6+ dependensi.
- Opsi + rekomendasi:
  - **A (rekomendasi)**: Mummy untuk REST + **WebSocket** untuk realtime, endpoint tetap
    `/api/v1/events/stream` dengan shim `EventSource`-like di frontend + resume token.
    **Deviasi spec §19.1/§13 (SSE → WS)** ⇒ butuh persetujuan eksplisit pemilik + update spec.
  - **B**: hand-rolled `std/asyncnet` (pola `fond`) → SSE sesuai spec, tapi memelihara
    ~600+ baris server HTTP sendiri + wajib offload query PG sinkron.
  - **C**: Prologue → ditolak (tidak menutup kebutuhan SSE, dependensi terbanyak, binary 3×).
- Yang dibutuhkan dari manusia: **pilih A atau B** (dan bila A: setujui deviasi SSE→WS agar
  spec §19.1/§13 diperbarui). Selama belum diputuskan, T-008 (contract test), T-009 (SSE hub),
  T-012 (end-to-end) tetap `BLOCKED`; task Fase 0 lain jalan terus.
- Status: TERBUKA
