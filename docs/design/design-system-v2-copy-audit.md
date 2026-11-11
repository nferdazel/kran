# Copy audit — design system v2 (shell + states)

Status: read-only audit, 10 Nov 2026. No tracked file was changed; every key and sentence below
was read from the repository, not invented from the spec.
Sources: `packages/i18n/messages/{id,en}.json` (1047 keys per locale),
`packages/ui/src/components/*.svelte`, `apps/web/src/routes/app/+layout.svelte`,
`.local/redesign/design-system/SPEC.md` §2-§4, `docs/design/04-a11y-and-copy.md` §5-§8,
`docs/DOMAIN.md`, `DESIGN.md` §9.

## 0. Verdict

- **The shell needs 3 new shared keys, not a new catalogue.** Of its 26 elements, 25 reuse an
  existing key (two with corrected usage) and one needs a per-screen label when that screen lands.
  The 3 shared gaps are drawer/dialog controls and one filter action.
- **The state problem is coverage, not vocabulary.** Only three empties are actually wrong:
  `loans` (a no-match sentence with no no-data sibling), `ledger` (names journals on a balance
  screen), and `vault` (ignores its own status filter). The other screens are covered by per-cause
  copy plus `error_generic`; adding a generic `<screen>_error` there would be a downgrade. No screen
  needs a generic "Belum ada data" key — inventing one is the defect `docs/design/04` §7 warns about.
- **Three real copy conflicts found**, and they are not cosmetic: the ledger's empty sentence names
  the wrong object (journals on a balance screen), `loans_empty` is a no-match sentence with no
  no-data sibling, and the navigation still ships `Vault kas` / `Teller`, which `DOMAIN.md` bans.
- **`MAIN MENU` / `FUNCTIONS` is not adopted.** SPEC §2 took those words from the reference image;
  the approved mockup and `lib/app/nav.ts` both use four domain groups. Details in §4.1.

Counts: shell 25 reuse + 1 per-screen label + 3 new shared keys. States: 2 new keys, 2 rewrites,
1 rename needed now; 5 more keys are conditional on features that do not exist yet. Terminology
conflicts: 3. Banned-term violations already shipped: 77 id strings across 7 terms (not fixed here).

## 1. Shell strings

`Where` names the component that renders the string, not the file that passes it.

