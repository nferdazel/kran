## `Result[T, E]` + `AppError` — hasil terkode untuk kernel (spec §12.2, §27.A).
##
## Exception hanya untuk bug/kondisi tak terduga; alur normal memakai `Result`.
## `AppError.code` mengikuti konvensi `MODUL-NNNN` (spec §27.A) dan `i18nKey` diterjemahkan
## di frontend (spec §13, `application/problem+json`).

type
  ## Klasifikasi error tingkat aplikasi (dipakai pemetaan ke HTTP status di interface).
  AppErrorKind* = enum
    aekValidation, aekNotFound, aekConflict, aekForbidden, aekDomain, aekInfrastructure

  ## Error terkode. `code` = "DEP-1001" (spec §27.A); `params` = nilai untuk interpolasi i18n.
  AppError* = object
    code*: string
    i18nKey*: string
    kind*: AppErrorKind
    params*: seq[tuple[key, value: string]]
    details*: string

  ## Hasil generik: sukses membawa `val`, gagal membawa `err`. Salah satu saja yang bermakna.
  Result*[T, E] = object
    ok*: bool
    val*: T
    err*: E

  ## Alias umum: error selalu `AppError`.
  AppResult*[T] = Result[T, AppError]

proc ok*[T, E](v: T): Result[T, E] {.inline.} =
  ## Bungkus nilai sukses.
  Result[T, E](ok: true, val: v)

proc err*[T, E](e: E): Result[T, E] {.inline.} =
  ## Bungkus error.
  Result[T, E](ok: false, err: e)

proc isOk*[T, E](r: Result[T, E]): bool {.inline.} =
  ## True bila sukses.
  r.ok

proc isErr*[T, E](r: Result[T, E]): bool {.inline.} =
  ## True bila gagal.
  not r.ok

template value*[T, E](r: Result[T, E]): T =
  ## Ambil nilai sukses; bila gagal menaikkan `ValueError` berisi detail error.
  if r.ok:
    r.val
  else:
    var msg = "Result dalam keadaan error"
    when E is AppError:
      msg = r.err.code
      if r.err.details.len > 0:
        msg = msg & ": " & r.err.details
    else:
      msg = "Result dalam keadaan error"
    raise newException(ValueError, msg)

proc error*[T, E](r: Result[T, E]): E =
  ## Ambil error; menaikkan `ValueError` bila hasil sebenarnya sukses.
  if r.ok:
    raise newException(ValueError, "Result dalam keadaan sukses, tidak ada error")
  r.err

proc mapOk*[T, U, E](r: Result[T, E], f: proc(v: T): U): Result[U, E] =
  ## Transformasi nilai sukses; error diteruskan tanpa perubahan.
  if r.ok:
    Result[U, E](ok: true, val: f(r.val))
  else:
    Result[U, E](ok: false, err: r.err)

proc appError*(code, i18nKey: string, kind: AppErrorKind, details = "",
               params: seq[tuple[key, value: string]] = @[]): AppError =
  ## Bangun `AppError`. `params` dipakai frontend untuk interpolasi pesan i18n.
  AppError(code: code, i18nKey: i18nKey, kind: kind, params: params, details: details)

proc `$`*(e: AppError): string =
  ## Reprsentasi ringkas untuk log (bukan untuk ditampilkan ke pengguna).
  result = e.code & " (" & $e.kind & ")"
  if e.i18nKey.len > 0:
    result = result & " " & e.i18nKey
  if e.details.len > 0:
    result = result & " - " & e.details
