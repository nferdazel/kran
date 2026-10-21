# Rotasi sandi role DB (O-069)

Insiden 17 Okt 2026: rotasi dilakukan ad hoc, `sed` menggandakan prefix `KRAN_DATABASE_URL=`
(karena `${OLD_URL}` sudah memuat nama kunci), API gagal start ±1 menit. Prosedur ini menggantikan
cara itu. **Jangan pernah** menaruh sandi di argumen perintah (argv terlihat di `ps`).

## Sebelum mulai

- Catat revisi + `/readyz` saat ini; pastikan tidak ada deploy berjalan.
- Siapkan dua terminal: satu untuk DB (`podman exec qouver-postgres psql -U qouver`), satu untuk app.
- Sandi baru: buat dengan `openssl rand -base64 32`, **tanpa** karakter yang merusak URL (`+ / =`
  boleh, tetapi hindari `@ : / ? #` supaya parsing URL tidak berubah) — atau URL-encode.
- Jangan mencetak sandi ke log shell; gunakan `read -s`.

## Langkah

```bash
# 1. Ganti sandi role aplikasi (sandi lewat stdin, bukan argv)
podman exec -i qouver-postgres psql -U qouver -d postgres -c \
  "ALTER ROLE kran_app PASSWORD :'pw'" <<< "\\set pw 'SANDI_BARU'"
# atau interaktif:
podman exec -it qouver-postgres psql -U qouver -d postgres -c "\\password kran_app"

# 2. Siapkan baris env baru TANPA sed dari baris utuh (hindari prefix ganda)
cd /srv/qouver/apps/kran
cp env/kran-prod.env env/kran-prod.env.bak-$(date +%Y%m%d-%H%M)
python3 - <<'PY'
import re, os
p = "env/kran-prod.env"
pw = os.environ["NEW_DB_PASSWORD"]          # ekspor lewat `read -s`, jangan literal
lines = open(p).read().splitlines()
out = []
for line in lines:
    if line.startswith("KRAN_DATABASE_URL="):
        url = line.split("=", 1)[1]
        url = re.sub(r"(://[^:]+:)[^@]*(@)", r"\g<1>" + pw + r"\g<2>", url)
        line = "KRAN_DATABASE_URL=" + url
    out.append(line)
open(p, "w").write("\n".join(out) + "\n")
PY
chmod 600 env/kran-prod.env

# 3. Restart dan verifikasi (keduanya wajib)
systemctl --user restart kran-api kran-worker
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/readyz   # harapan 200
KRAN_DATABASE_URL="$(grep '^KRAN_DATABASE_URL=' env/kran-prod.env | cut -d= -f2-)" \
  LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --check             # harapan exit 0

# 4. Hapus cadangan env hanya setelah langkah 3 hijau
rm env/kran-prod.env.bak-*
```

## Bila gagal

- `/readyz` ≠ 200: kembalikan env dari cadangan, restart, verifikasi; **jangan** menghapus cadangan.
- `--check` gagal autentikasi: berarti sandi DB dan URL tidak sinkron — ulangi langkah 1–2, jangan
  menebak isi baris URL.
- Catat waktu, role, dan hasil di `docs/PROGRESS.md`; jangan menulis sandi.
