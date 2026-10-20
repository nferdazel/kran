# Go-live Fase 1 — checklist

Branch `feat/fase1-party`, gate terakhir `b3f3f98` (816 `[OK]`, e2e 24). Rujukan: `deploy-setup.md`,
`field-encryption.md`, `ops-cli.md`, `migrasi.md`.

**Aturan:** merge ke `main` = deploy (webhook). Merge hanya oleh pemilik (AGENTS §3). Langkah bertanda
**OWNER** tidak dijalankan agen.

## 0. Prasyarat (repo)

- [x] `./task ci` hijau pada commit yang akan di-merge (`b3f3f98`)
- [x] Semua task Fase 1 `DONE` + reviewer APPROVE (`docs/BACKLOG.md`)
- [x] `docs/milestones/M1-report.md` diperbarui
- [ ] Nilai parameter pilot disetujui pemilik (**O-066**) — seed base bertanda
      `NEEDS-COMPLIANCE-REVIEW`; jangan mengarang angka

## 1. Sebelum merge (OWNER, di server)

- [ ] Backup DB terjadwal + verifikasi restore sekali (runbook `migrasi.md`)
- [ ] Cek kapasitas disk image (`podman images`, retensi `KRAN_IMAGE_KEEP`) — D-066/T-069
- [ ] Pastikan `:local` dan `:prev` ada (dasar rollback)
- [ ] Ganti password admin awal (`dev.firstlogin`/akun produksi) — jangan deploy dengan default
- [ ] Catat SHA `main` saat ini (titik rollback)

## 2. Merge (OWNER)

```bash
git checkout main
git pull --ff-only
git merge --no-ff feat/fase1-party
git push origin main          # memicu deploy + health gate + auto-rollback
```

- [ ] Pantau log deploy; health gate `/readyz` lulus
- [ ] Bila rollback otomatis: cek `ops/scripts/rollback.sh` + log, jangan paksa ulang

## 3. Setelah deploy (OWNER + verifikasi)

- [ ] `curl -fsS https://cbs.qouver.com/healthz` dan `/readyz` → 200
- [ ] Login sesi nyata; buka `GET /api/v1/ledger/coa` (izin `ledger.coa.read`)
- [ ] `GET /api/v1/ledger/trial-balance?periodId=…` untuk periode yang dibuka
- [ ] `GET /api/v1/products` (kosong sampai seed katalog) dan `GET /api/v1/parties` (izin sesuai)
- [ ] Audit `platform.audit_log` bertambah untuk aksi yang dilakukan
- [ ] Migrasi: `dbtools status` tidak ada `pending`; tabel `product.*` ada

## 4. Worker akuntansi (OWNER — O-081)

Unit worker kini long-running (`ops/systemd/kran-worker.container`). Sebelum enable:

- [ ] Probe: pastikan ada cara melihat backlog outbox (query `platform.outbox` per status) dan
      `RestartPreventExitStatus=2 3` dipahami (exit 2 = konfigurasi, 1 = DB transien/restart)
- [ ] `systemctl enable --now kran-worker` (quadlet: `systemctl enable --now kran-worker.service`)
- [ ] Kirim satu event sintetis di lingkungan uji/staging → jurnal muncul, event `DONE`
- [ ] Cek `journal.posted` terbit dan log worker tidak berhenti diam-diam

## 5. KEK / field encryption (OWNER — O-071)

Ikuti `docs/runbooks/field-encryption.md` (D-046 butir 12). Ringkas:

- [ ] Buat kunci 32 byte di luar repo/image, mode 0600 (rencana `sops`/`age`)
- [ ] Set `KRAN_KEK_FILE` pada unit API, restart, cek startup tidak menolak
- [ ] Uji satu enkripsi/dekripsi di staging + audit pembacaan
- [ ] **Jangan** aktifkan alur KYC penuh sebelum ini selesai

## 6. Rollback (bila perlu — OWNER)

- [ ] `ops/scripts/rollback.sh` (tag `:prev` → `:local`, pulihkan unit, poll `/readyz`) — D-066
- [ ] Jangan menjalankan migrasi destruktif untuk "membatalkan" Fase 1; migrasi expand-only

## 7. Setelah stabil

- [ ] Catat bukti deploy di `docs/PROGRESS.md` (SHA, waktu, hasil health gate)
- [ ] Putuskan T-079 (UI) — menunggu ratifikasi D-075
