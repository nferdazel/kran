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

## E-001 — Keputusan ADR-002: HTTP server Nim (Mummy vs Prologue)

- Tanggal: 2026-10-13
- Task: T-014 (memblokir T-008 contract test, T-009 SSE, T-012 end-to-end)
- Kategori: ADR terbuka (spec §8 butir 1; spec §25 ADR-002 = "Perlu benchmark")
- Fakta: `shared/platform-lib/http` harus membungkus server terpilih; tanpanya handler, SSE hub,
  dan contract test tidak bisa dikunci. Spike T-014 belum dijalankan saat entri ini dibuat.
- Yang dibutuhkan dari manusia: pilih satu server (rekomendasi ada di dokumen spike) agar
  `shared/platform-lib/http` bisa dikunci dan T-008/T-009 dilanjutkan.
- Status: TERBUKA
