## Task `deposit.interest_accrual` untuk kerangka day-close (T-138c, spec §11.6 "akrual bunga").
##
## Satu chunk = satu halaman rekening berjangka. Untuk tiap rekening, task menghitung bunga yang
## **belum** diakrualkan sampai tanggal buku, mencatatnya di `deposit.interest_accrual`, dan
## menjurnal `InterestAccrued` (D 501 / K 204) di transaksi yang sama. Tanpa jurnal, akrual hanya
## angka di subledger; tanpa baris akrual, jurnal tidak bisa dipertanggungjawabkan. Keduanya satu
## fakta, jadi satu `withTx` per chunk.
##
## **Pembulatan sekali per rentang** (keputusan pemilik, 28 Okt 2026): yang dibulatkan adalah bunga
## kumulatif dari `opened_on` sampai tanggal buku, lalu bagian hari itu = selisihnya terhadap
## kumulatif baris terakhir. Membulatkan tiap hari lalu menjumlahkan akan menyimpang beberapa sen
## dari bunga yang dijanjikan di akhir tenor.
##
## **Kritis** (keputusan pemilik): kegagalan satu rekening menahan penutupan. Bunga yang kurang
## tanpa ada yang menahannya adalah temuan audit yang muncul berbulan-bulan kemudian.
##
## **Idempoten**: PK `(account_id, business_date)` menolak akrual kedua, kunci idempotensi jurnal
## `interest.accrual:<akun>:<tanggal>` menolak jurnal kedua, dan rekening yang sudah punya baris
## untuk tanggal buku dilewati. Menjalankan ulang penutupan tanggal yang sama tidak mengubah angka.
##
## **HUMAN-REVIEW-REQUIRED**: area kritis (rumus bunga + jurnal, AGENTS.md §8).
##
## Kode kegagalan (stabil, dipakai UI/runbook):
##   DAY-330 daftar rekening gagal dibaca (bisa diulang)
##   DAY-331 binding produk tidak ada / bentuknya salah
##   DAY-332 tanggal rekening/buku tidak sah
##   DAY-333 jurnal akrual gagal ditulis (periode tertutup, rule hilang, dsb.)
##   DAY-334 akrual ganda terdeteksi (PK) — seharusnya mustahil di bawah advisory lock
##   DAY-335 akrual menurun (pokok berkurang tanpa koreksi akrual)
##   DAY-336 nilai akrual melampaui batas bilangan
##   DAY-337 baris akrual gagal disimpan (bisa diulang)

import std/[json, strutils]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[businessdate, clock, dayclose, ids, money, rate, result]

import platform/domain/event
import platform/infrastructure/outbox_repo

import deposit/domain/[account, daycount, interest]
import deposit/infrastructure/interest_repo

import daycloser/domain/[registry, types]

import ./deposit_posting
import ./posting

const
  interestAccrualTaskId* = "deposit.interest_accrual"

  ## Kunci binding versi produk yang dibaca. Nama atribut ditetapkan kode
  ## (`modules/product/seeds/params.yaml`); nilainya tetap milik produk (spec §10.5, D-137).
  rateParamKey = "product.savings.interest_rate"
  basisParamKey = "product.savings.day_count_basis"
  scaleParamKey = "product.savings.rounding_scale"

type
  AccrualAbort = object of CatchableError
    ## Kegagalan yang **bukan** soal I/O: konfigurasi produk rusak atau angka tidak masuk akal.
    ## Menaikkannya membatalkan transaksi chunk, jadi tidak ada akrual setengah jadi.
    code*: string
    metrics*: JsonNode

proc abort(code, message: string; metrics: JsonNode = nil): ref AccrualAbort =
  result = newException(AccrualAbort, message)
  result.code = code
  result.metrics = metrics

proc requireText(value: JsonNode; key, accountNo: string): string =
  if value.isNil or value.kind != JString or value.getStr().strip.len == 0:
    raise abort("DAY-331", "rekening " & accountNo & ": binding " & key &
      " tidak ada atau bukan teks")
  value.getStr()

proc rateOf(value: JsonNode; accountNo: string): Rate =
  let raw = requireText(value, rateParamKey, accountNo)
  let parsed = rateFromPercentString(raw)
  if parsed.isErr:
    raise abort("DAY-331", "rekening " & accountNo & ": binding " & rateParamKey &
      " bukan rate persen sah ('" & raw & "')")
  parsed.value()

proc basisOf(value: JsonNode; accountNo: string): DayCountBasis =
  let raw = requireText(value, basisParamKey, accountNo)
  try:
    parseDayCountBasis(raw)
  except ValueError:
    raise abort("DAY-331", "rekening " & accountNo & ": binding " & basisParamKey &
      " bukan basis yang dikenal ('" & raw & "')")

proc roundingScaleOf(value: JsonNode; accountNo: string): int =
  if value.isNil or value.kind != JInt:
    raise abort("DAY-331", "rekening " & accountNo & ": binding " & scaleParamKey &
      " tidak ada atau bukan integer")
  let scale = value.getInt
  if scale < 0 or scale > moneyScale:
    raise abort("DAY-331", "rekening " & accountNo & ": binding " & scaleParamKey &
      " di luar 0.." & $moneyScale & " (" & $scale & ")")
  scale

