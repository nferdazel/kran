## Jenis & metadata parameter yang dipakai bersama (spec §10.2–§10.4).
##
## Berkas ini adalah **kontrak** antara kode yang ditulis manusia dan kode hasil generate
## `tools/paramgen`: definisi parameter hidup di `modules/<m>/seeds/params.yaml`, hasil
## generate-nya ada di `shared/kernel/generated/paramkeys.nim`.
##
## Aturan (spec §10.4): nilai bisnis tidak boleh diambil lewat string mentah. Cara satu-satunya
## memakai key bertipe:
##
## ```nim
## let dpdKl = params.get(P_lending_collectibility_dpd_kl, asOf = bizDate, scope = loanScope)
## ```

type
  ## Cakupan (scope) sebuah nilai parameter. Urutan resolusi (spesifik → umum) ada di
  ## `platform/param` (spec §10.2), bukan di sini.
  ParamScopeType* = enum
    pstGlobal = "GLOBAL"
    pstInstitution = "INSTITUTION"
    pstBranch = "BRANCH"
    pstProduct = "PRODUCT"
    pstSegment = "SEGMENT"
    pstRole = "ROLE"

  ## Sensitivitas perubahan (spec §10.2): CRITICAL = 4-eyes + approval berjenjang.
  ParamSensitivity* = enum
    psNormal = "NORMAL"
    psCritical = "CRITICAL"

  ## Tipe nilai parameter yang boleh dideklarasikan di `params.yaml`.
  ## Pemetaan ke Nim/TS didefinisikan di `tools/paramgen`.
  ParamValueType* = enum
    pvtInteger = "integer"
    pvtDecimal = "decimal"
    pvtString = "string"
    pvtBool = "bool"
    pvtJson = "json"
    pvtEnum = "enum"
    pvtMoney = "money"
    pvtRate = "rate"
    pvtDate = "date"

  ## Key parameter bertipe. Konversi dari string hanya boleh dilakukan oleh kode hasil
  ## generate (spec §10.4 "compile-time": key tak terdaftar = error compile).
  ParamKey*[T] = distinct string

  ## Metadata satu definisi parameter — bentuk di memori yang dipakai startup check
  ## (spec §10.4) dan drift guard. `scopes` adalah himpunan; urutan resolusi bukan urusan sini.
  ParamDefinition* = object
    key*: string
    module*: string
    valueType*: ParamValueType
    scopes*: set[ParamScopeType]
    sensitivity*: ParamSensitivity
    requiresApproval*: bool
    regulatoryRefs*: seq[string]
    descriptionKey*: string
    sinceVersion*: string

proc paramKey*[T](key: string): ParamKey[T] {.inline.} =
  ## Hanya untuk kode hasil generate dan test. Nama sengaja tidak "enak dipakai".
  ParamKey[T](key)

proc keyString*[T](k: ParamKey[T]): string {.inline.} =
  string(k)

proc `$`*[T](k: ParamKey[T]): string {.inline.} =
  string(k)

proc valueTypeName*(t: ParamValueType): string {.inline.} =
  $t

proc scopeTypeName*(s: ParamScopeType): string {.inline.} =
  $s

proc sensitivityName*(s: ParamSensitivity): string {.inline.} =
  $s

const paramScopeResolutionOrder* = [
  ## Urutan resolusi nilai: paling spesifik lebih dulu (spec §10.2).
    ## Satu tempat saja; dipakai `platform/param` dan diuji di sana.
  pstProduct, pstBranch, pstInstitution, pstSegment, pstRole, pstGlobal
]
