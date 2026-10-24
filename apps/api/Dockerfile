# syntax=docker/dockerfile:1
#
# Image build kran-api (spec §21.4 #7). Image ini DIJALANKAN sebagai container oleh quadlet
# `ops/systemd/kran-api.container` (dan `kran-worker.container`). Selain itu `deploy-vps.sh` masih
# `podman create` + `podman cp /usr/local/bin/kran-api` untuk mengambil biner native yang dipakai
# gate-nya sendiri (FREEZE GATE, MIGRATION GATE) — gate itu berjalan di host, sebelum layanan
# di-restart.
#
# KONTEKS BUILD = **ROOT repo**, bukan `apps/api/`. Beda dari pola Skyward (modul Go-nya mandiri di
# `apps/api`), monorepo Nim ini menyebar di root: `shared/`, `modules/`, `apps/`, `tools/`. Karena itu
# `deploy-vps.sh` memakai `podman build -f apps/api/Dockerfile <root>`; kalau konteksnya `apps/api`,
# `COPY` tidak bisa melihat `shared/` sama sekali.
#
# Repo ini belum punya berkas lock dependensi (`kran.lock` disebut skrip deploy tapi belum ada), jadi
# `nimble install -d` mengambil versi yang cocok saat itu juga — biner hasil build karena itu belum
# sepenuhnya dapat direproduksi. Dicatat sebagai item terbuka, bukan disembunyikan.

# Base image dipin **digest** (OPS-9): tag `bookworm-slim` bergerak, sehingga build yang sama bisa
# menghasilkan runtime berbeda tanpa perubahan repo. Digest di bawah = index multi-arch
# `debian:bookworm-slim` per 21 Okt 2026; naikkan bersama review, bukan otomatis.
#   debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
ARG DEBIAN_DIGEST=sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# ── Build stage ───────────────────────────────────────────────────────────────
FROM debian:bookworm-slim@${DEBIAN_DIGEST} AS build

ARG NIM_VERSION=2.2.12
# SHA-256 tarball Nim resmi (dipublikasikan nim-lang.org sebagai `<berkas>.sha256`). Tanpa
# pemeriksaan ini, unduhan toolchain adalah titik masuk supply chain: satu tarball yang ditukar
# menghasilkan biner yang "berhasil build" tetapi bukan kode kita (OPS-9).
ARG NIM_SHA256=7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git build-essential libpq-dev libpcre3-dev \
    && rm -rf /var/lib/apt/lists/*

# Nim resmi (bukan paket distro yang tertinggal jauh). Versinya disamakan dengan CI:
# `.github/workflows/ci.yml` memakai 2.2.12.
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" -o /tmp/nim.tar.xz \
    && echo "${NIM_SHA256}  /tmp/nim.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/nim \
    && tar -xJf /tmp/nim.tar.xz -C /opt/nim --strip-components=1 \
    && rm -f /tmp/nim.tar.xz
ENV PATH="/opt/nim/bin:${PATH}"

WORKDIR /src
# Dependensi dulu supaya lapisan ini bisa dipakai ulang selama kran.nimble tidak berubah.
COPY kran.nimble ./
RUN nimble install -d -y

COPY . .
# Flag build mengikuti `./task` (D-001): `--mm:orc` + `--threads:on` bukan pilihan gaya — pool DB dan
# pump realtime memakai thread, dan `./task test`/`ci` menguji dengan flag yang sama.
RUN nim c -d:release --mm:orc --threads:on --hints:off --out:/out/kran-api apps/api/src/main.nim

# ── Runtime stage ─────────────────────────────────────────────────────────────
# libpq dibuka **saat jalan** lewat dynlib (db_connector), bukan ditautkan saat build — tanpa paket ini
# biner gagal start dengan `could not load: libpq.so.5`. libpcre3 untuk mesin rute Mummy.
FROM debian:bookworm-slim@${DEBIAN_DIGEST} AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libpq5 libpcre3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 kran

COPY --from=build /out/kran-api /usr/local/bin/kran-api

USER kran
EXPOSE 8095
ENTRYPOINT ["/usr/local/bin/kran-api"]
