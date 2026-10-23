## Unit test domain `deposit` pemindahbukuan (T-088c): akun harus berbeda, nominal positif, event.
##
## Murni (tanpa DB) — invarian DB (mutasi dua saldo, urutan kunci anti-deadlock, jurnal) diuji di
## `ittransfer`; jalur HTTP di `itapi_teller`.

import std/unittest

import kernel/[ids, money]
import ../api

suite "deposit: invarian pemindahbukuan":
  test "rekening sumber dan tujuan harus berbeda":
    let a = Id("11111111-1111-7111-8111-111111111111")
    let b = Id("22222222-2222-7222-8222-222222222222")
    # Beda rekening + nominal positif → lolos.
    validateTransfer(a, b, money(100_0000))
    expect ValueError:
      validateTransfer(a, a, money(100_0000))

  test "nominal PB harus positif":
    let a = Id("11111111-1111-7111-8111-111111111111")
    let b = Id("22222222-2222-7222-8222-222222222222")
    expect ValueError:
      validateTransfer(a, b, zero())
    expect ValueError:
      validateTransfer(a, b, money(-1))

  test "event ledger PB dinamai DepositTransferred":
    check transferSourceEvent == "DepositTransferred"
