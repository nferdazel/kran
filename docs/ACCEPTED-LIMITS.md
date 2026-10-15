# Batas yang diterima — Fase 0

Dokumen ini adalah **register keputusan**, bukan daftar keinginan. Aturannya satu: setiap batas harus
punya (a) dampak nyata, (b) cara mendeteksinya, dan (c) pemilik — fase atau task yang menanganinya.
Kalau salah satu tidak ada, itu bukan batas yang diterima melainkan pekerjaan yang terlupa.

Alasan dokumen ini ada: "Fase 0 tanpa cela" bukan sesuatu yang bisa dibuktikan siapa pun. Yang bisa
dibuktikan adalah **tidak ada celah yang diketahui pada jalur yang diperiksa**, dan setiap hal yang
belum ditangani tercatat beserta cara melihatnya. Register ini adalah bagian kedua dari kalimat itu.

## 1. Batas yang memang milik fase lain (tidak dipaksakan masuk Fase 0)

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Metrics/observability belum ada (Prometheus-style: latensi, error rate, pool PG, antrean outbox, durasi task day-close) | Tidak ada pengukuran berkelanjutan; operator hanya punya log terstruktur | `/healthz`, `/readyz`, log JSON, dan kueri SQL manual | Fase 9 (spec §22, §23); O-019 |
| Freeze gate day-close | Deploy tidak bisa diblokir karena EOD berjalan; `ctl daycloser-status` selalu "belum ada" | jalankan `ctl daycloser-status` — nilainya selalu 3 sampai `daycloser` ada | Fase 3 (framework `daycloser`); O-013 |
| Uji restore & latihan DR | Tidak ada bukti backup bisa dipulihkan | belum pernah dijalankan | Di luar repo (akses server); O-002, O-007 |
| Target performa (spec §1.4: EOD 100k rekening + 50k pinjaman < 30 menit) | Belum ada bukti skala; angka target belum pernah diuji | belum ada benchmark | Fase 3 (day-close) + Fase 9 |
| Multi-instance / HA | Satu proses = satu titik gagal | arsitektur: satu biner, satu pool, satu pump | Fase 9 (cutover §23) |
| MFA & matriks pemisahan tugas (SoD) | Kontrol akses = kata sandi + RBAC + audit; belum ada faktor kedua | periksa katalog izin & pengaturan akun | Item O-015, O-016 |

## 2. Batas teknis yang diterima setelah batch "Fase 0 tahan banting"

| Batas | Dampak nyata | Cara mendeteksi | Pemilik |
|---|---|---|---|
| Tidak ada rollback **skema** (expand-only) | Migrasi bermasalah hanya bisa ditangani lewat backup pra-deploy | `migrate --contract`/`--down` masih ditolak kode 3 | T-035 (O-048) |
| Job CI GitHub belum lengkap (`db-tests`/`traceability`) | CI GitHub tidak menjalankan uji integrasi DB; gate yang sebenarnya adalah `./task ci` lokal (butuh DB dev) | lihat `docs/ci-jobs.md` | O-027 |
| Antrean kirim realtime per koneksi tidak dibatasi | Klien lambat menambah pemakaian memori proses | pantau RSS; peristiwa hilang ditutup resume token | O-028 |
| Lag outbox tidak diperiksa `/readyz` | `/readyz` tetap hijau walau pump tertinggal memproses outbox | yang diperiksa baru "pump tersambung" (`realtimeProbe`), bukan lag | O-019 (bagian yang tersisa) |
| SIGTERM: koneksi yang belum masuk handler tetap terpotong; soket realtime ditutup oleh keluarnya proses | Permintaan yang belum masuk handler bisa gagal saat deploy; klien WS menyambung ulang | log `permintaan berjalan selesai (drain)` / `N permintaan masih berjalan` | T-032 (diterima; `server.close()` dihindari karena O-025) |
| Jendela staleness izin realtime | Setelah izin dicabut, data masih bisa terkirim sampai satu interval pemeriksaan berakhir | parameter `sessionRecheckSeconds` (0 = setiap putaran pump) | T-030 |
| Validasi koneksi pool menambah satu perjalanan bolak-balik per peminjaman dari idle | Latensi per permintaan naik sedikit | `CBS_DB_VALIDATE_ON_ACQUIRE` (matikan = koneksi mati di server tidak diganti otomatis) | T-033 |
| Biaya KDF tiruan mengikuti parameter iterasi **saat ini** | Akun lama dengan jumlah iterasi berbeda tidak setara biayanya | bandingkan waktu respons login akun tak dikenal vs akun wajar | T-028 |
| Percobaan kata sandi lama di `/auth/password` belum dibatasi/diaudit | Tidak ada perlindungan brute-force pada endpoint itu | belum ada penghitung percobaan di sana | O-050 |
| Regulasi spec §4 bertanda `V?`/`V!` belum terverifikasi | Pasal/angka bisa berubah; yang bergantung padanya belum final | penanda `NEEDS-COMPLIANCE-REVIEW` di kode/seed/docs | O-001 |
| Belum ada kontrak-fuzzing (`schemathesis`), visual regression, ESLint a11y | Cakupan uji kontrak/visual lebih sempit daripada rencana spec | lihat daftar uji; parity kontrak diuji lewat `tcontract`/`itapi` | O-026, O-022, O-023 |

## 3. Yang **tidak** diklaim

- **Bukan "tanpa bug".** Yang dibuktikan: gate hijau berulang, dan setiap perbaikan penting punya uji
  yang **gagal** bila perbaikannya dibalik (lihat §4). Itu batas bukti yang jujur.
- **Stabilitas belum diuji pada beban produksi.** Gate ini menjalankan permintaan serial/rendah;
  uji paralel yang ada (8 thread pada pool kecil, 8 klien realtime) membuktikan kebenaran, bukan
  kapasitas.
- **Deploy & rollback belum pernah dilatih di server.** `ops/scripts/deploy-vps.sh` belum pernah
  dijalankan (T-013); rehearsal-nya pekerjaan tersendiri dan butuh keputusan pemilik.

## 4. Bukti yang ada hari ini

- `./task ci-repeat 3` (gate kestabilan, T-031): hijau 3 putaran berturut-turut — angka lengkapnya
  dicatat di `docs/tasks/T-037.md` pada saat run penutup dijalankan.
- Enam perbaikan terbukti **diskriminatif** lewat mutasi (uji gagal saat perbaikan dibalik):
  1. T-028 — hash tiruan PBKDF2 dimatikan;
  2. T-029 — penyambungan ulang pump dihapus;
  3. T-029 — titik mulai (`lastEventId`) di-reset saat menyambung ulang;
  4. T-030 — penutupan langganan saat izin dicabut dihapus;
  5. T-032 — drain dimatikan;
  6. T-033 — validasi nyata koneksi pool dimatikan.
- Uji yang **bukan** bermutasi dinyatakan apa adanya di task-nya sendiri (T-033 paralel pool,
  T-034 penjaga regresi Mummy).

## 5. Cara memakai dokumen ini

- Menemukan batas baru saat mengerjakan task → tambahkan baris (dampak, cara deteksi, pemilik), jangan
  simpan di kepala.
- Sebelum deploy → baca §1 dan §2. Yang paling langsung menyangkut deploy: freeze gate (fase 3),
  rollback skema (T-035), latihan deploy (T-013), dan jendela drain 10 detik (T-032).
