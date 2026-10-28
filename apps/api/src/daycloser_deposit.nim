## Task `deposit.interest_accrual` (T-138c) dan `deposit.maturity_aro` (T-138d) untuk kerangka
## day-close (spec §11.6 "akrual bunga", "jatuh tempo/ARO").
##
## **Akrual.** Satu chunk = satu halaman rekening berjangka. Untuk tiap rekening, task menghitung
## bunga yang **belum** diakrualkan sampai tanggal buku, mencatatnya di `deposit.interest_accrual`,
## dan menjurnal `InterestAccrued` (D 501 / K 204) di transaksi yang sama. Tanpa jurnal, akrual hanya
## angka di subledger; tanpa baris akrual, jurnal tidak bisa dipertanggungjawabkan. Keduanya satu
## fakta, jadi satu `withTx` per chunk.
##
## **Jatuh tempo.** Setelah akrual hari itu selesai (task ini bergantung pada `interest_accrual`),
## rekening yang `maturity_date <= tanggal buku` dipindahkan sesuai `aro_instruction` (keputusan
## pemilik D-155): pokok+bunga ke rekening simpanan (`NONE`), bunga saja ke rekening simpanan
## (`PRINCIPAL`), atau bunga menjadi pokok (`PRINCIPAL_AND_INTEREST`). Setiap perpindahan dijurnal
## **sinkron** di transaksi chunk yang sama dengan mutasi saldo dan baris `deposit.transaction`,
## karena `reconcile-deposits` merekonstruksi saldo dari baris subledger (D-155).
##
## **Pembulatan sekali per rentang** (keputusan pemilik, 28 Okt 2026): yang dibulatkan adalah bunga
## kumulatif dari `opened_on` sampai tanggal buku, lalu bagian hari itu = selisihnya terhadap
## kumulatif baris terakhir. Membulatkan tiap hari lalu menjumlahkan akan menyimpang beberapa sen
## dari bunga yang dijanjikan di akhir tenor.
##
## **Kritis** (keputusan pemilik): kegagalan satu rekening menahan penutupan. Bunga yang kurang
## tanpa ada yang menahannya adalah temuan audit yang muncul berbulan-bulan kemudian; pokok yang
## tidak berpindah saat jatuh tempo sama.
##
## **Idempoten**: PK `(account_id, business_date)` menolak akrual kedua, kunci idempotensi jurnal
## `interest.accrual:<akun>:<tanggal>` menolak jurnal kedua, dan rekening yang sudah punya baris
## untuk tanggal buku dilewati. Jatuh tempo mengubah keadaan di transaksi yang sama (`status`
## `CLOSED` atau `maturity_date` maju), jadi rekening yang sudah diproses tidak lagi muncul di
## halaman berikutnya; kunci jurnal `maturity:<akun>:<tanggal>` dan `interest.post:<akun>:<tanggal>`
## adalah lapis kedua. Menjalankan ulang penutupan tanggal yang sama tidak mengubah angka.
##
## **HUMAN-REVIEW-REQUIRED**: area kritis (rumus bunga, perpindahan pokok/bunga, jurnal; AGENTS.md
## §8).
##
## Kode kegagalan akrual (stabil, dipakai UI/runbook):
##   DAY-330 daftar rekening gagal dibaca (bisa diulang)
##   DAY-331 binding produk tidak ada / bentuknya salah
##   DAY-332 tanggal rekening/buku tidak sah
##   DAY-333 jurnal akrual gagal ditulis (periode tertutup, rule hilang, dsb.)
##   DAY-334 akrual ganda terdeteksi (PK) — seharusnya mustahil di bawah advisory lock
##   DAY-335 akrual menurun (pokok berkurang tanpa koreksi akrual)
##   DAY-336 nilai akrual melampaui batas bilangan
##   DAY-337 baris akrual gagal disimpan (bisa diulang)
##
## Kode kegagalan jatuh tempo:
##   DAY-340 daftar rekening jatuh tempo gagal dibaca (bisa diulang)
##   DAY-341 `aro_instruction` kosong pada deposito berjangka (data rusak; jangan menebak ARO)
##   DAY-342 tanggal rekening/jatuh tempo tidak sah
##   DAY-343 rekening simpanan tujuan tidak ada (prasyarat operasional, pola `DAY-301`)
##   DAY-344 jurnal jatuh tempo tidak bisa dibuat (rule hilang/ambigu, periode tertutup)
##   DAY-345 perpindahan gagal disimpan / saldo berubah di tengah proses (bisa diulang)
##   DAY-346 `aro_instruction` tidak dikenal (data rusak)
##   DAY-347 tenor perpanjangan tidak sah (`maturity_date` tidak setelah `opened_on`)

import std/[json, options, strutils]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[businessdate, clock, dayclose, ids, money, rate, result]

