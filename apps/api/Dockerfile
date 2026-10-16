# syntax=docker/dockerfile:1
#
# Image build kran-api (spec §21.4 #7). `deploy-vps.sh` tidak menjalankan image ini sebagai
# kontainer: ia `podman create` lalu `podman cp /usr/local/bin/kran-api` untuk mengambil biner
# native-nya, lalu menjalankannya sebagai unit systemd.
#
# KONTEKS BUILD = **ROOT repo**, bukan `apps/api/`. Beda dari pola Skyward (modul Go-nya mandiri di
# `apps/api`), monorepo Nim ini menyebar di root: `shared/`, `modules/`, `apps/`, `tools/`. Karena itu
# `deploy-vps.sh` memakai `podman build -f apps/api/Dockerfile <root>`; kalau konteksnya `apps/api`,
# `COPY` tidak bisa melihat `shared/` sama sekali.
#
# Repo ini belum punya berkas lock dependensi (`kran.lock` disebut skrip deploy tapi belum ada), jadi
# `nimble install -d` mengambil versi yang cocok saat itu juga — biner hasil build karena itu belum
# sepenuhnya dapat direproduksi. Dicatat sebagai item terbuka, bukan disembunyikan.

# ── Build stage ───────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS build

ARG NIM_VERSION=2.2.12

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils git build-essential libpq-dev libpcre3-dev \
    && rm -rf /var/lib/apt/lists/*

# Nim resmi (bukan paket distro yang tertinggal jauh). Versinya disamakan dengan CI:
# `.github/workflows/ci.yml` memakai 2.2.12.
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" -o /tmp/nim.tar.xz \
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
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libpq5 libpcre3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 kran

COPY --from=build /out/kran-api /usr/local/bin/kran-api

USER kran
EXPOSE 8095
ENTRYPOINT ["/usr/local/bin/kran-api"]
