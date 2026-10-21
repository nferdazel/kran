# Runbook — enkripsi field-level (KEK, DEK, blind index)

Mekanisme: `shared/platform-lib/crypto/fieldcrypto.nim` (spec §18.2; keputusan `docs/adr/017-field-level-encryption.md`,
`docs/DECISIONS.md` D-048). **Area kriptografi — HUMAN-REVIEW-REQUIRED** sebelum dipakai untuk data
anggota nyata (AGENTS.md §8).

Ringkas model: **KEK** di berkas terpisah (mode 600, env `KRAN_KEK_FILE`) → **DEK diturunkan per
tabel** (`HMAC-SHA256(KEK, "kran:dek:v1:" || tabel)`) → ciphertext **AES-256-GCM** berbentuk
`kran:enc:v1:<kid>:<nonce_b64url>:<ciphertext||tag_b64url>` (AAD = nama tabel). Pencarian kesamaan
lewat **blind index** `HMAC-SHA256(HMAC-SHA256(KEK,"kran:bidx:v1:"||tabel), nilai)` heksadesimal.

> Semua perintah di bawah adalah contoh **di repo/laptop**. Runbook ini **tidak** membuat berkas
> rahasia di server; pembuatan berkas KEK produksi dilakukan manual oleh pemilik di server.

## 1. Membuat berkas KEK

Berkas KEK berisi satu atau beberapa kunci berversi, satu per baris: `<kid>:<base64 32 byte>`.
Baris kosong dan `#…` diabaikan.

```
umask 077
printf 'v1:%s\n' "$(openssl rand -base64 32)" > /srv/qouver/apps/kran/env/kran-kek.key
chmod 600 /srv/qouver/apps/kran/env/kran-kek.key
```

- `kid` = penanda versi kunci (`v1`, `v2`, …), huruf/angka/`_`/`-`/`.` saja.
- Kunci harus tepat **32 byte** setelah base64-decode.
- Mode **wajib 600** (hanya pemilik). Berkas yang bisa dibaca grup/orang lain **ditolak** saat start.

## 2. Menyimpan berkas (inti O-006)

- Berkas KEK **TIDAK** ikut backup DB yang sama. Simpan di tempat terpisah, terenkripsi/offline
  (rencana `sops`/`age` sebelum data pilot nyata — D-046 butir 12).
- **Berkas hilang = data terenkripsi tidak bisa dibaca kembali.** Tidak ada jalur pemulihan.
- Jangan menaruh berkas KEK di dalam repo, image, atau backup DB.

## 3. Mengaktifkan

Setel di env proses API/worker, lalu **restart**:

Di host, berkas tetap di `/srv/qouver/apps/kran/env/kran-kek.key` (mode 600). Unit quadlet
me-mount-nya ke dalam container dan **wajib** memetakan uid container ke pemilik berkas:

```
# kran-api.container / kran-worker.container
UserNS=keep-id:uid=10001,gid=10001
Volume=/srv/qouver/apps/kran/env/kran-kek.key:/run/secrets/kran-kek.key:ro,z

# env (kran-prod.env) — path **di dalam container**
KRAN_KEK_FILE=/run/secrets/kran-kek.key
```

Tanpa `UserNS=keep-id`, container berjalan sebagai uid 10001 yang dipetakan ke subuid host →
berkas 600 tidak terbaca dan API menolak start (terbukti saat go-live Fase 1).

Perilaku (tanpa fallback diam-diam, O-056/D-046 butir 6):

| Keadaan | Perilaku |
|---|---|
| `KRAN_KEK_FILE` **kosong** | aplikasi **start** seperti sekarang. Setiap enkripsi/dekripsi menolak dengan `NotConfiguredError` ("enkripsi field belum dikonfigurasi") |
| `KRAN_KEK_FILE` diset & berkas sah | dibaca & divalidasi **saat startup** → siap dipakai |
| berkas hilang / tidak terbaca / rusak / kid tidak sah / mode bukan 600 | **tolak start** (`KekError`) |