import platform/domain/event
import platform/infrastructure/outbox_repo

import deposit/domain/[account, daycount, interest, transaction]
import deposit/infrastructure/[interest_repo, maturity_repo, transaction_repo]

import daycloser/domain/[registry, types]

import ./deposit_posting
import ./posting

const
  interestAccrualTaskId* = "deposit.interest_accrual"
  maturityAroTaskId* = "deposit.maturity_aro"

  ## Kunci binding versi produk yang dibaca. Nama atribut ditetapkan kode
  ## (`modules/product/seeds/params.yaml`); nilainya tetap milik produk (spec §10.5, D-137).
  rateParamKey = "product.savings.interest_rate"
  basisParamKey = "product.savings.day_count_basis"
  scaleParamKey = "product.savings.rounding_scale"

  ## Awalan kunci idempotensi jurnal jatuh tempo (lapis kedua, pola `interest.accrual:`).
  maturityJournalPrefix = "maturity:"
  interestPostJournalPrefix = "interest.post:"

type
  DepositAbort = object of CatchableError
    ## Kegagalan yang **bukan** soal I/O: konfigurasi produk rusak, data rekening rusak, atau
    ## prasyarat operasional hilang. Menaikkannya membatalkan transaksi chunk, jadi tidak ada
    ## akrual/perpindahan setengah jadi.
    code*: string
    metrics*: JsonNode

proc abort(code, message: string; metrics: JsonNode = nil): ref DepositAbort =
  result = newException(DepositAbort, message)
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

proc dateOf(iso, what, code: string): BusinessDate =
  ## Parse tanggal dengan kode kegagalan milik pemanggil: akrual memakai `DAY-332`, jatuh tempo
  ## memakai `DAY-342`, supaya operator tahu task mana yang berhenti.
  let parsed = parseBusinessDate(iso)
  if parsed.isErr:
    raise abort(code, what & " bukan tanggal sah: " & iso)
  parsed.value()

proc parseDate(iso, what: string): BusinessDate =
  dateOf(iso, what, "DAY-332")

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
  except DepositAbort as e:
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

# ---------------------------------------------------------------------------------------------
# Jatuh tempo / ARO (T-138d, D-155)
# ---------------------------------------------------------------------------------------------

type
  MaturityOutcome = object
    ## Angka satu rekening untuk metrics chunk. Nol = tidak ada yang berpindah.
    closed: bool
    rolledOver: bool
    principalMoved: Money
    interestPaid: Money
    interestCapitalized: Money

proc parseAroOf(item: MaturityAccount): AroInstruction =
  ## Instrumen ARO wajib ada untuk deposito berjangka yang jatuh tempo. Kosong atau nilai asing =
  ## data rusak; task **berhenti** daripada menebak (`NONE` yang salah menutup rekening anggota).
  let a = item.account
  if item.aroInstruction.len == 0:
    raise abort("DAY-341", "rekening " & a.accountNo &
      ": aro_instruction kosong pada deposito berjangka; lengkapi instruksinya")
  try:
    return parseAroInstruction(item.aroInstruction)
  except ValueError:
    raise abort("DAY-346", "rekening " & a.accountNo & ": aro_instruction tidak dikenal ('" &
      item.aroInstruction & "')")

proc maturityDateOf(item: MaturityAccount): BusinessDate =
  dateOf(item.maturityDate, "maturity_date rekening " & item.account.accountNo, "DAY-342")

proc nextMaturity(item: MaturityAccount): string =
  ## Tenor perpanjangan = tenor semula (`maturity_date − opened_on`), dihitung dari tanggal jatuh
  ## tempo lama (D-155 butir 5). Tidak ada parameter tenor per produk.
  let a = item.account
  let opened = dateOf(a.openedOn, "opened_on rekening " & a.accountNo, "DAY-342")
  let maturity = maturityDateOf(item)
  let tenorDays = daysBetween(opened, maturity)
  if tenorDays <= 0:
    raise abort("DAY-347", "rekening " & a.accountNo & ": tenor perpanjangan tidak sah (" &
      a.openedOn & ".." & item.maturityDate & ")")
  addDays(maturity, tenorDays).toIso

proc journalOf(db: DbConn; clock: Clock; ctx: TaskContext; a: Account; eventType: string;
               amount: Money; keyPrefix: string): Id =
  ## Jurnal perpindahan jatuh tempo, ditulis sinkron. Kunci idempotensi
  ## `<awalan><akun>:<tanggal buku>` mencegah jurnal kedua bila task dijalankan ulang untuk tanggal
  ## yang sama (lapis kedua setelah perubahan keadaan rekening).
  postRuleJournalSync(db, clock, eventType, amount, a.branchId, a.accountId, ctx.businessDate,
    keyPrefix & $a.accountId & ":" & ctx.businessDate, systemActor,
    %*{"product": a.productCode, "accountType": $a.accountType})

