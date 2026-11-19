# Image build kran-web (spec §14.1/§21.4): pohon statis SvelteKit, dilayani nginx.
#
# KONTEKS BUILD = **ROOT repo** (`podman build -f apps/web/Dockerfile .`), sama seperti
# apps/api/Dockerfile: `pnpm-workspace.yaml`, lockfile, dan `packages/` ada di root, jadi konteks
# `apps/web` tidak bisa melihat paket workspace sama sekali.
#
# Dua stage supaya image runtime hanya memuat nginx + hasil build: tanpa node, tanpa pnpm store,
# tanpa sumber. Unit-nya `ops/systemd/kran-web.container` — belum dipasang, hari ini Caddy masih
# melayani direktori `web/` di host.

FROM docker.io/library/node:24-alpine AS builder

# pnpm dari corepack pada versi yang dipatok `packageManager` di package.json, jadi image yang
# dibangun di sini dan image yang dibangun CI menyelesaikan lockfile dengan cara yang sama.
RUN corepack enable

WORKDIR /src

# Manifest + paket workspace dulu: perubahan di apps/web saja memakai ulang lapisan ini alih-alih
# memasang ulang seluruh dependensi.
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY packages/ ./packages/
COPY apps/web/package.json apps/web/

# `@kran/web...` = paketnya sendiri plus dependensi workspace-nya (@kran/ui, @kran/api-client).
RUN pnpm install --frozen-lockfile --filter @kran/web...

COPY apps/web/ ./apps/web/

# `adapter-static` + `fallback: "index.html"` (vite.config.ts) menulis ke `build/`: satu index.html
# plus `_app/immutable`, bukan satu `.html` per rute.
RUN pnpm --filter @kran/web build

# Isi berbeda per commit: dua commit tidak pernah menghasilkan image yang sama, dan /healthz
# menyebut revisi yang menjawab.
ARG GIT_REV=dev
RUN printf '{"rev":"%s","part":"web"}\n' "$GIT_REV" > apps/web/build/healthz

FROM docker.io/library/nginx:1.30.7-alpine

COPY apps/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /src/apps/web/build/ /usr/share/nginx/html/

EXPOSE 8080
