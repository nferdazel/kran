## Result & error terkode (spec §12.2).
##
## Aturan: exception hanya untuk bug/kondisi tak terduga; kegagalan yang bisa
## diperkirakan dikembalikan sebagai `AppResult[T]`. Error membawa **kode + kunci i18n**
## dan bukan kalimat jadi (spec §16.1: backend tidak mengirim kalimat untuk UI).

type
  AppErrorKind* = enum
    aekValidation = "VALIDATION"
    aekNotFound = "NOT_FOUND"
    aekConflict = "CONFLICT"
    aekForbidden = "FORBIDDEN"
    aekDomain = "DOMAIN"
    aekInfrastructure = "INFRASTRUCTURE"

  AppError* = object
    code*: string                           ## kode modul, mis. "DEP-1001" (spec §27.A)
    i18nKey*: string                        ## kunci terjemahan; frontend yang menerjemahkan
    kind*: AppErrorKind
    params*: seq[tuple[key, value: string]] ## nilai untuk placeholder pesan
    details*: string                        ## untuk log/diagnostik; JANGAN dipakai sebagai teks UI

  Result*[T, E] = object
    ok*: bool
    val*: T
    err*: E

  AppResult*[T] = Result[T, AppError]

proc ok*[T, E](v: T): Result[T, E] {.inline.} =
  Result[T, E](ok: true, val: v)

proc err*[T, E](e: E): Result[T, E] {.inline.} =
  Result[T, E](ok: false, err: e)

proc isOk*[T, E](r: Result[T, E]): bool {.inline.} =
  r.ok

proc isErr*[T, E](r: Result[T, E]): bool {.inline.} =
  not r.ok

proc value*[T, E](r: Result[T, E]): T =
  ## Nilai sukses. Menaikkan `ValueError` bila `r` berisi error — ini pemakaian yang
  ## salah (bug), bukan alur normal.
  if not r.ok:
    when E is AppError:
      raise newException(
        ValueError,
        "Result berisi error: " & r.err.code & " (" & $r.err.kind & ")"
      )
    else:
      raise newException(ValueError, "Result berisi error")
  r.val

proc error*[T, E](r: Result[T, E]): E =
  ## Error. Menaikkan `ValueError` bila `r` sukses (pemakaian salah).
  if r.ok:
    raise newException(ValueError, "Result berisi nilai sukses, bukan error")
  r.err

proc mapOk*[T, U, E](r: Result[T, E], f: proc(v: T): U): Result[U, E] =
  if r.ok: ok[U, E](f(r.val)) else: err[U, E](r.err)

proc mapErr*[T, E, F](r: Result[T, E], f: proc(e: E): F): Result[T, F] =
  if r.ok: ok[T, F](r.val) else: err[T, F](f(r.err))

proc appError*(
    code, i18nKey: string,
    kind: AppErrorKind,
    details = "",
    params: seq[tuple[key, value: string]] = @[],
): AppError =
  AppError(code: code, i18nKey: i18nKey, kind: kind, details: details, params: params)

proc `$`*(e: AppError): string =
  ## Representasi untuk log/diagnostik, bukan untuk UI.
  e.code & " [" & $e.kind & "] " & e.i18nKey & (if e.details.len > 0: ": " & e.details else: "")