| # | Element | Key | id | en | Where | Status |
|---|---|---|---|---|---|---|
| 1 | Skip link | `common_skip_to_content` | Lewati ke konten utama | Skip to main content | AppShell | reuse |
| 2 | Sidebar nav landmark | `common_nav_label` | Navigasi utama | Primary navigation | Sidebar (`<nav aria-label>`) | reuse |
| 3 | Brand title | `common_brand_short` | KRAN | KRAN | Sidebar | reuse |
| 4 | Brand subtitle | `app_sidebar_subtitle` | Terminal konsol | Console terminal | Sidebar | reuse, wording flagged (§6.10) |
| 5 | Group: cash | `common_nav_group_cash` | Kas | Cash | NavGroup | reuse |
| 6 | Group: members | `common_nav_group_members` | Anggota & simpanan | Members & savings | NavGroup | reuse |
| 7 | Group: ledger | `common_nav_group_ledger` | Buku besar | Ledger | NavGroup | reuse |
| 8 | Group: admin | `common_nav_group_admin` | Pengaturan | Settings | NavGroup | reuse |
| 9 | Nav item label | `common_nav_*` (10 keys) | Teller, Vault kas, Buku besar, … | Teller, Cash vault, Ledger, … | NavItem | reuse, 2 labels violate DOMAIN (§4.2) |
| 10 | Menu button | `common_menu_toggle` | Buka navigasi | Open navigation | Topbar (`aria-expanded` carries state) | reuse |
| 11 | Breadcrumb landmark | `common_breadcrumb_label` | Jejak navigasi | Breadcrumb | Topbar (`<nav aria-label>`) | reuse |
| 12 | Breadcrumb root | `common_brand_short` | KRAN | KRAN | Topbar | reuse (usage change, §4.3) |
| 13 | Breadcrumb current | the screen's own nav key | Buku besar | Ledger | Topbar | reuse |
| 14 | Page h1 | `<screen>_title` (e.g. `ledger_title`) | Saldo buku besar, Pinjaman, … | Ledger balances, Loans, … | PageHeader | reuse |
| 15 | Page intro | `<screen>_intro` | Saldo per akun untuk periode terpilih. … | Balances per account for the selected period. … | PageHeader | reuse |
| 16 | Page meta | `common_business_date_label` + value | Tanggal bisnis | Business date | PageHeader `meta` | reuse (value is data, never translated) |
| 17 | Page meta, value absent | `common_business_date_unknown` | belum tersedia | unavailable | PageHeader `meta` | reuse — key ships today in the root layout header |
| 18 | Toolbar search name | `<screen>_filter_label` | — (first needed when a filter bar lands) | — | Toolbar `label` with `search` | **new, per screen** (§4.4) |
| 19 | Toolbar existing example | `params_search_label` | Cari parameter aktif | Search active parameters | Toolbar on `/app/params` | reuse as the pattern |
| 20 | Toolbar actions | `<screen>_*` (e.g. `ledger_reload`, `ledger_print`) | Muat ulang, Cetak | Reload, Print | Toolbar children (today in each page's local header) | reuse |
| 21 | Sidebar user | `app_signed_in_as` | Masuk sebagai {name} | Signed in as {name} | Sidebar footer | reuse |
| 22 | Sidebar role | `app_roles_label` + role value | Peran | Role | Sidebar footer (label exists; value is data) | reuse — key ships today as a section label on `/app/params`, the footer usage is new |
| 23 | Change password | `app_change_password` | Ganti kata sandi | Change password | Sidebar footer | reuse |
| 24 | Sign out | `app_logout` | Keluar | Sign out | Sidebar footer | reuse |
| 25 | Palette heading / search / hint | `palette_heading`, `palette_search_label`, `palette_hint` | Palet perintah, Cari perintah, … | Command palette, Search commands, … | app layout dialog | reuse |
| 26 | Palette no-match | `palette_empty` | Tidak ada perintah yang cocok. | No matching command. | app layout dialog | reuse (correct no-match sentence) |

New shell keys, with the exact copy proposed:

| Key | id | en | Used for | Why it cannot reuse |
|---|---|---|---|---|
| `common_close` | Tutup | Close | Drawer close button, dialog close button | The word already appears twice for unrelated controls (`users_close` collapses a row, `ledger_admin_close` starts a period close), so neither can be adopted as the shared control |
| `common_open_detail` | Lihat detail | View detail | Drawer trigger on a table row | Same sentence already exists as `dayclose_open_detail`; the shared key is the pattern, `dayclose_open_detail` migrates when T-290 touches that row |
| `common_filter_clear` | Hapus filter | Clear filter | Action inside every no-match empty | No "clear filter" string exists in either catalogue today |

Deliberately **not** added:

- `common_menu_close` / "Tutup navigasi": the accessible name stays constant and `aria-expanded`
  carries open/closed. Two names on one button confuse screen-reader users more than they help.
- `common_loading` / `common_error`: `app_loading` ("Memuat data…") and `app_error` ("Gagal memuat
  data.") already are the route-level pair. A second generic pair under `common_` would be a
  duplicate with a different prefix.
- `common_empty` / "Belum ada data": banned by `docs/design/04` §7 — under an active filter it is a
  false statement about the cooperative. Every empty is screen-specific.

## 2. State copy (loading, empty×3, error, retry, drawer)

### 2.1 Naming rules (locked for T-286…T-292)

`<screen>_loading`, `<screen>_error`, `<screen>_error_<cause>`, `<screen>_denied`,
`<screen>_locked`, `<screen>_empty`, `<screen>_empty_no_match`, `<screen>_detail_<state>`.
`<screen>` is the namespace already used by `docs/design/04` §8 (`teller`, `vault`, `dayclose`,
`ledger`, `loans`, `accounts`, `products`, `params`, `users`, `print`, `statement`, `common`,
`error`, `app`). All keys satisfy `tools/i18ncheck` `validKeyShape` (lowercase snake, ≥2 segments).

Rules that follow from the copy contract:

1. `<screen>_empty` is **only** first-run / nothing exists yet. It must name the object and the
   next action: "Belum ada pinjaman. Ajukan pinjaman pertama."
2. `<screen>_empty_no_match` is **only** an active filter or search with zero results, and must
   offer `common_filter_clear`: "Tidak ada pengguna yang cocok."
3. `<screen>_denied` is a permission fact, not an error: say what is missing and who can grant it.
4. `<screen>_error` is a **load** failure of the screen's main data (what failed + what to do).
   Action and field failures keep `<screen>_error_<cause>`.
5. Retry and reload are different actions and different words: **Coba lagi** = repeat the request
   (`app_retry`); **Muat ulang** = rebuild the page (`<screen>_reload`). Never swap them.
6. Loading copy ends with an ellipsis and names the object: "Memuat parameter…", not "Loading".
7. Empty is silent (`EmptyState` is static, no `role="status"`); loading is `role="status"` with
   `aria-busy` on the region; error is announced once (§3 of `docs/design/04`).

### 2.2 Coverage matrix (list screens)

✅ exists and usable · ⚠️ exists but misnamed / wrong sentence · ❌ missing.

| Screen (K) | no-data | no-match | loading | load error | denied |
|---|---|---|---|---|---|
| `/app/ledger` (K-04) | ⚠️ `ledger_empty` says "Belum ada jurnal…" on a balance screen | ⚠️ `ledger_filter_empty` → rename `ledger_empty_no_match` | ✅ `ledger_loading` | ✅ `ledger_error` | ✅ `ledger_denied` |
| `/app/loans` (K-12/13/15) | ❌ | ⚠️ `loans_empty` ("Tidak ada pinjaman yang cocok") is the no-match sentence | ✅ `loans_loading` | ✅ `loans_error` | ✅ `loans_denied` |
| `/app/vault` (K-02) | ✅ `vault_requests_empty` | ❌ (the status filter exists, the sentence does not change with it) | ✅ `vault_loading` | ⚠️ per-cause via `vaultProblemMessage`, fallback `error_generic` — no single key, and that is a valid choice | ✅ `vault_denied` |
| `/app/products` (K-20) | ✅ `products_empty` | conditional (no filter control today) | ✅ `products_loading` | ✅ `products_error` | ❌ nav gates the link; a direct URL would show a generic error, not a deny |
| `/app/params` (K-19) | ✅ per section (`params_active_empty`, `params_pending_empty`, `params_end_requests_empty`) | ✅ `params_search_empty` | ⚠️ `app_loading` by design (multi-section page) | ⚠️ `app_error` by design | ⚠️ inline panels (`app_denied_params`, `app_denied_audit`) rather than a screen deny |
| `/app/users` (K-18) | ✅ `users_empty` | conditional (no search control today) | ✅ `users_loading` | ⚠️ per-cause via `userProblemMessage`; no single key, and that is a valid choice | ✅ `users_denied` |
| `/app/dayclose` (K-03) | ✅ `dayclose_history_empty`, `dayclose_tasks_empty`, `dayclose_detail_empty` | n/a (no filter) | ✅ ×3 | ⚠️ `error_generic` fallback, per-cause copy for actions — valid choice | ✅ `dayclose_denied` |
| `/app/accounts/open` (K-08) | ✅ `accounts_product_empty` (no active product version) | ✅ `accounts_member_empty` (no matching party — wording violates §6.3) | ✅ section-level (`accounts_product_loading`) | ⚠️ `accounts_error` is an action failure ("Rekening tidak bisa dibuka"), not a load failure | ✅ `accounts_denied` |
| `/login` (K-22) | n/a | n/a | ✅ `login_submitting` | n/a (submit failure: `login_error`) | n/a |
| `/app/print/*` (K-23/24) | ✅ `statement_empty` | n/a | ✅ `print_loading` | ✅ `print_error` + `print_retry` | ✅ `print_denied` |

Forms (K-01, K-08, K-21) render five form states (default, invalid, submitting, failure, success),
not the five list states; that set is already covered by `<screen>_error_<cause>` and
`<screen>_submitting` / `<screen>_*ing` on each screen. Drawers get `open` (content), `loading`
(`<screen>_detail_loading`) and `error` (`<screen>_detail_error`).

### 2.3 New and changed keys for states

**Needed now** — a screen renders the state today and the copy is wrong or missing:

| Key | id | en | Screen | Change |
|---|---|---|---|---|
| `loans_empty` | Belum ada pinjaman. Ajukan pinjaman pertama. | No loans yet. Submit the first loan. | loans | rewrite: today's value is the no-match sentence |
| `loans_empty_no_match` | Tidak ada pinjaman yang cocok. | No matching loans. | loans | new: takes today's `loans_empty` value |
| `ledger_empty` | Belum ada akun bersaldo pada periode ini. | No account has a balance in this period. | ledger | rewrite: today's sentence names journals on a balance screen |
| `ledger_filter_empty` → `ledger_empty_no_match` | Tidak ada akun pada kategori ini. | No accounts in this category. | ledger | rename, copy unchanged |
| `vault_empty_no_match` | Tidak ada pengajuan berstatus {status}. | No request has status {status}. | vault | new: the status filter exists, the sentence ignores it today |

`ledger_empty_hint` ("Posting jurnal, atau pilih periode lain.") carries the same wrong object; it
needs a period action ("Pilih periode lain.") or deletion, not a filter action — that empty has no
filter. Wait for the period control decision in T-288 (open question 2).

In `vault_empty_no_match`, `{status}` must be the translated `statusLabel(status)` the filter already
uses, never the raw enum from the server.

**Conditional** — only when the feature that uses them lands (a key before its use is an orphan and
fails `./task check-fast`):

| Key | id | en | Lands with |
|---|---|---|---|
| `ledger_detail_heading` | Detail jurnal | Journal detail | T-290 drawer |
| `products_empty_no_match` | Tidak ada produk untuk filter ini. | No products match this filter. | a filter control on `/app/products` |
| `users_empty_no_match` | Tidak ada pengguna yang cocok. | No users match your search. | a search control on `/app/users` |
| `products_denied` | Akun Anda tidak punya izin membaca katalog produk. | Your account cannot read the product catalogue. | a screen-level deny on `/app/products` |
| `params_denied` | Akun Anda tidak punya izin membaca parameter. | Your account cannot read parameters. | if a whole-page deny replaces the inline panels |

**Not needed, checked in code rather than assumed:**

- `params_loading` / `params_error`: `/app/params` uses `app_loading` and `app_error` on purpose; it
  is a multi-section page, not one region.
- `users_error` / `vault_error`: both map failures per cause (`userProblemMessage`,
  `vaultProblemMessage`) with a generic fallback. One load-error key would be a copy downgrade.
- `teller_error`: the session load already has `teller_session_blocked_error` and
  `teller_session_blocked_loading`.

### 2.4 Component mapping

| Component | Prop | Key rule |
|---|---|---|
| `LoadingState` (new) | `label` | `<screen>_loading`; `app_loading` only for a whole multi-section page; `role="status"`, `aria-busy` on the replaced region |
| `EmptyState` (change) | `kind="no-data"` | `<screen>_empty` |
| | `kind="no-match"` | `<screen>_empty_no_match` + action `common_filter_clear` |
| | `kind="denied"` | title `app_denied_heading` + body `<screen>_denied`; action `error_page_back` |
| `ErrorState` (new) | `title`, `body`, `retryLabel` | `<screen>_error` where it exists, else the per-cause sentence with `error_generic` fallback; retry label `app_retry` |
| `Drawer` (new) | `aria-labelledby` | `<screen>_detail_heading`; close button `common_close`; trigger `common_open_detail` |
| `Toolbar` | `label` with `search` | `<screen>_filter_label` (pattern: `params_search_label`) |

## 3. Keys worth reusing (do not duplicate)

| Existing key | Reuse for | Note |
|---|---|---|
| `app_loading` / `app_error` | route-level loading and load failure | never inside a named region; screens use `<screen>_loading` / `<screen>_error` |
| `app_retry` | every "Coba lagi" | `teller_retry` and `print_retry` are the same string; migrate them when those screens are touched, do not add a fourth |
| `app_denied_heading` | denied empty title ("Akses terbatas") | body stays screen-specific |
| `error_page_back` | denied action ("Kembali ke area kerja") | the only existing "back to workspace" sentence |
| `error_generic` | last-resort failure body | shorter than `<screen>_error`; prefer the screen key |
| `common_table_region` | `DataTable` region name (`Tabel: {name}`) | already used by 10 tables across 6 screens; keep it as the one region-name pattern |
| `common_business_date_label` and `common_business_date_unknown` | page meta | already the only wording for business date |
| `params_search_label` | toolbar search label on `/app/params` | the reference sentence for new `<screen>_filter_label` keys |
| `dayclose_open_detail` | any drawer trigger that does not exist yet (today it is the dayclose row action) | same sentence as `common_open_detail`; migrate it when T-290 touches that row, do not copy it |
| `users_close` | a row collapse label | it means "collapse this row", not "close the drawer"; do not merge it with `common_close` |

## 4. Terminology decisions (locked)

One word per thing, in id and en. Everything here is already in `DOMAIN.md` or
`docs/design/04` §5; this list is the subset the shell and the five states need.

| Concept | id | en | Locked because | Conflict found |
|---|---|---|---|---|
| Branch vault | Kas besar | Branch vault | `DOMAIN.md` bans `vault` in operator copy | `common_nav_vault` = "Vault kas", `vault_title` = "Vault kas", 19 id strings say "vault" (`vault_balance_label`, `teller_session_error_insufficient_vault`, …) |
| Cashier | Kasir | Teller | `DOMAIN.md`: `teller` is a code identifier, not Indonesian copy | `common_nav_teller` = "Teller", `teller_title` = "Teller", 9 id strings use "teller" (7 operator sentences) |
| Empty vs no-match | (two sentences, never one) | (two sentences) | `docs/design/04` §7: an empty under a filter is a false statement | `loans_empty` is a no-match sentence; `ledger_empty` describes journals |
| Retry vs reload | Coba lagi / Muat ulang | Try again / Reload | Two different operator actions | both exist; do not normalise them into one |
| Filter action | Hapus filter | Clear filter | No existing wording; one verb for the action | new key `common_filter_clear` |
| Drawer close | Tutup | Close | Native dialog and drawer controls share one word | no drawer/dialog close key exists; `users_close` is a row-collapse label, not this control |
| Detail trigger | Lihat detail | View detail | Already the shipped sentence | `dayclose_open_detail` duplicates it |
| Breadcrumb root | KRAN | KRAN | The product name in a 12 px crumb, not the tagline | today `common_app_title` ("KRAN — Sistem Koperasi & Bank") is used in the root layout |
| Period | Periode | Period | `DOMAIN.md` bans batch/cutoff/cycle | no conflict in the shell |

### 4.1 `MAIN MENU` / `FUNCTIONS` — not adopted

SPEC §2 lists the reference image's labels. The approved mockup (`.local/redesign/mockup/index.html`,
lines 380-386) renders four domain groups: Kas, Anggota & simpanan, Buku besar, Pengaturan — exactly
the keys in `lib/app/nav.ts`. Adopting MAIN MENU/FUNCTIONS would either nest the four groups under
two generic ones (a third navigation level for no information gain) or drop the domain grouping
that makes the menu scannable. **Decision: keep the four domain labels, no new keys.** SPEC §2's
wording is treated as the reference's example, not a requirement.

### 4.2 Navigation labels that violate `DOMAIN.md`

`Vault kas` → **Kas besar** (id), `Teller` → **Kasir** (id); en stays "Cash vault" / "Teller".
This is already recorded as a conflict in `docs/design/04` §11.3, so it is not a new opinion. It is
**not** fixed here: renaming touches `common_nav_*`, `vault_title`, `vault_*` and several tests, and
belongs in its own ticket, not in a read-only audit.

### 4.3 Breadcrumb root

Pass `common_brand_short` ("KRAN") as the first crumb instead of `common_app_title`. The tagline is
already in `<title>` and is too long for an 11 px crumb at 360 px. No new key.

### 4.4 Toolbar search label

`Toolbar` requires `label` when `search` is set; the copy is per screen because the landmark must
name what is searched ("Saring akun", "Cari pengguna"). `params_search_label` is the shipped example.
No generic key: "Saring daftar" tells a screen-reader user nothing about which list.

### 4.5 "Tutup" is not one thing

`Tutup` closes a panel; `Tutup periode`, `Tutup kas`, `Tutup buku` are business acts.
The shared control key is `common_close` (drawer, dialog). It must not be reused for a business
action, and a business action must not fall back to the bare word:

- `users_close` ("Tutup") is the collapse label of an expanded row, paired with `users_manage`
  ("Kelola"). Not a drawer control; no change needed now.
- `ledger_admin_close` ("Tutup") is a **row action that starts closing a period** and is followed by
  a confirm form whose submit is `ledger_admin_close_submit` ("Tutup periode"). A bare "Tutup" on a
  period row reads as "close this panel", not "close the books". **Recommendation: "Tutup periode…"
  (ellipsis, because it opens a confirm), and keep the submit as "Tutup periode".** This is a copy
  fix on `/app/ledger/admin` when that screen is next touched, not a new key.

## 5. Never translated, and placeholders

**Data, not copy** (never a key): person names, member numbers, account numbers, account codes
(`101.2`), journal references, amounts, business dates and timestamps, branch names, server status
and role codes, permission codes, file names, narration the operator typed.
Also literal: **KRAN**, **IDR** (currency unit in a header), keyboard keys (`Ctrl+K`, `Esc`, `Tab`,
`Enter`), and **SHU / RAT / PB**, which are expanded once per document and never translated away.

**Placeholders** use `{name}` only — never positional. In the shell and state set: `{name}`
(`app_signed_in_as`), `{status}` (new `vault_empty_no_match`), `{count}` (plural pair
`common_home_accounts_one/_other`), plus `{ref}`, `{date}`, `{period}`, `{permission}` in error
copy. Every placeholder must exist in both locales with the same name; `tools/i18ncheck` enforces it.

**Copy budgets** (`docs/design/04` §8): label ≤24 chars, button ≤24, hint ≤90, error ≤160,
empty ≤120 plus one action. All proposed strings above fit; the longest is
`products_denied`, 50 characters in id and 47 in en.

## 6. Pre-existing violations found (flagged, not fixed)

Read with `packages/i18n/messages/id.json`; counts are exact for this commit (`feat/design-system-v2`),
matched case-insensitively on the id value.

1. **`vault` in id copy — 19 keys.** `common_nav_vault`, `vault_title`, `vault_intro`,
   `vault_balance_label`, `vault_denied`, `vault_loading`, `vault_read_only`,
   `vault_source_hint`, `teller_session_error_insufficient_vault`,
   `teller_session_error_vault_missing`, `dayclose_code_303`, `perm_teller_vault_*`.
2. **`run` in id copy — 32 keys.** `dayclose_detail_heading` ("Detail run"),
   `dayclose_detail_run_id` ("Id run"), `dayclose_active_run_label`, `dayclose_confirm_run_title`,
   `dayclose_notice_run_stopped`, `dayclose_history_intro`, … `DOMAIN.md` and `DESIGN.md` §9 both
   ban it for the operator.
3. **`party` in id copy — 7 keys.** `accounts_branch_label` ("Cabang (dari party)"),
   `accounts_member_change` ("Ganti party"), `accounts_member_empty` ("Party yang cocok …"),
   `accounts_member_error`, `accounts_error_party_not_active`, `accounts_error_branch_mismatch`,
   `accounts_member_search_hint`. `DOMAIN.md`: the operator sees Anggota.
4. **`uuid` in id copy — 3 keys.** `ledger_admin_error_journal_invalid`, `ledger_admin_reverse_journal_hint`,
   `loans_error_party_invalid`.
5. **`CIF` in id copy — 2 keys.** `accounts_member_search_label` ("Cari nama atau CIF"),
   `accounts_member_selected` ("Dipilih: {name} ({cif})").
6. **`ID rekening` in id copy — 6 keys.** `teller_account_id_hint`, `teller_account_none_hint`,
   `teller_error_account_invalid`, `teller_error_account_required`,
   `teller_error_destination_invalid`, `teller_not_found`. Should be "Nomor rekening".
7. **`teller` in id copy — 9 keys, 7 of them operator sentences.** `common_nav_teller`,
   `teller_title`, `dayclose_code_301`, `dayclose_code_302`, `teller_session_error_not_owned`,
   `loans_accounts_forbidden`, `vault_read_only`; the other two (`role_teller`,
   `perm_teller_transaction_post`) are display labels for a role and a permission.
8. **`vault_read_only` leaks permission codes to the operator**: "…butuh teller.vault.submit,
   keputusan butuh teller.vault.approve." `docs/design/04` §5/§8 ban codes as visible copy; the
   sentence must name the action and the person, not the code.
9. **`ledger_table_help` promises behaviour that does not exist**: "tombol panah berpindah sel …
   Home/End ke tepi baris". `DataTable` has no cell focus and no roving arrow keys. Either the
   component gains them in T-288 or the sentence is wrong; copy must not claim an unbuilt feature.
10. **`app_sidebar_subtitle` = "Terminal konsol"** reads like a developer label. Suggested
    "Konsol operasional" / "Operations console"; low risk, Fajar's call.

`tools/i18ncheck` does **not** scan for banned terms yet (`docs/design/04` §10 proposes it), so none
of items 1-7 will fail CI today. They are not introduced by the design system work.

## 7. Constraints for whoever implements this

1. **A key lands in the same PR as its first use.** `tools/i18ncheck` fails on orphan keys; adding
   the catalogue first and the component later turns `./task check-fast` red.
2. **One key = one sentence.** Renames in §2.3 are key-only; do not "improve" the id copy of an
   unrelated screen in the same commit.
3. **No generic empty.** A new screen without a no-data sentence is a ticket, not a fallback string.
4. **Reuse list is binding**: do not create `common_close_2`, `app_error_generic`, or a second
   "Coba lagi".
5. **Delete the old key after the last use.** A renamed key left in the catalogue is an orphan and
   fails the gate.
6. **The banned-term sweep (§6) is its own ticket** with its own evidence; it changes visible copy
   on about seven screens, so it needs the same axe/keyboard pass as any other copy change.

## 8. Verification and open questions

Verified by reading, not by running the app:

- 1047 keys in each locale; every key named as "exists" above was read from `id.json` and `en.json`.
- `tools/i18ncheck` enforces key shape, placeholder parity across locales, and no orphan keys;
  it does not enforce banned terms or hardcoded text.
- `EmptyState` today accepts `title`/`description`/`action` and has no `kind`; `LoadingState`,
  `ErrorState`, `Drawer`, `TotalsRow` do not exist yet (SPEC §3). The mapping in §2.4 is the target
  API, not the current one.

Open, for Fajar (design) and Intan (lead), not decided here:

1. `common_table_scroll_hint` — do we show a visible "Geser tabel…" hint at 360/200 %, or keep it
   screen-reader-only? The mockup shows it; `docs/design/04` requires the scroll container, not the
   hint. If yes: id "Geser tabel untuk melihat kolom lainnya.", en "Scroll the table to see the
   other columns."
2. `ledger_empty_hint` — replace with a period-specific hint ("Pilih periode lain.") or drop it?
   It depends on whether the period control stays above the table (T-288). It must not become
   `common_filter_clear`: this empty has no filter.
3. Whether the §6 banned-term sweep is P6 work or its own phase ticket; it is the largest visible
   copy change on the list and should not ride along with the shell.
