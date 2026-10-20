# Go-live Fase 1 — checklist

Branch `feat/fase1-party`, gate terakhir `b3f3f98` (816 `[OK]`, e2e 24). Rujukan: `deploy-setup.md`,
`field-encryption.md`, `ops-cli.md`, `migrasi.md`.

**Aturan:** merge ke `main` = deploy (webhook). Merge hanya oleh pemilik (AGENTS §3). Langkah bertanda
**OWNER** tidak dijalankan agen.

## 0. Prasyarat (repo)

- [x] `./task ci` hijau pada commit yang akan di-merge (`b3f3f98`)
- [x] Semua task Fase 1 `DONE` + reviewer APPROVE (`docs/BACKLOG.md`)
- [x] `docs/milestones/M1-report.md` diperbarui
- [x] Seed base dijalankan 20 Okt 2026 (33 definisi/nilai; `product.savings.*` ada). Nilai final
      tetap menunggu **O-066**

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

- [x] Deploy 20 Okt 2026: `36602a8` lalu `28168f7`, health gate `/readyz` 200, 33 migrasi
- [ ] Bila rollback otomatis: cek `ops/scripts/rollback.sh` + log, jangan paksa ulang

## 3. Setelah deploy (OWNER + verifikasi)

- [x] `curl -fsS https://cbs.qouver.com/healthz` dan `/readyz` → 200 (20 Okt 2026)
- [ ] Login sesi nyata; buka `GET /api/v1/ledger/coa` (izin `ledger.coa.read`) — **butuh password admin**
- [ ] `GET /api/v1/ledger/trial-balance?periodId=…` untuk periode yang dibuka
- [ ] `GET /api/v1/products` (kosong sampai seed katalog) dan `GET /api/v1/parties` (izin sesuai)
- [ ] Audit `platform.audit_log` bertambah untuk aksi yang dilakukan
- [x] Migrasi: 33 tercatat, schema `party`/`ledger`/`product` ada

## 4. Worker akuntansi (OWNER — O-081)

Unit worker kini long-running (`ops/systemd/kran-worker.container`). Sebelum enable:

- [x] Probe: `/readyz` memuat check `worker` (denyut > 180 dtk, atau belum pernah melapor setelah
      masa tenggang start 180 dtk = gagal) dan `outbox-dead` (jumlah `DEAD` di `detail`, tidak
      menggagalkan readiness). `RestartPreventExitStatus=2 3` dipahami (exit 2 = konfigurasi, 1 = DB transien/restart)
- [ ] Alert eksternal yang memanggil `/readyz` dan memeriksa `DEAD` (O-092)
- [x] Worker aktif 20 Okt 2026; autostart lewat symlink `default.target.wants` (unit quadlet
      generated menolak `systemctl enable`)
- [ ] Kirim satu event sintetis → jurnal muncul, event `DONE` (belum dilakukan di produksi agar
      buku tidak tercemar data uji)
- [ ] Cek `journal.posted` terbit dan log worker tidak berhenti diam-diam

## 5. KEK / field encryption (OWNER — O-071)

Ikuti `docs/runbooks/field-encryption.md` (D-046 butir 12). Ringkas:

- [x] Kunci v1 32 byte dibuat di server, mode 600, di luar repo/image
- [x] `KRAN_KEK_FILE=/run/secrets/kran-kek.key` + mount + `UserNS=keep-id`; API sehat
- [ ] Uji enkripsi/dekripsi nyata + audit pembacaan (butuh sesi admin)
- [ ] Salinan offline/terenkripsi KEK (`sops`/`age`) — **wajib** sebelum data anggota nyata

## 6. Rollback (bila perlu — OWNER)

- [ ] `ops/scripts/rollback.sh` (tag `:prev` → `:local`, pulihkan unit, poll `/readyz`) — D-066
- [ ] Jangan menjalankan migrasi destruktif untuk "membatalkan" Fase 1; migrasi expand-only

## 7. Setelah stabil

- [ ] Catat bukti deploy di `docs/PROGRESS.md` (SHA, waktu, hasil health gate)
- [ ] Putuskan T-079 (UI) — menunggu ratifikasi D-075
