import std/[options, unittest]

import kernel/ids
import ../api

suite "CIF: digit Luhn":
  test "vektor klasik 7992739871":
    check luhnCheckDigit("7992739871") == '3'

  test "nol dan satu digit":
    check luhnCheckDigit("0") == '0'
    check luhnCheckDigit("1") == '8'
    check luhnCheckDigit("12") == '5'

  test "literal non-digit dilewati":
    check luhnCheckDigit("CIF-0007") == '5'

  test "payload tanpa digit ditolak":
    expect ValueError:
      discard luhnCheckDigit("ABC-")

suite "CIF: format dari pola parameter":
  test "urutan berlebar nol + check":
    check formatCif("{seq:6}{check}", 1) == "0000018"
    check formatCif("{seq:6}{check}", 42) == "0000422"

  test "prefix literal":
    check formatCif("CIF-{seq:4}{check}", 7) == "CIF-00075"

  test "tanpa check digit":
    check formatCif("AG-{seq}", 12) == "AG-12"

  test "urutan tidak muat di lebar ditolak":
    expect ValueError:
      discard formatCif("{seq:2}", 100)

  test "pola tanpa {seq} ditolak":
    expect ValueError:
      discard formatCif("{check}", 1)

  test "{check} bukan di akhir ditolak":
    expect ValueError:
      discard formatCif("{check}{seq}", 1)

  test "{seq} ganda ditolak":
    expect ValueError:
      discard formatCif("{seq}{seq}", 1)

  test "lebar bukan angka ditolak":
    expect ValueError:
      discard formatCif("{seq:abc}", 1)

  test "karakter di luar daftar aman ditolak":
    expect ValueError:
      discard formatCif("{seq} {check}", 1)

  test "nomor urut minimal 1":
    expect ValueError:
      discard formatCif("{seq}", 0)

  test "hasil lebih dari 32 karakter ditolak":
    # Pola ini **lolos** aturan token (satu `{seq}` muat, `{check}` di akhir) tetapi hasilnya
    # 15 + 18 + 1 = 34 karakter — jadi yang diuji memang batas panjang, bukan aturan token lain.
    expect ValueError:
      discard formatCif("AAAAAAAAAAAAAAA{seq:18}{check}", 1)

suite "party: validasi domain":
  let branch = Id("11111111-1111-7111-8111-111111111111")

  test "jenis dikenal":
    check parsePartyKind("PERSON") == some(pkPerson)
    check parsePartyKind("ORG") == some(pkOrg)
    check parsePartyKind("LAIN") == none(PartyKind)

  test "nama dinormalisasi dan divalidasi":
    check validateName("  Budi  ") == "Budi"
    expect ValueError:
      discard validateName(" A ")
    expect ValueError:
      discard validateName("Budi\nSantoso")

  test "party baru ACTIVE + CIF dari pola":
    let p = newParty(Id("22222222-2222-7222-8222-222222222222"), pkPerson, " Budi ",
      branch, "{seq:4}{check}", 3)
    check p.cif == "0003" & $luhnCheckDigit("0003")
    check p.displayName == "Budi"
    check p.status == psActive
    check p.branchId == branch
