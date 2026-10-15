# config.nims — path modul repo ini untuk **perkakas** Nim (nimlangserver/nimsuggest di editor,
# `nim check` cepat dari direktori mana pun).
#
# Sengaja hanya daftar path, tanpa flag build lain:
#   - `./task` tetap sumber kebenaran flag build (docs/DECISIONS.md D-001), dan flag di sana
#     (mis. `--mm:orc`, `--threads:on` untuk test) **tidak** digandakan di sini supaya berkas ini
#     tidak bisa mengubah perilaku kompilasi — hanya membuat perkakas melihat hal yang sama;
#   - tanpa berkas ini, editor hanya bisa melaporkan `cannot open file: platform-lib/db/pool`
#     dan galat domino di bawahnya, karena impor repo ini diselesaikan lewat `-p:` dari `./task`.
#
# Path ditulis absolut dari letak berkas ini, sebab perkakas editor tidak menjalankan Nim dari root
# repo. Cara memakai: `nimsuggest --stdin <berkas>` (lihat AGENTS.md — "Pastikan definisi dengan
# nimsuggest").

import std/[os]

let root = currentSourcePath().parentDir

for dir in ["shared", "modules", "apps", "tools", "tools/dbtools"]:
  switch("path", root / dir)
