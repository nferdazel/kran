## Gate pra & pasca-tutup (spec §11.5 langkah 2 & 5, katalog §11.6).
##
## Setiap gate adalah task `daycloser` tersendiri, bukan satu pemeriksaan gabungan: kegagalannya
## harus bisa ditunjuk satu per satu (UI/audit), dan **bukti** hasilnya tersimpan di
## `daycloser.task.metrics` — log hilang, metrik tidak. Komposisi (pool + repo) ada di sini karena
## gate memang melintasi modul: teller, deposit, dan ledger sekaligus.
##
## Aturan yang dipegang:
##   - parameter yang hilang/rusak = gate **gagal** (penutupan tidak boleh dilonggarkan oleh
##     konfigurasi yang belum tersemai);
##   - angka uang dibandingkan lewat `Money`, tidak pernah lewat float;
##   - tidak ada kode akun di kode: daftar akun datang dari parameter DB.

import std/[json, options, strutils]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[dayclose, money, paramkey, result]
import kernel/generated/paramkeys

import platform/domain/scope
import platform/domain/calendar
import platform/infrastructure/[calendar_repo, param_repo]

import party/domain/jsonparam

import daycloser/domain/[registry, types]

import deposit/infrastructure/reconcile_repo
import ledger/domain/[coa, report]
import ledger/infrastructure/[ledger_repo, report_repo]
import teller/infrastructure/[session_repo, vault_request_repo]

type
  GateResult* = object
    ## Hasil satu gate. `metrics` tetap diisi saat gagal: angka yang menyebabkan penolakan adalah
    ## bukti, bukan pelengkap.
    ok*: bool
    code*: string
    message*: string
    metrics*: JsonNode

  GateCheck* = proc(pool: DbPool; ctx: TaskContext): GateResult {.closure.}

const
  ## Batas bawah tanggal: gate menghitung saldo **kumulatif** sampai tanggal tutup, jadi rentang
  ## dimulai sebelum jurnal pertama yang mungkin ada.
  earliestDate = "0001-01-01"

  ## Jumlah id yang ikut disimpan sebagai bukti. Cukup untuk menunjuk masalah, tidak sampai
  ## membengkakkan `task.metrics`.
  evidenceLimit = 20

proc passed(metrics: JsonNode): GateResult =
  GateResult(ok: true, metrics: metrics)

proc blocked(code, message: string; metrics: JsonNode = nil): GateResult =
  GateResult(ok: false, code: code, message: message, metrics: metrics)

proc paramAccounts(pool: DbPool; ctx: TaskContext; key: string): seq[string] =
  ## Daftar akun dari parameter `json` (bukan literal di kode, spec §10).
  pool.withConn(proc(db: DbConn): seq[string] =
    {.cast(gcsafe).}:
      let node = activeValueJson(db, key, ctx.businessDate, lookupFor(institutionScope()))
      stringList(node, key))

proc unknownAccounts(pool: DbPool; ctx: TaskContext; accounts: seq[string]): seq[string] =
  ## Akun parameter yang tidak ada / tidak `ACTIVE`. Tanpa pemeriksaan ini, salah ketik pada
  ## parameter mematikan gate **tanpa galat**: akun fiktif tidak pernah muncul di laporan saldo,
  ## sehingga gate "lulus" karena tidak ada yang diperiksa.
  pool.withConn(proc(db: DbConn): seq[string] =
    {.cast(gcsafe).}:
      for code in accounts:
        let found = coaByCode(db, code)
        if found.isNone or found.get().status != asActive:
          result.add code)

proc signedBalance(line: BalanceLine): Money =
  ## Saldo menurut sifat akun: aset naik di debit, kewajiban/ekuitas naik di kredit. Membaca
  ## `accountType` dari COA, bukan menebak dari kode akun.
  case line.accountType
  of atAsset: line.closingDebit - line.closingCredit
  of atLiability, atEquity: line.closingCredit - line.closingDebit
  of atRevenue: line.closingCredit - line.closingDebit
  of atExpense: line.closingDebit - line.closingCredit

proc tellerSessionsCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Sesi kas harus tutup dan seimbang sebelum buku ditutup (spec §11.6 "Validasi pra-tutup").
  ## Sesi OPEN dari hari sebelumnya ikut dihitung: itu justru keadaan yang paling perlu terlihat.
  let g = pool.withConn(proc(db: DbConn): SessionGate =
    sessionGate(db, ctx.businessDate, evidenceLimit))
  let metrics = %*{"openSessions": g.openSessions, "unbalancedSessions": g.unbalanced,
                   "sessionIds": g.problemIds}
  if g.openSessions > 0:
    return blocked("DAY-301", $g.openSessions & " sesi teller masih OPEN", metrics)
  if g.unbalanced > 0:
    return blocked("DAY-302",
      $g.unbalanced & " sesi teller ditutup dengan kas tidak seimbang", metrics)
  passed(metrics)