proc recordMovement(db: DbConn; clock: Clock; accountId: Id; txType: TransactionType;
                    amount: Money; businessDate, narration: string; journalId: Id) =
  ## Baris subledger untuk perpindahan jatuh tempo. `journalId` boleh sama untuk dua rekening
  ## (satu jurnal = satu fakta GL, dua baris = dua efek rekening); UNIQUE `(journal_id, account_id)`
  ## menjaga agar rekening yang sama tidak dicatat dua kali.
  insertTransaction(db, Transaction(
    transactionId: newId(clock), txType: txType, accountId: accountId, amount: amount,
    businessDate: businessDate, narration: narration, journalId: journalId), systemActor)

proc savingsTarget(db: DbConn; item: MaturityAccount; what: string): Id =
  ## Rekening simpanan tujuan pembayaran pokok/bunga. Tidak ada = prasyarat operasional hilang
  ## (D-155): bukan "tidak berlaku", karena uang anggota tidak punya tempat mendarat.
  let found = activeSavingsAccount(db, item.account.partyId, item.account.branchId)
  if found.isNone:
    raise abort("DAY-343", "rekening " & item.account.accountNo &
      ": tidak ada rekening simpanan ACTIVE di cabang yang sama untuk menerima " & what &
      "; buka rekening tujuan lalu resume penutupan")
  found.get()

proc settleNone(db: DbConn; clock: Clock; ctx: TaskContext; item: MaturityAccount;
                principal, interest: Money): MaturityOutcome =
  ## ARO `NONE` (D-155 butir 2): pokok + bunga pindah ke rekening simpanan, deposito ditutup.
  let a = item.account
  let target = if principal.isPositive or interest.isPositive:
      savingsTarget(db, item, "pokok dan bunga jatuh tempo") else: Id("")

  if principal.isPositive:
    let journalId = journalOf(db, clock, ctx, a, "DepositMatured", principal,
      maturityJournalPrefix)
    recordMovement(db, clock, a.accountId, ttMaturityOut, principal, ctx.businessDate,
      "Pindah jatuh tempo ke rekening simpanan", journalId)
    recordMovement(db, clock, target, ttMaturityIn, principal, ctx.businessDate,
      "Jatuh tempo deposito " & a.accountNo, journalId)
    let left = adjustBalance(db, a.accountId, -principal)
    if left.isNone or not left.get().isZero:
      raise abort("DAY-345", "rekening " & a.accountNo &
        ": saldo tidak bisa dinolkan saat jatuh tempo (berubah selama proses?)")
    if adjustBalance(db, target, principal).isNone:
      raise abort("DAY-345", "rekening tujuan " & $target & ": baris saldo tidak ada")
    result.principalMoved = principal

  if interest.isPositive:
    let journalId = journalOf(db, clock, ctx, a, "InterestPosted", interest,
      interestPostJournalPrefix)
    recordMovement(db, clock, target, ttInterestCredit, interest, ctx.businessDate,
      "Bunga deposito " & a.accountNo, journalId)
    if adjustBalance(db, target, interest).isNone:
      raise abort("DAY-345", "rekening tujuan " & $target & ": baris saldo tidak ada")
    result.interestPaid = interest

  closeAccount(db, a.accountId, systemActor)
  result.closed = true

proc settlePrincipal(db: DbConn; clock: Clock; ctx: TaskContext; item: MaturityAccount;
                     interest: Money): MaturityOutcome =
  ## ARO `PRINCIPAL` (D-155 butir 3): pokok diperpanjang, bunga dibayar ke rekening simpanan.
  let a = item.account
  if interest.isPositive:
    let target = savingsTarget(db, item, "bunga jatuh tempo")
    let journalId = journalOf(db, clock, ctx, a, "InterestPosted", interest,
      interestPostJournalPrefix)
    recordMovement(db, clock, target, ttInterestCredit, interest, ctx.businessDate,
      "Bunga deposito " & a.accountNo, journalId)
    if adjustBalance(db, target, interest).isNone:
      raise abort("DAY-345", "rekening tujuan " & $target & ": baris saldo tidak ada")
    result.interestPaid = interest

  setMaturityDate(db, a.accountId, nextMaturity(item), systemActor)
  result.rolledOver = true

proc settlePrincipalAndInterest(db: DbConn; clock: Clock; ctx: TaskContext;
                                item: MaturityAccount; interest: Money): MaturityOutcome =
  ## ARO `PRINCIPAL_AND_INTEREST` (D-155 butir 4): bunga dikapitalisasi menjadi pokok.
  let a = item.account
  if interest.isPositive:
    let journalId = journalOf(db, clock, ctx, a, "InterestCapitalized", interest,
      interestPostJournalPrefix)
    recordMovement(db, clock, a.accountId, ttInterestCredit, interest, ctx.businessDate,
      "Kapitalisasi bunga deposito", journalId)
    if adjustBalance(db, a.accountId, interest).isNone:
      raise abort("DAY-345", "rekening " & a.accountNo & ": baris saldo tidak ada")
    result.interestCapitalized = interest

  setMaturityDate(db, a.accountId, nextMaturity(item), systemActor)
  result.rolledOver = true

