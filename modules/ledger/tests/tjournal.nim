## Unit + property test jurnal (T-073): bentuk, keseimbangan, dan pembalik.

import std/[random, strutils, unittest]

import kernel/[ids, money]
import ../api
import ../infrastructure/journal_repo

proc line(no: int, account: string, debit, credit: int64): JournalLine =
  JournalLine(lineNo: no, glAccount: account,
    branchId: Id("11111111-1111-7111-8111-111111111111"),
    debit: money(debit), credit: money(credit))

suite "journal: validasi bentuk":
  test "dua baris seimbang diterima":
    let lines = validateJournalLines(@[
      line(1, "101", 150_0000, 0),
      line(2, "201", 0, 150_0000)])
    check lines.len == 2
    check isBalanced(lines)
    check totalDebit(lines) == money(150_0000)
    check totalCredit(lines) == money(150_0000)

  test "kurang dari dua baris ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", 100, 0)])
    expect ValueError:
      discard validateJournalLines(newSeq[JournalLine]())

  test "baris dengan dua sisi / tanpa sisi ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", 100, 100), line(2, "201", 0, 0)])
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", 0, 0), line(2, "201", 100, 0)])

  test "nomor baris ganda ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", 100, 0), line(1, "201", 0, 100)])

  test "nominal negatif ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", -100, 0), line(2, "201", 0, -100)])

  test "jurnal tidak seimbang ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "101", 100, 0), line(2, "201", 0, 99)])

  test "akun kosong ditolak":
    expect ValueError:
      discard validateJournalLines(@[line(1, "  ", 100, 0), line(2, "201", 0, 100)])

  test "kunci idempotensi wajib dan dibatasi":
    check validateIdempotencyKey(" evt-1 ") == "evt-1"
    expect ValueError:
      discard validateIdempotencyKey("   ")
    expect ValueError:
      discard validateIdempotencyKey(repeat('k', maxIdempotencyKeyLength + 1))
    expect ValueError:
      discard validateIdempotencyKey("a\tb")

  test "source event dan alasan pembalik divalidasi":
    check validateSourceEvent(" DepositPosted ") == "DepositPosted"
    expect ValueError:
      discard validateSourceEvent("")
    check validateReversalReason("salah posting") == "salah posting"
    expect ValueError:
      discard validateReversalReason("   ")

suite "journal: pembalik":
  test "debit dan kredit ditukar, nomor diurutkan ulang":
    let original = @[line(1, "101", 250_0000, 0), line(2, "201", 0, 250_0000)]
    let rev = reversalLinesOf(original)
    check rev.len == 2
    check rev[0].glAccount == "101"
    check rev[0].credit == money(250_0000)
    check rev[0].debit.isZero
    check rev[1].glAccount == "201"
    check rev[1].debit == money(250_0000)
    check isBalanced(rev)
    check totalDebit(rev) == totalDebit(original)

suite "journal: property 1.000 jurnal acak":
  test "jurnal yang dibangkitkan seimbang selalu diterima, mutasi satu unit selalu ditolak":
    var r = initRand(20261020)
    for i in 0 ..< 1000:
      let n = r.rand(2 .. 8)
      var lines: seq[JournalLine]
      var total: int64 = 0
      for k in 1 .. n - 1:
        let amount = r.rand(1 .. 10_000_000).int64
        total += amount
        if r.rand(1) == 0:
          lines.add line(k, "101", amount, 0)
        else:
          lines.add line(k, "201", 0, amount)
      # Baris terakhir menutup selisih sehingga total debit = total kredit.
      let debitSoFar = totalDebit(lines)
      let creditSoFar = totalCredit(lines)
      let diff = minorUnits(debitSoFar) - minorUnits(creditSoFar)
      if diff >= 0:
        lines.add line(n, "201", 0, diff)
      else:
        lines.add line(n, "101", -diff, 0)

      let accepted = validateJournalLines(lines)
      check accepted.len == n
      check isBalanced(accepted)

      # Mutasi satu unit pada satu baris harus membuat jurnal tidak seimbang.
      var broken = accepted
      let idx = r.rand(0 .. broken.high)
      if broken[idx].debit.isZero:
        broken[idx].credit = money(minorUnits(broken[idx].credit) + 1)
      else:
        broken[idx].debit = money(minorUnits(broken[idx].debit) + 1)
      expect ValueError:
        discard validateJournalLines(broken)

suite "journal: nominal dari DB (T-129/DB-5)":
  test "nilai dalam rentang Money terbaca apa adanya":
    check moneyOf("1234.00") == money(123400)
    check moneyOf("-1234.00") == money(-123400)
    check moneyOf("0.00").isZero

  test "batas atas tepat masih diterima":
    # int64.high minor units = 92.233.720.368.547.758,07
    check moneyOf("92233720368547758.07") == money(int64.high)

  test "satu sen di atas batas ditolak, bukan membungkus":
    # Sebelum T-129 nilai ini membungkus jadi negatif tanpa galat.
    expect ValueError:
      discard moneyOf("92233720368547758.08")

  test "nilai 22 digit (lebar numeric(24,2)) ditolak":
    expect ValueError:
      discard moneyOf("9999999999999999999999.99")

  test "skala lebih dari 2 desimal tetap ditolak":
    expect ValueError:
      discard moneyOf("1.005")