proc pendingApprovalsCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Tidak ada pengajuan yang menggantung saat buku ditutup (spec §11.5 #2). Yang diperiksa
  ## adalah perpindahan kas yang menunggu checker; perubahan parameter/produk berstatus DRAFT
  ## bukan transaksi dan tidak menahan penutupan.
  let pending = pool.withConn(proc(db: DbConn): int64 = pendingTopUpCount(db))
  let metrics = %*{"pendingVaultTopUps": pending}
  if pending > 0:
    return blocked("DAY-303",
      $pending & " pengajuan top-up vault belum diputuskan", metrics)
  passed(metrics)

proc suspenseCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Akun selisih/suspense harus nol sebelum tutup (spec §11.5 #2 "suspense = 0").
  let accounts = paramAccounts(pool, ctx, keyString(P_daycloser_precheck_suspense_accounts))
  if accounts.len == 0:
    return blocked("DAY-312", "parameter daftar akun suspense kosong")
  let unknown = unknownAccounts(pool, ctx, accounts)
  if unknown.len > 0:
    return blocked("DAY-311", "akun suspense tidak dikenal/non-aktif: " & unknown.join(", "),
      %*{"unknownAccounts": unknown})
  let lines = pool.withConn(proc(db: DbConn): seq[BalanceLine] =
    balancesFromLedger(db, earliestDate, ctx.businessDate))
  var balances = newJArray()
  for line in lines:
    if line.accountCode in accounts:
      balances.add %*{"accountCode": line.accountCode,
                      "balance": signedBalance(line).toDecimalString}
  if balances.len == 0:
    # Akun parameter tidak punya pergerakan sama sekali: saldonya nol, jadi gate lulus.
    return passed(%*{"accounts": accounts, "balances": balances})
  var nonZero: seq[string]
  for item in balances:
    if item["balance"].getStr != zero().toDecimalString:
      nonZero.add item["accountCode"].getStr
  let metrics = %*{"accounts": accounts, "balances": balances}
  if nonZero.len > 0:
    return blocked("DAY-304",
      "akun selisih belum nol: " & nonZero.join(", "), metrics)
  passed(metrics)

proc trialBalanceCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Σ debit = Σ kredit kumulatif (spec §11.5 #5). Trigger DB menjaga tiap jurnal seimbang; gate
  ## ini membuktikan agregatnya, termasuk jurnal yang dibuat lewat jalur mana pun.
  let lines = pool.withConn(proc(db: DbConn): seq[BalanceLine] =
    balancesFromLedger(db, earliestDate, ctx.businessDate))
  var debit = zero()
  var credit = zero()
  for line in lines:
    debit = debit + line.closingDebit
    credit = credit + line.closingCredit
  let metrics = %*{"totalDebit": debit.toDecimalString, "totalCredit": credit.toDecimalString,
                   "difference": (debit - credit).toDecimalString, "accounts": lines.len}
  if debit != credit:
    return blocked("DAY-305", "trial balance tidak seimbang", metrics)
  passed(metrics)

proc subledgerCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Saldo subledger simpanan harus sama dengan akun GL kewajibannya (spec §11.5 #5).
  let accounts = paramAccounts(pool, ctx, keyString(P_daycloser_postcheck_subledger_gl_accounts))
  if accounts.len == 0:
    return blocked("DAY-312", "parameter daftar akun GL subledger kosong")
  let unknown = unknownAccounts(pool, ctx, accounts)
  if unknown.len > 0:
    return blocked("DAY-311", "akun GL subledger tidak dikenal/non-aktif: " & unknown.join(", "),
      %*{"unknownAccounts": unknown})
  let sub = pool.withConn(proc(db: DbConn): SubledgerTotal = subledgerTotal(db))
  let lines = pool.withConn(proc(db: DbConn): seq[BalanceLine] =
    balancesFromLedger(db, earliestDate, ctx.businessDate))

  var gl = zero()
  var found: seq[string]
  for line in lines:
    if line.accountCode in accounts:
      gl = gl + signedBalance(line)
      found.add line.accountCode

  let parsed = moneyFromString(sub.total)
  let metrics = %*{"subledger": sub.total, "gl": gl.toDecimalString,
                   "glAccounts": found, "accounts": sub.accounts,
                   "missingBalanceRows": sub.missingCache}
  if parsed.isErr:
    return blocked("DAY-306", "saldo subledger tidak terbaca: " & sub.total, metrics)
  if sub.missingCache > 0:
    return blocked("DAY-307",
      $sub.missingCache & " rekening tanpa baris saldo; total subledger tidak bisa dipercaya",
      metrics)
  if parsed.value() != gl:
    return blocked("DAY-308", "saldo subledger tidak sama dengan GL", metrics)
  passed(metrics)

proc latePostingsCheck*(pool: DbPool; ctx: TaskContext): GateResult =
  ## Gerbang HTTP adalah cek-lalu-jalan: permintaan yang **dimulai** sesudah freeze bisa commit
  ## setelah tanggal `CLOSING`. Jurnal seperti itu membuat gate pasca-tutup menilai keadaan yang
  ## tidak lagi lengkap, jadi penutupan harus dihentikan dan diulang.
  ##
  ## Cakupannya sengaja dibatasi: `journal.recorded_at` memakai `now()` (= waktu mulai transaksi),
  ## jadi transaksi yang mulai **sebelum** freeze dan commit sesudahnya tidak tertangkap di sini
  ## (batas dicatat di `docs/ACCEPTED-LIMITS.md`).
  let bd = pool.withConn(proc(db: DbConn): Option[BusinessDateRow] =
    businessDateOf(db, institutionScope()))
  if bd.isNone or bd.get.currentDate != ctx.businessDate or bd.get.state != bdsClosing:
    return blocked("DAY-309",
      "tanggal buku bukan " & ctx.businessDate & " berstatus CLOSING saat pasca-tutup")
  let frozenAtRow = pool.withConn(proc(db: DbConn): Option[string] =
    businessDateFrozenAt(db, institutionScope()))
  if frozenAtRow.isNone:
    return blocked("DAY-309", "waktu pembekuan tanggal buku tidak terbaca")
  let frozenAt = frozenAtRow.get()
  let late = pool.withConn(proc(db: DbConn): tuple[count: int64; ids: seq[string]] =
    latePostings(db, ctx.businessDate, frozenAt, evidenceLimit))
  let metrics = %*{"frozenAt": frozenAt, "latePostings": late.count, "journalIds": late.ids}
  if late.count > 0:
    return blocked("DAY-310",
      $late.count & " jurnal masuk setelah tanggal dibekukan", metrics)
  passed(metrics)

type
  GateSpec = object
    id: string
    module: string
    kind: TaskKind
    requiredParams: seq[string]
    check: GateCheck

proc gateSpecs(): seq[GateSpec] =
  ## Daftar gate tanpa dependensi. Urutan eksekusi **tidak** mengikuti urutan ini: `resolve`
  ## memakai topological sort yang mengurutkan siap secara alfabetis (`registry.nim`). Karena itu
  ## tiap gate harus berdiri sendiri — tidak ada gate yang mengandalkan hasil gate lain.
  @[
    GateSpec(id: "teller.sessions_closed", module: "teller", kind: tkPreCheck,
             check: tellerSessionsCheck),
    GateSpec(id: "teller.pending_approvals", module: "teller", kind: tkPreCheck,
             check: pendingApprovalsCheck),
    GateSpec(id: "ledger.suspense_zero", module: "ledger", kind: tkPreCheck,
             requiredParams: @["daycloser.precheck.suspense_accounts"],
             check: suspenseCheck),
    GateSpec(id: "ledger.trial_balance", module: "ledger", kind: tkPostCheck,
             check: trialBalanceCheck),
    GateSpec(id: "ledger.subledger_vs_gl", module: "ledger", kind: tkPostCheck,
             requiredParams: @["daycloser.postcheck.subledger_gl_accounts"],
             check: subledgerCheck),
    GateSpec(id: "ledger.no_late_postings", module: "ledger", kind: tkPostCheck,
             check: latePostingsCheck),
  ]

proc gateTask(spec: GateSpec; pool: DbPool): DayCloseTask =
  ## Satu task dari satu spesifikasi. Dibuat lewat proc, bukan langsung di dalam loop
  ## `registerGates`: closure yang dibuat di badan loop menangkap **satu** variabel bersama,
  ## sehingga semua gate akan menjalankan pemeriksaan yang terakhir ditulis.
  DayCloseTask(
    id: spec.id,
    module: spec.module,
    levels: {clEOD},
    kind: spec.kind,
    dependsOn: @[],
    # Gate kritis: lulus atau run berhenti. Skip juga ditolak orkestrator untuk task kritis,
      # sehingga "lolos karena dilewati" tidak mungkin.
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: spec.requiredParams,
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
      let r = spec.check(pool, ctx)
      if r.ok:
        return ok[TaskOutcome, TaskError](okOutcome(r.metrics))
      err[TaskOutcome, TaskError](taskError(r.code, r.message, metrics = r.metrics)))

proc registerGates*(reg: Registry; pool: DbPool) =
  for spec in gateSpecs():
    reg.register gateTask(spec, pool)
