## Unit test detail party (T-078). Tanpa DB dan tanpa kriptografi: bentuk nilai, validasi per
## jenis party, dan bentuk tersamar.

import std/[options, strutils, unittest]

import ../api

suite "detail: validasi teks":
  test "nama resmi dipangkas dan dijaga panjangnya":
    check validateLegalName("  Budi Santoso  ") == "Budi Santoso"
    expect ValueError:
      discard validateLegalName("B")
    expect ValueError:
      discard validateLegalName(repeat('x', maxLegalNameLength + 1))
    expect ValueError:
      discard validateLegalName("Budi\x01Santoso")

  test "pekerjaan opsional: kosong bukan galat":
    check validateOccupation("") == ""
    check validateOccupation("  Petani  ") == "Petani"
    expect ValueError:
      discard validateOccupation(repeat('x', maxOccupationLength + 1))

  test "alamat/kota/kode pos":
    check validateAddressLine("  Jl. Merdeka 5  ") == "Jl. Merdeka 5"
    expect ValueError:
      discard validateAddressLine("   ")
    check validateCity("  Bandung ") == "Bandung"
    check validateCity("") == ""
    check validatePostalCode("40115") == "40115"
    check validatePostalCode("") == ""

suite "detail: jenis kelamin dari parameter":
  test "harus anggota daftar parameter dan selalu huruf besar":
    let allowed = @["MALE", "FEMALE"]
    check parseSex("male", allowed) == some("MALE")
    check parseSex(" Female ", allowed) == some("FEMALE")
    check parseSex("LAKI", allowed).isNone
    check parseSex("", allowed).isNone

  test "ejaan parameter boleh gaya apa pun, nilai tersimpan satu bentuk":
    check parseSex("male", @["Male"]) == some("MALE")

suite "detail: validasi per jenis party":
  test "PERSON wajib person, dilarang org":
    checkDetailKind(pkPerson, hasPerson = true, hasOrg = false)
    expect ValueError:
      checkDetailKind(pkPerson, hasPerson = false, hasOrg = false)
    expect ValueError:
      checkDetailKind(pkPerson, hasPerson = true, hasOrg = true)

  test "ORG wajib org, dilarang person":
    checkDetailKind(pkOrg, hasPerson = false, hasOrg = true)
    expect ValueError:
      checkDetailKind(pkOrg, hasPerson = false, hasOrg = false)
    expect ValueError:
      checkDetailKind(pkOrg, hasPerson = true, hasOrg = true)

suite "detail: bentuk tersamar":
  test "hanya dua karakter terakhir (pola D-069)":
    check maskTail("Budi Santoso") == "so"
    check maskTail("1990-01-15") == "15"
    check maskTail("A") == "A"
    check maskTail("") == ""