proc quantize(amount: Money; scale: int): Money =
  ## Turunkan presisi ke `scale` desimal dengan HALF_EVEN (Money sudah membulatkan begitu).
  ## `scale = moneyScale` = tidak ada perubahan; `0`/`1` membuang digit di bawahnya **sebelum**
  ## selisih dihitung, supaya bagian harian tidak "mengembalikan" digit yang tidak dipakai.
  if scale >= moneyScale:
    return amount
  var step = 1'i64
  for _ in 0 ..< moneyScale - scale:
    step *= 10
  amount.div(step) * step

proc parseDate(iso, what: string): BusinessDate =
  let parsed = parseBusinessDate(iso)
  if parsed.isErr:
    raise abort("DAY-332", what & " bukan tanggal sah: " & iso)
  parsed.value()

proc parseMoney(text, what: string): Money =
  let parsed = moneyFromString(text)
  if parsed.isErr:
    raise abort("DAY-332", what & " bukan nominal sah: " & text)
  parsed.value()

proc countChunks(pool: DbPool; chunkSize: int): Result[int, TaskError] =
  ## Jumlah halaman rekening. Nol rekening = nol chunk: institusi tanpa deposito berjangka tetap
  ## bisa menutup buku, dan task-nya tetap tercatat `SUCCEEDED` tanpa pekerjaan.
  try:
    let total = pool.withConn(proc(db: DbConn): int64 = countAccrualAccounts(db))
    if chunkSize < 1:
      raise newException(ValueError, "chunk size harus >= 1")
    ok[int, TaskError](int((total + int64(chunkSize) - 1) div int64(chunkSize)))
  except IOError as e:
    err[int, TaskError](taskError("DAY-330",
      "jumlah rekening akrual gagal dibaca: " & e.msg, retryable = true))

type
  AccrualCalc = object
    days*: int           ## hari akrual pada rentang ini (0 = tidak ada yang dicatat)
    amount*: Money       ## bagian yang dijurnal hari ini (kumulatif sekarang − sebelumnya)
    cumulative*: Money   ## total sejak opened_on, dibulatkan sekali
    ratePercent*: string ## bentuk persen kanonik untuk arsip
    basisDayCount*: int  ## pembagi tahun basis saat ini

proc accrualOf(item: AccrualAccount; businessDate: string): AccrualCalc =
  ## Hitung bagian yang belum diakrualkan untuk satu rekening pada satu tanggal buku. Murni
  ## terhadap data yang sudah dibaca (tidak menyentuh DB), supaya angkanya bisa diuji ulang.
  let a = item.account
  let opened = parseDate(a.openedOn, "opened_on rekening " & a.accountNo)
  let through = parseDate(businessDate, "tanggal buku")

  let rate = rateOf(item.rateValue, a.accountNo)
  let basis = basisOf(item.basisValue, a.accountNo)
  let scale = roundingScaleOf(item.scaleValue, a.accountNo)
  let units = basisDays(basis)

  # Bunga berhenti pada hari **sebelum** jatuh tempo (keputusan pemilik, D-155): tenor 365 hari
  # dari 1 Okt 2026 berakhir 30 Sep 2027, dan maturity_date-nya 1 Okt 2027. Tanpa batas ini,
  # deposit yang prosesnya terlambat akan berbunga melewati perjanjian.
  var accrualThrough = through
  if item.maturityDate.len > 0:
    let maturity = parseDate(item.maturityDate, "maturity_date rekening " & a.accountNo)
    let lastAccruing = addDays(maturity, -1)
    if lastAccruing < accrualThrough:
      accrualThrough = lastAccruing
  if accrualThrough < opened:
    return AccrualCalc(days: 0, amount: zero(), cumulative: zero(),
      ratePercent: rate.toPercentString, basisDayCount: units)

  # Hari akrual kumulatif sejak rekening dibuka sampai tanggal akrual terakhir (inklusif). Basis
  # 30/360 bisa menghasilkan 0 hari untuk rentang pendek di akhir bulan — artefak konvensi, bukan
  # bug; rekening itu tidak mencatat baris hari ini dan ketinggalannya ikut pada hari berikutnya.
  let cumulativeDays = accrualDays(basis, a.openedOn, addDays(accrualThrough, 1).toIso)
  if cumulativeDays <= 0:
    # 30/360 bisa memberi 0 hari untuk rentang pendek di akhir bulan (artefak konvensi). Tidak ada
    # yang dicatat hari ini; ketinggalannya ikut pada hari berikutnya karena kumulatif dihitung
    # dari `opened_on`, bukan dari baris terakhir.
    return AccrualCalc(days: 0, amount: zero(), cumulative: zero(),
      ratePercent: rate.toPercentString, basisDayCount: units)

  let raw = interestForRange(a.balance, rate, cumulativeDays, units)
  if raw.isErr:
    raise abort("DAY-336", "rekening " & a.accountNo & ": " & raw.error.details)
  let cumulative = quantize(raw.value(), scale)

  var previous = zero()
  if item.lastDate.len > 0:
    previous = parseMoney(item.lastCumulative, "cumulative akrual terakhir rekening " & a.accountNo)
  let amount = cumulative - previous
  if amount.isNegative:
    raise abort("DAY-335", "rekening " & a.accountNo & ": akrual menurun dari " &
      previous.toDecimalString & " ke " & cumulative.toDecimalString &
      " (pokok berkurang tanpa koreksi akrual?)")

  let rangeStart = if item.lastDate.len > 0: addDays(parseDate(item.lastDate,
    "tanggal akrual terakhir rekening " & a.accountNo), 1) else: opened
  # `accrualThrough` bisa berada **sebelum** awal rentang: rekening yang sudah diakrualkan sampai
  # batas jatuh tempo lalu diproses lagi setelahnya. Itu bukan rentang terbalik yang salah, hanya
  # tidak ada hari baru — dan `accrualDays` menolak urutan terbalik.
  if accrualThrough < rangeStart:
    return AccrualCalc(days: 0, amount: zero(), cumulative: zero(),
      ratePercent: rate.toPercentString, basisDayCount: units)
  AccrualCalc(days: accrualDays(basis, rangeStart.toIso, addDays(accrualThrough, 1).toIso),
    amount: amount, cumulative: cumulative, ratePercent: rate.toPercentString,
    basisDayCount: units)

