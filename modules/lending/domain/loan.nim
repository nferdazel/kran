## Domain murni modul `lending` (T-161): bentuk pinjaman (spec §9.2, §23 Fase 4).
##
## Tahap ini hanya **bentuk dan invarian struktural**: metode jadwal, status, jadwal angsuran per
## baris, dan urutan alokasi pembayaran. Kalkulasi jadwal ada di `schedule.nim` (T-162).
##
## **Tidak ada angka bisnis di sini.** Suku bunga, tenor, ambang DPD, persentase PPAP, dan urutan
## alokasi datang dari binding versi produk + parameter (D-180), bukan konstanta (AGENTS.md §1.2).

import std/[sets, strutils]

import kernel/[ids, money, rate, result]

proc loanErr(msg: string; code = "LEN-1001"): AppError =
  appError(code, "error.lending.invalid", aekValidation, msg)

type
  ScheduleMethod* = enum
    ## Cara jadwal angsuran dibentuk (D-180 butir 1). Nilai string = kolom DB.
    ## Bentuk penyimpanan jadwal sama untuk ketiganya: satu baris per jatuh tempo.
    smFlat = "FLAT"
    smEffective = "EFFECTIVE"
    smAnnuity = "ANNUITY"

  ProductVersionStatus* = enum
    pvsDraft = "DRAFT"
    pvsActive = "ACTIVE"

  LoanStatus* = enum
    ## `WRITTEN_OFF` bukan status akhir data: barisnya tetap ada sebagai riwayat hapus buku.
    lsApplied = "APPLIED"
    lsApproved = "APPROVED"
    lsActive = "ACTIVE"
    lsClosed = "CLOSED"
    lsWrittenOff = "WRITTEN_OFF"

  AllocationComponent* = enum
    ## Potongan yang bisa menerima pembayaran. Urutannya **tidak** ditentukan di kode (D-180
    ## butir 4) — `parseAllocationOrder` membacanya dari parameter.
    acPrincipal = "PRINCIPAL"
    acInterest = "INTEREST"
    acPenalty = "PENALTY"

  LoanProductVersion* = object
    productId*: Id
    versionId*: Id
    productCode*: string
    versionNo*: int
    status*: ProductVersionStatus
    scheduleMethod*: ScheduleMethod
    tenorMonths*: int
    annualRate*: Rate
    ## Urutan lengkap; setiap komponen muncul tepat sekali (dijaga `parseAllocationOrder`).
    allocationOrder*: seq[AllocationComponent]

  Loan* = object
    loanId*: Id
    partyId*: Id
    productVersionId*: Id
    branchId*: Id
    principal*: Money
    status*: LoanStatus
    disbursedOn*: string ## ISO `yyyy-MM-dd`, `""` selama belum dicairkan
    maturityOn*: string
    appliedBy*: Id
    approvedBy*: Id

  Installment* = object
    ## Satu baris jadwal. Nilai "due" dibentuk T-162; pembayaran menambah `paid*` (T-165).
    loanId*: Id
    no*: int
    dueOn*: string
    principalDue*: Money
    interestDue*: Money
    penaltyDue*: Money
    paidPrincipal*: Money
    paidInterest*: Money
    paidPenalty*: Money
    paidOn*: string

proc scheduleMethodOf*(raw: string): AppResult[ScheduleMethod] =
  ## Nilai kolom DB -> enum. Ditolak, bukan diam-diam dipetakan ke default: metode yang salah
  ## menghasilkan jadwal yang salah, dan jadwal yang salah sudah terlihat seperti uang.
  case raw
  of "FLAT": ok[ScheduleMethod, AppError](smFlat)
  of "EFFECTIVE": ok[ScheduleMethod, AppError](smEffective)
  of "ANNUITY": ok[ScheduleMethod, AppError](smAnnuity)
  else: err[ScheduleMethod, AppError](loanErr("metode jadwal tidak dikenal: " & raw))