Deploy yang sekarang sehat (tanpa kolom terenkripsi) **tidak** perlu menyetel `KRAN_KEK_FILE`.

## 4. Rotasi

- **Kunci baru**: tambahkan baris baru **di bawah** (`v2:…`). **Kunci aktif = entri terakhir**, jadi
  enkripsi baru memakai `v2`; ciphertext lama (`kid` `v1`) tetap terbaca selama `v1` masih ada.
  Jangan menghapus kunci lama sampai semua data dengan `kid` itu sudah di-enkripsi ulang.
- **Rotasi KEK tidak bisa independen per tabel**: DEK terikat KEK. Mengganti/menghapus KEK membuat
  ciphertext lama tidak terbaca kecuali di-re-enkripsi ulang dengan kunci baru (selama kunci lama
  masih ada, baca masih jalan).
- **Rotasi kunci blind index membatalkan indeks**: indeks adalah HMAC dari kunci turunan; setelah
  kunci berubah, indeks lama tidak lagi cocok → perlu **reindex**.
- **JANGAN merotasi KEK selama data identitas (`party.identity_doc.number_bidx`) ada** sampai
  perintah reindex tersedia (O-073). Tanpa reindex, deteksi duplikat NIK gagal-terbuka: tidak ada
  galat, tetapi constraint unik tidak lagi menangkap duplikat. Bila rotasi darurat terpaksa
  dilakukan: (1) re-enkripsi semua ciphertext dengan kunci baru, (2) hitung ulang `number_bidx`
  dari plaintext hasil dekripsi kunci lama, (3) bandingkan jumlah baris + cari duplikat baru,
  (4) baru hapus kunci lama. Langkah 2 belum punya perintah `ctl` — kerjakan manual dengan snapshot
  DB dan catat di `docs/PROGRESS.md`.
- Selalu uji baca (dekripsi + pencarian indeks) sebelum menghapus kunci lama.

## 5. Kontrak pemakaian (Fase 1)

Kerangka untuk `party`/`lending` saat kolom PII mendarat:

1. **Ambil keyring sekali** saat startup (infrastructure), mis. `fieldCryptoFromEnv(envTableFromProcess())`,
   dan pakai keyring itu untuk seluruh permintaan. Jangan membaca berkas KEK per permintaan.
2. **Simpan**: kolom ciphertext bertipe `text`; `enc = encryptField(fc, "<tabel>", nilai)`.
   Nama tabel **wajib** nama tabel nyata dan **stabil** — ia menjadi AAD + pemisah domain kunci;
   mengganti nama tabel tanpa re-enkripsi membuat data tak terbaca.
3. **Cari kesamaan**: kolom blind index `text`; `bidx = blindIndex(fc, "<tabel>", normalizeDigits(nilai))`.
   Untuk NIK/NPWP/no. HP pakai `normalizeDigits` (hanya digit ASCII). Query: `WHERE bidx_col = ?`.
   **Hanya kesamaan** — jangan `LIKE`/rentang di kolom terenkripsi.
4. **Baca**: `decryptField(fc, "<tabel>", enc)`. `DecryptError`/`NotConfiguredError` **jangan
   ditelan** menjadi nilai kosong — permukaan galat yang eksplisit.
5. **Jangan pernah mencatat plaintext/kunci** ke log (log.nim sudah mem-mask nama field sensitif,
   tetapi itu pertahanan kedua — tetap jangan kirim PII ke logger).
6. Kolom boleh **NULL** = belum ada nilai; jangan enkripsi string kosong sebagai pengganti NULL.

## 6. Open item

- **Normalisasi nama/alamat** (Unicode/aturan bisnis) **belum** ditetapkan; `normalizeDigits`
  sengaja hanya untuk field angka. Jangan mengarang normalisasi Unicode — catat sebagai open item
  saat Fase 1 membutuhkannya.
- Manajemen kunci ke depan: `sops`/`age` (O-006) sebelum data pilot nyata.