proc settleMaturity(db: DbConn; clock: Clock; ctx: TaskContext; item: MaturityAccount):
    MaturityOutcome =
  ## Keputusan ARO untuk satu rekening yang sudah jatuh tempo. Pokok yang berpindah adalah **saldo
  ## rekening** (bukan angka lain): subledger harus tetap merekonstruksi saldo yang sama.
  let aro = parseAroOf(item)
  let principal = item.account.balance
  let interest = item.accruedInterest
  # Tanggal divalidasi lebih dulu untuk semua ARO: rekening yang tanggalnya rusak tidak boleh
  # diproses sebagian.
  discard maturityDateOf(item)
  case aro
  of aiNone: settleNone(db, clock, ctx, item, principal, interest)
  of aiPrincipal: settlePrincipal(db, clock, ctx, item, interest)
  of aiPrincipalAndInterest: settlePrincipalAndInterest(db, clock, ctx, item, interest)

proc countMaturityChunks(pool: DbPool; chunkSize: int): Result[int, TaskError] =
  ## Jumlah halaman himpunan **stabil** (seluruh rekening berjangka), bukan jumlah yang jatuh tempo:
  ## halaman dihitung di atas himpunan yang tidak berubah selama run (lihat `maturity_repo`).
  try:
    let total = pool.withConn(proc(db: DbConn): int64 = countMaturityCandidates(db))
    if chunkSize < 1:
      raise newException(ValueError, "chunk size harus >= 1")
    ok[int, TaskError](int((total + int64(chunkSize) - 1) div int64(chunkSize)))
  except IOError as e:
    err[int, TaskError](taskError("DAY-340",
      "jumlah rekening jatuh tempo gagal dibaca: " & e.msg, retryable = true))

proc runMaturityChunk(pool: DbPool; clock: Clock; ctx: TaskContext; chunk: Chunk): TaskResult =
  var items: seq[MaturityAccount]
  try:
    items = pool.withConn(proc(db: DbConn): seq[MaturityAccount] =
      dueMaturitiesPage(db, ctx.businessDate, chunk.chunkNo * ctx.chunkSize, ctx.chunkSize))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-340",
      "halaman rekening jatuh tempo gagal dibaca: " & e.msg, retryable = true))

  var closed, rolled = 0
  var principalMoved = zero()
  var interestPaid = zero()
  var interestCapitalized = zero()
  try:
    discard pool.withTx(proc(db: DbConn): int =
      for item in items:
        let settled = settleMaturity(db, clock, ctx, item)
        if settled.closed:
          inc closed
        if settled.rolledOver:
          inc rolled
        principalMoved = principalMoved + settled.principalMoved
        interestPaid = interestPaid + settled.interestPaid
        interestCapitalized = interestCapitalized + settled.interestCapitalized
      1)
  except DepositAbort as e:
    return err[TaskOutcome, TaskError](taskError(e.code, e.msg, metrics = e.metrics))
  except ValueError as e:
    # `selectRule`/`buildLines` menolak rule yang tidak ada atau ambigu: konfigurasi, bukan I/O.
    return err[TaskOutcome, TaskError](taskError("DAY-344",
      "posting rule jatuh tempo tidak bisa dipakai: " & e.msg))
  except IOError as e:
    return err[TaskOutcome, TaskError](taskError("DAY-345",
      "perpindahan jatuh tempo gagal disimpan: " & e.msg, retryable = true))

  ok[TaskOutcome, TaskError](okOutcome(%*{
    "accounts": items.len, "closed": closed, "rolledOver": rolled,
    "principal": principalMoved.toDecimalString, "interestPaid": interestPaid.toDecimalString,
    "interestCapitalized": interestCapitalized.toDecimalString,
    "businessDate": ctx.businessDate}))

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

  # Jatuh tempo **sesudah** akrual: bunga hari terakhir tenor harus sudah tercatat sebelum
  # dipindahkan/dikapitalisasi. `dependsOn` membuat urutan itu bagian dari kontrak registry, bukan
  # kebetulan urutan abjad id.
  reg.register DayCloseTask(
    id: maturityAroTaskId,
    module: "deposit",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[interestAccrualTaskId],
    critical: true,
    idempotency: imPerBusinessDate,
    partition: psByChunkCount,
    requiredParams: @[],
    countChunks: proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
    countMaturityChunks(pool, chunkSize),
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    runMaturityChunk(pool, clock, ctx, chunk))
