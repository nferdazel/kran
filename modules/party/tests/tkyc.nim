## Unit test KYC & dokumen identitas (T-071). Tanpa DB dan tanpa kriptografi: yang diuji bentuk
## nilai, normalisasi, dan aritmetika kalender re-KYC.

import std/[json, options, strutils, unittest]

import ../api

suite "identity: normalisasi & validasi":
  test "normalisasi menyisakan huruf besar dan angka":
    check normalizeNumber("1234-5678 90") == "1234567890"
    check normalizeNumber("kb-123/abc") == "KB123ABC"
    check normalizeNumber("  .--  ") == ""

  test "jenis dokumen selalu disimpan huruf besar, daftar parameter boleh gaya apa pun":
    # Ejaan parameter tidak boleh mengubah nilai tersimpan: `doc_type` ikut kunci unik, jadi
    # merapikan ejaan daftar tidak boleh memecah deteksi duplikat.
    check parseDocType("ktp", @["Ktp"]) == some("KTP")
    check parseDocType("KtP", @["ktp"]) == some("KTP")
    check parseDocType("ktp", @["KTP", "NPWP"]) == some("KTP")

  test "jenis dokumen harus ada di daftar parameter":
    let allowed = @["KTP", "NPWP"]
    check parseDocType("ktp", allowed) == some("KTP")
    check parseDocType(" Npwp ", allowed) == some("NPWP")
    check parseDocType("SIM", allowed).isNone
    check parseDocType("", allowed).isNone

  test "panjang tetap dari parameter dihormati":
    check validateNumber("1234567890123456", 32, 16) == "1234567890123456"
    expect ValueError:
      discard validateNumber("123", 32, 16)

  test "batas panjang parameter mengikat":
    check validateNumber("ABC123", 32) == "ABC123"
    expect ValueError:
      discard validateNumber("ABC123", 3)

  test "nomor kosong dan batas panjang tidak sah ditolak":
    expect ValueError:
      discard validateNumber("", 32)
    expect ValueError:
      discard validateNumber("12", 0)
    # Batas dari parameter tidak boleh melebihi kemampuan kolom (kode menjaga ini).
    expect ValueError:
      discard validateNumber("12", maxNumberLength + 1)

  test "bentuk tersamar hanya menyisakan dua karakter terakhir":
    check maskNumber("1234567890123456") == "56"
    check maskNumber("A1") == "A1"
    check maskNumber("") == ""

suite "kyc: status, level, dan alasan":
  test "status KYC dikenal (case-insensitive)":
    check parseKycStatus("pending") == some(ksPending)
    check parseKycStatus(" Verified ") == some(ksVerified)
    check parseKycStatus("DITOLAK").isNone

  test "tingkat risiko harus ada di daftar parameter":
    let levels = @["LOW", "MEDIUM", "HIGH"]
    check parseRiskLevel("high", levels) == some("HIGH")
    check parseRiskLevel("EXTREME", levels).isNone
    check parseRiskLevel("", levels).isNone

  test "tingkat risiko selalu huruf besar, daftar parameter boleh gaya apa pun":
    check parseRiskLevel("low", @["Low"]) == some("LOW")
    check parseRiskLevel("HIGH", @["high"]) == some("HIGH")

  test "alasan wajib dan dibatasi panjangnya":
    check validateReason("  penilaian awal  ") == "penilaian awal"
    expect ValueError:
      discard validateReason("   ")
    expect ValueError:
      discard validateReason(repeat('x', maxReasonLength + 1))

suite "kyc: jeda re-KYC dari parameter":
  test "bulan per tingkat risiko dibaca dari parameter":
    let p = %*{"LOW": 36, "MEDIUM": 12, "HIGH": 6}
    check reviewMonthsOf(p, "LOW") == 36
    check reviewMonthsOf(p, "high") == 6

  test "kunci tidak ada / bentuk salah = gagal-cepat":
    expect ValueError:
      discard reviewMonthsOf(%*{"LOW": 36}, "HIGH")
    expect ValueError:
      discard reviewMonthsOf(%*{"LOW": "banyak"}, "LOW")
    expect ValueError:
      discard reviewMonthsOf(%*[36], "LOW")
    expect ValueError:
      discard reviewMonthsOf(newJNull(), "LOW")

  test "tanggal jatuh tempo menambah bulan":
    check reviewDueDate("2026-10-19", 36) == "2029-10-19"
    check reviewDueDate("2026-10-31", 1) == "2026-11-30"
    check reviewDueDate("2024-01-31", 1) == "2024-02-29"
    check reviewDueDate("2025-12-15", 12) == "2026-12-15"

  test "jumlah bulan tidak masuk akal ditolak":
    expect ValueError:
      discard reviewDueDate("2026-10-19", 0)

suite "jsonparam: pembacaan bentuk parameter":
  test "larik teks":
    check stringList(%*["KTP", "NPWP"], "party.identity.doc_types") == @["KTP", "NPWP"]
    expect ValueError:
      discard stringList(%*"KTP", "party.identity.doc_types")
    expect ValueError:
      discard stringList(%*["KTP", 16], "party.identity.doc_types")

  test "peta teks→angka":
    check intByKey(%*{"KTP": 16}, "ktp", "party.identity.doc_lengths") == some(16)
    check intByKey(%*{"KTP": 16}, "NPWP", "party.identity.doc_lengths").isNone
    expect ValueError:
      discard intByKey(%*{"KTP": "enam belas"}, "KTP", "party.identity.doc_lengths")
    expect ValueError:
      discard intByKey(%*[16], "KTP", "party.identity.doc_lengths")