proc runChunk(pool: DbPool; clock: Clock; ctx: TaskContext; chunk: Chunk): TaskResult =
  var accounts: seq[AccrualAccount]
  try:
    accounts = pool.withConn(proc(db: DbConn): seq[AccrualAccount] =
      accrualAccountsPage(db, chunk.chunkNo * ctx.chunkSize, ctx.chunkSize))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-330",
      "halaman rekening akrual gagal dibaca: " & e.msg, retryable = true))

  var accrued, zeroed, already = 0
  var total = zero()
  try:
    discard pool.withTx(proc(db: DbConn): int =
      for item in accounts:
        let a = item.account
        if item.lastDate.len > 0 and item.lastDate >= ctx.businessDate:
          inc already # tanggal buku ini (atau sesudahnya) sudah punya baris akrual
          continue
        if ctx.businessDate < a.openedOn:
          inc already # rekening dibuka setelah tanggal buku: belum ada bunga
          continue

        let calc = accrualOf(item, ctx.businessDate)
        if calc.days <= 0:
          inc already
          continue

        var journalId = Id("")
        if calc.amount.isPositive:
          journalId = postRuleJournalSync(db, clock, "InterestAccrued", calc.amount,
            a.branchId, a.accountId, ctx.businessDate,
            "interest.accrual:" & $a.accountId & ":" & ctx.businessDate, systemActor,
            %*{"product": a.productCode, "accountType": $a.accountType})
          # Event **tanpa** header `accounting`: jurnalnya sudah ditulis sinkron di atas, jadi
          # konsumen outbox tidak boleh memposting jurnal kedua (pola yang sama dengan transaksi
          # tunai teller). Header `accounting` hanya untuk event yang belum dijurnal.
          discard appendEvent(db, newOutboxEvent(newId(clock), "InterestAccrued", "deposit_account",
            $a.accountId, "interest.accrued:" & $a.accountId & ":" & ctx.businessDate,
            %*{"accountId": $a.accountId, "businessDate": ctx.businessDate,
               "amount": calc.amount.toDecimalString, "cumulative": calc.cumulative.toDecimalString,
               "days": calc.days, "journalId": $journalId, "branchId": $a.branchId}))

        let inserted = insertAccrual(db, a.accountId, ctx.businessDate,
          a.balance.toDecimalString, calc.ratePercent, calc.amount.toDecimalString,
          calc.cumulative.toDecimalString, calc.days, calc.basisDayCount, journalId)
        if not inserted:
          raise abort("DAY-334", "rekening " & a.accountNo & " sudah punya akrual untuk " &
            ctx.businessDate & " (PK menolak baris kedua)")
        if calc.amount.isPositive:
          inc accrued
          total = total + calc.amount
        else:
          inc zeroed
      1)
  except AccrualAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg, metrics = e.metrics))
  except ValueError as e:
    # `selectRule`/`buildLines` menolak rule yang tidak ada atau ambigu: konfigurasi, bukan I/O.
    return err[TaskOutcome, TaskError](taskError("DAY-333",
      "posting rule akrual tidak bisa dipakai: " & e.msg))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-337",
      "akrual gagal disimpan: " & e.msg, retryable = true))

  ok[TaskOutcome, TaskError](okOutcome(%*{
    "accounts": accounts.len, "accrued": accrued, "zero": zeroed, "skipped": already,
    "total": total.toDecimalString, "businessDate": ctx.businessDate}))

proc registerDepositTasks*(reg: Registry; pool: DbPool) =
  let clock = systemClock()

  reg.register DayCloseTask(
    id: interestAccrualTaskId,
    module: "deposit",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psByChunkCount,
    requiredParams: @[],
    countChunks: proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
    countChunks(pool, chunkSize),
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    runChunk(pool, clock, ctx, chunk))
