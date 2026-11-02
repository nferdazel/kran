## Laporan portofolio pinjaman (T-171) — murni, tanpa I/O.
##
## Tiga laporan dengan tiga tanggal acuan yang berbeda, dan itu disengaja:
##
##   - **tunggakan/aging** dan **penyisihan** adalah potret **per tanggal buku** (dibaca dari
##     snapshot harian T-166/T-167). Laporan untuk tanggal lampau harus memakai nilai tanggal itu;
##     memakai nilai hari ini akan mengubah laporan yang sudah dipublikasikan.
##   - **rekonsiliasi** membandingkan GL dengan subledger saat ini, jadi ia tidak punya `asOf`:
##     "saldo GL per 30 Juni" versus "sisa pokok hari ini" hanya akan menghasilkan selisih palsu.
##
## Golongan (dan karenanya keranjang aging) **tidak** didefinisikan di sini: ambangnya parameter
## (`lending.collectibility.dpd_bounds`, D-180) dan pemetaannya milik `collectibility.gradeOf`.

import std/algorithm

import kernel/[ids, money]

import ./collectibility

type
  ArrearsItem* = object
    ## Satu pinjaman yang **punya** angsuran lewat jatuh tempo dengan sisa > 0. Tunggakan dihitung
    ## dari jadwal aktif (`superseded_on IS NULL`), bukan dari cache saldo: cache bisa tertinggal
    ## dan laporan harus bisa menjelaskan angkanya.
    loanId*: Id
    partyId*: Id
    branchId*: Id
    dpd*: int
    grade*: Collectibility
    principal*: Money
    interest*: Money
    penalty*: Money

  ArrearsTotal* = object
    principal*: Money
    interest*: Money
    penalty*: Money

  GradeAging* = object
    ## Keranjang aging = golongan kolektibilitas, karena keduanya memakai ambang DPD yang sama.
    grade*: Collectibility
    loans*: int
    principal*: Money
    interest*: Money
    penalty*: Money

  AllowanceLine* = object
    ## Satu baris laporan penyisihan per golongan, apa adanya dari snapshot tanggal itu.
    ## `rateMicro` adalah `Rate` (1e6 = 100%); tarif tidak dijumlahkan saat agregasi — kalau dua
    ## tarif berbeda muncul untuk satu golongan, itu perubahan parameter di tengah hari dan harus
    ## terlihat (`mixedRates`).
    grade*: Collectibility
    loans*: int
    base*: Money
    rateMicro*: int64
    allowance*: Money

  ArrearsReport* = object
    asOf*: string
    items*: seq[ArrearsItem]
    byGrade*: seq[GradeAging]

  AllowanceReport* = object
    asOf*: string
    lines*: seq[AllowanceLine]

  Reconciliation* = object
    ## Dua identitas yang dijaga, dan selisihnya ditampilkan apa adanya (bukan disembunyikan
    ## dengan `abs`): tanda selisih menunjukkan sisi mana yang lebih besar.
    ##
    ##   GL 110 (piutang)      = Σ sisa pokok subledger
    ##   GL 111 (penyisihan)   = Σ penyisihan terakhir − Σ penyisihan terpakai hapus buku
    loanReceivableGl*: Money
    loanReceivableSubledger*: Money
    allowanceGl*: Money
    allowanceSubledger*: Money
    allowanceWrittenOff*: Money

proc lineTotal*(item: ArrearsItem): Money {.inline.} =
  item.principal + item.interest + item.penalty

proc total*(t: ArrearsTotal): Money {.inline.} =
  t.principal + t.interest + t.penalty

proc total*(g: GradeAging): Money {.inline.} =
  g.principal + g.interest + g.penalty

proc combined*(report: ArrearsReport): ArrearsTotal =
  for item in report.items:
    result.principal = result.principal + item.principal
    result.interest = result.interest + item.interest
    result.penalty = result.penalty + item.penalty

proc groupByGrade*(items: seq[ArrearsItem]): seq[GradeAging] =
  ## Satu baris per golongan yang **ada** isinya, urut keparahan (urutan enum). Golongan kosong
  ## tidak dicetak sebagai nol: laporan tunggakan yang menampilkan semua keranjang selalu membuat
  ## pembaca mengira angkanya lengkap.
  for grade in Collectibility:
    var line = GradeAging(grade: grade)
    for item in items:
      if item.grade != grade:
        continue
      line.loans = line.loans + 1
      line.principal = line.principal + item.principal
      line.interest = line.interest + item.interest
      line.penalty = line.penalty + item.penalty
    if line.loans > 0:
      result.add line

proc byDpd*(items: seq[ArrearsItem]): seq[ArrearsItem] =
  ## Urutan laporan: paling lama menunggak lebih dulu, lalu id. Urutan yang bergantung pada urutan
  ## baris DB akan berubah setiap kali planner memilih indeks lain.
  result = items
  result.sort(proc (a, b: ArrearsItem): int =
    if a.dpd != b.dpd: cmp(b.dpd, a.dpd) else: cmp($a.loanId, $b.loanId))

proc allowanceTotal*(report: AllowanceReport): Money =
  for line in report.lines:
    result = result + line.allowance

proc allowanceBase*(report: AllowanceReport): Money =
  for line in report.lines:
    result = result + line.base

proc mixedRates*(report: AllowanceReport): seq[Collectibility] =
  ## Golongan yang muncul lebih dari sekali — indikasi tarif berubah di tengah tanggal buku.
  ## Snapshot menyimpan tarif per pinjaman, jadi ini bisa terjadi tanpa melanggar skema.
  for grade in Collectibility:
    var seen = 0
    for line in report.lines:
      if line.grade == grade:
        seen = seen + 1
    if seen > 1:
      result.add grade

proc receivableDiff*(r: Reconciliation): Money {.inline.} =
  r.loanReceivableGl - r.loanReceivableSubledger

proc allowanceExpected*(r: Reconciliation): Money {.inline.} =
  ## Penyisihan yang seharusnya masih tercatat: yang dibentuk dikurangi yang sudah dipakai hapus
  ## buku.
  r.allowanceSubledger - r.allowanceWrittenOff

proc allowanceDiff*(r: Reconciliation): Money {.inline.} =
  r.allowanceGl - r.allowanceExpected

proc isBalanced*(r: Reconciliation): bool {.inline.} =
  r.receivableDiff().isZero and r.allowanceDiff().isZero