proc allocationComponentOf*(raw: string): AppResult[AllocationComponent] =
  case raw
  of "PRINCIPAL": ok[AllocationComponent, AppError](acPrincipal)
  of "INTEREST": ok[AllocationComponent, AppError](acInterest)
  of "PENALTY": ok[AllocationComponent, AppError](acPenalty)
  else: err[AllocationComponent, AppError](loanErr("komponen alokasi tidak dikenal: " & raw))

proc parseAllocationOrder*(raw: string): AppResult[seq[AllocationComponent]] =
  ## Parameter menyimpan urutan sebagai daftar dipisah koma, mis. `PRINCIPAL,INTEREST,PENALTY`.
  ## Ditolak bila kosong, ada komponen tak dikenal/duplikat, atau ada komponen yang **hilang**:
  ## urutan tak lengkap membuat sebagian pembayaran tidak punya tujuan, dan itu uang yang
  ## menguap tanpa jejak — bukan pilihan konfigurasi.
  var picked: seq[AllocationComponent] = @[]
  var seen = initHashSet[AllocationComponent]()
  for part in raw.split(','):
    let piece = part.strip()
    if piece.len == 0:
      return err[seq[AllocationComponent], AppError](loanErr("urutan alokasi memuat komponen kosong"))
    let comp = allocationComponentOf(piece)
    if not comp.isOk:
      return err[seq[AllocationComponent], AppError](comp.error)
    if seen.contains(comp.val):
      return err[seq[AllocationComponent], AppError](loanErr("komponen alokasi duplikat: " & piece))
    seen.incl(comp.val)
    picked.add(comp.val)
  # Jumlah komponen diambil dari enum, bukan konstanta lepas: menambah komponen baru tanpa
  # memperbarui parameter lalu gagal di sini, bukan diam-diam dilewati.
  let expected = ord(high(AllocationComponent)) + 1
  if picked.len != expected:
    return err[seq[AllocationComponent], AppError](
      loanErr("urutan alokasi tidak lengkap: " & $picked.len & "/" & $expected)
    )
  ok[seq[AllocationComponent], AppError](picked)

proc allocationOrderString*(order: openArray[AllocationComponent]): string =
  ## Kebalikan `parseAllocationOrder`, untuk menulis parameter/DB.
  var parts: seq[string] = @[]
  for comp in order:
    parts.add($comp)
  parts.join(",")

proc totalDue*(inst: Installment): Money {.inline.} =
  inst.principalDue + inst.interestDue + inst.penaltyDue

proc totalPaid*(inst: Installment): Money {.inline.} =
  inst.paidPrincipal + inst.paidInterest + inst.paidPenalty

proc isSettled*(inst: Installment): bool {.inline.} =
  ## Jadwal dianggap lunas hanya bila **setiap** komponen tertutup; total yang sama bisa berasal
  ## dari alokasi yang salah (mis. denda terbayar, pokok kurang).
  inst.paidPrincipal == inst.principalDue and inst.paidInterest == inst.interestDue and
    inst.paidPenalty == inst.penaltyDue

proc canApprove*(status: LoanStatus): bool =
  ## Hanya pengajuan yang menunggu keputusan yang bisa disetujui. `APPROVED` yang disetujui ulang
  ## akan menimpa penyetuju pertama — jejak siapa yang menyetujui apa jadi hilang.
  status == lsApplied

proc assertDistinctActors*(maker, checker: Id) =
  ## Empat mata (spec §7, D-099): penyetuju pinjaman tidak boleh orang yang mengajukan.
  ## `ValueError` (bukan `AppResult`) karena ini keadaan yang tidak boleh lolos dari jalur HTTP —
  ## handler memetakannya ke `409 self_approval`, sama seperti versi produk.
  if maker == checker:
    raise newException(ValueError,
      "penyetuju harus berbeda dari pembuat (persetujuan sendiri ditolak)")
