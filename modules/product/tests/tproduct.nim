## Unit test domain `product` (T-076): bentuk kode, tipe, jendela versi, binding.

import std/[json, strutils, unittest]

import kernel/ids
import ../api

suite "product: identitas":
  test "kode dinormalisasi dan divalidasi":
    check validateCode("  tab-sukarela ") == "TAB-SUKARELA"
    check validateCode("sav.01") == "SAV.01"
    expect ValueError:
      discard validateCode("")
    expect ValueError:
      discard validateCode("X")
    expect ValueError:
      discard validateCode("-ABC")
    expect ValueError:
      discard validateCode("AB CD")

  test "nama wajib dan dibatasi":
    check validateName("  Simpanan Sukarela ") == "Simpanan Sukarela"
    expect ValueError:
      discard validateName("   ")
    expect ValueError:
      discard validateName(repeat('x', 121))

  test "tipe produk hanya yang dikenal":
    check parseProductType("savings") == ptSavings
    check parseProductType("TIME_DEPOSIT") == ptTimeDeposit
    expect ValueError:
      discard parseProductType("DEPOSITO")

suite "product: status versi (maker-checker)":
  test "status dikenal dan dinormalisasi":
    check parseVersionStatus("draft") == vsDraft
    check parseVersionStatus(" ACTIVE ") == vsActive
    check parseVersionStatus("Rejected") == vsRejected
    expect ValueError:
      discard parseVersionStatus("RETIRED")

  test "transisi hanya DRAFT → ACTIVE/REJECTED":
    check canTransition(vsDraft, vsActive)
    check canTransition(vsDraft, vsRejected)
    check not canTransition(vsActive, vsDraft)
    check not canTransition(vsActive, vsRejected)
    check not canTransition(vsRejected, vsActive)
    check not canTransition(vsDraft, vsDraft)

  test "self-approval ditolak domain":
    let maker = Id("77777777-7777-7777-8777-777777777777")
    let checker = Id("88888888-8888-7888-8888-888888888888")
    assertDistinctActors(maker, checker)
    expect ValueError:
      assertDistinctActors(maker, maker)

suite "product: jendela versi":
  test "terbuka ke atas bila effectiveTo kosong":
    let w = validateWindow("2026-10-01", "")
    check w.fromIso == "2026-10-01"
    check w.toIso == ""

  test "effectiveTo boleh sama (versi satu hari), tidak boleh sebelum":
    let w = validateWindow("2026-10-01", "2026-11-01")
    check w.toIso == "2026-11-01"
    let oneDay = validateWindow("2026-10-01", "2026-10-01")
    check oneDay.toIso == "2026-10-01"
    expect ValueError:
      discard validateWindow("2026-10-02", "2026-10-01")

  test "tanggal tidak sah ditolak":
    expect ValueError:
      discard validateWindow("2026-02-31", "")
    expect ValueError:
      discard validateWindow("2026-10-01", "31-10-2026")

suite "product: binding parameter":
  proc binding(key: string, value: JsonNode): ParamBinding =
    ParamBinding(paramKey: key, value: value)

  test "minimal satu binding dan hanya namespace product.":
    check validateBindings(@[binding("product.savings.min_balance", %"0.0000")]).len == 1
    expect ValueError:
      discard validateBindings(newSeq[ParamBinding]())
    expect ValueError:
      discard validateBindings(@[binding("platform.security.session_idle_minutes", %30)])

  test "kunci ganda dan nilai null ditolak":
    expect ValueError:
      discard validateBindings(@[
        binding("product.savings.admin_fee", %"0.0000"),
        binding("product.savings.admin_fee", %"1.0000")])
    expect ValueError:
      discard validateBindings(@[binding("product.savings.admin_fee", newJNull())])
