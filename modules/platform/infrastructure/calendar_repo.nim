## Repository kalender kerja & business date (spec §9.3, §11.2).
##
## Tidak ada nilai kalender di kode: bentuk akhir pekan & awal tahun fiskal dibaca lewat
## parameter framework (T-005), hari libur dari `platform.holiday`. Bila parameter wajib tidak
## punya nilai aktif → error (spec §10.6), bukan fallback diam-diam.
##
## Catatan scope: parameter dibaca dengan lookup yang hanya mengisi id untuk scope pemanggil.
## Nilai level INSTITUTION (dengan id konkret) belum ikut terasa dari konteks BRANCH — lihat
## `docs/tasks/T-007.md` (keterbatasan yang dicatat, bukan bug yang disembunyikan).

import std/[json, options]

import db_connector/db_postgres

import ../domain/[calendar, scope]
import ./param_repo
import kernel/[businessdate, ids, paramkey, result]
import kernel/generated/paramkeys

type
  BusinessDateRow* = object
    scopeType*: ParamScopeType
    scopeId*: string
    currentDate*: string
    state*: BusinessDateState
    updatedAt*: string

  WorkingDayInfo* = object
    ## Hasil satu pemeriksaan tanggal: mengapa hari kerja/non-kerja + level penutupannya.
    date*: string
    isWeekend*: bool
    isHoliday*: bool
    isWorkingDay*: bool
    closeLevels*: set[CloseLevel]

proc paramJson*[T](db: DbConn, key: ParamKey[T], scope: ScopeRef,
                   asOf: string): JsonNode =
  ## Nilai parameter wajib ada pada `asOf` untuk scope tersebut (lihat `activeValueJson`).
  db.activeValueJson(keyString(key), asOf, lookupFor(scope))

proc addHoliday*(db: DbConn, scope: ScopeRef, holidayDate, nameKey: string,
                 recurring = false): bool =
  ## Menambah hari libur. Mengembalikan `false` bila sudah ada (idempotent).
  db.execAffectedRows(sql"""
    INSERT INTO platform.holiday (scope_type, scope_id, holiday_date, name_key, recurring_annual)
    VALUES (?, NULLIF(?, ''), ?::date, ?, ?)
    ON CONFLICT (scope_type, COALESCE(scope_id, ''), holiday_date) DO NOTHING""",
    $scope.scopeType, scope.scopeId, holidayDate, nameKey, recurring) == 1

proc holidayRows*(db: DbConn, scope: ScopeRef): seq[(string, bool)] =
  ## Semua hari libur yang relevan untuk scope: institusi akar + scope pemanggil.
  for row in db.getAllRows(sql"""
    SELECT holiday_date::text, recurring_annual FROM platform.holiday
     WHERE (scope_type = 'INSTITUTION' AND scope_id IS NULL)
        OR (scope_type = ? AND coalesce(scope_id, '') = ?)
     ORDER BY holiday_date""", $scope.scopeType, scope.scopeId):
    result.add (row[0], row[1] == "t")

proc holidayDates*(db: DbConn, scope: ScopeRef, fromYear, toYear: int): seq[string] =
  ## Tanggal libur sebagai ISO. Baris `recurring_annual` diperluas ke setiap tahun rentang
  ## (tahun tersimpannya ikut, karena bulan/tanggal itulah yang berulang); 29 Februari pada
  ## tahun non-kabisat dilewati karena tanggalnya memang tidak ada.
  for (iso, recurring) in holidayRows(db, scope):
    let parsed = parseBusinessDate(iso)
    if parsed.isErr:
      raise newException(ValueError, "tanggal libur tidak sah: " & iso)
    let d = parsed.value()
    if not recurring:
      if d.year >= fromYear and d.year <= toYear:
        result.add iso
      continue
    for y in fromYear .. toYear:
      let expanded = businessDate(y, d.month, d.day)
      if expanded.isOk:
        result.add expanded.value().toIso

proc calendarShape*(db: DbConn, scope: ScopeRef, asOf: string): CalendarShape =
  ## Bentuk kalender efektif pada `asOf`. Hari libur diambil rentang tahun `asOf` ±1 supaya
  ## perhitungan hari kerja di sekitar pergantian tahun tetap benar.
  let parsed = parseBusinessDate(asOf)
  if parsed.isErr:
    raise newException(ValueError, "tanggal acuan tidak sah: " & asOf)
  let year = parsed.value().year
  result.weekendDays =
    parseWeekendDays(db.paramJson(P_platform_calendar_weekend_days, scope, asOf))
  result.fiscalYearStartMonth =
    int(db.paramJson(P_platform_calendar_fiscal_year_start_month, scope, asOf).getInt)
  result.holidays = holidaySet(holidayDates(db, scope, year - 1, year + 1))

proc workingDayInfo*(db: DbConn, scope: ScopeRef, date: string): WorkingDayInfo =
  let shape = calendarShape(db, scope, date)
  let parsed = parseBusinessDate(date)
  if parsed.isErr:
    raise newException(ValueError, "tanggal tidak sah: " & date)
  let d = parsed.value()
  result.date = d.toIso
  result.isWeekend = isWeekend(d, shape.weekendDays)
  result.isHoliday = isHoliday(d, shape.holidays)
  result.isWorkingDay = isWorkingDay(d, shape)
  result.closeLevels = closeLevelsFor(d, shape)

proc businessDateOf*(db: DbConn, scope: ScopeRef): Option[BusinessDateRow] =
  let found = db.singleRow(sql"""
    SELECT scope_type, coalesce(scope_id, ''), current_business_date::text, state,
           to_char(updated_at, 'YYYY-MM-DD"T"HH24:MI:SSOF')
      FROM platform.business_date
     WHERE scope_type = ? AND coalesce(scope_id, '') = ?""",
    $scope.scopeType, scope.scopeId)
  if found.isNone:
    return none(BusinessDateRow)
  let row = found.get()
  some BusinessDateRow(
    scopeType: scope.scopeType,
    scopeId: row[1],
    currentDate: row[2],
    state: parseState(row[3]),
    updatedAt: row[4])

proc ensureBusinessDate*(db: DbConn, scope: ScopeRef, date: string,
                         actor: Id): bool =
  ## Membuat baris tanggal buku bila belum ada (bootstrap institusi baru).
  ## Mengembalikan `false` bila barisnya sudah ada — tidak menimpa tanggal yang berjalan.
  db.execAffectedRows(sql"""
    INSERT INTO platform.business_date
      (scope_type, scope_id, current_business_date, state, updated_by)
    VALUES (?, NULLIF(?, ''), ?::date, 'OPEN', ?::uuid)
    ON CONFLICT (scope_type, COALESCE(scope_id, '')) DO NOTHING""",
    $scope.scopeType, scope.scopeId, date, $actor) == 1

proc transitionBusinessDate*(db: DbConn, scope: ScopeRef, expected, next: BusinessDateState,
                             actor: Id): bool =
  ## Transisi state dengan penjagaan ganda (spec §11.3):
  ##   - `canTransition` menolak jalur ilegal apa pun (raise `ValueError`);
  ##   - `WHERE ... state = expected` menolak bila state DB sudah bergeser (return `false`).
  if not canTransition(expected, next):
    raise newException(ValueError,
      "transisi business date ilegal: " & $expected & " → " & $next)
  db.execAffectedRows(sql"""
    UPDATE platform.business_date
       SET state = ?, updated_at = now(), updated_by = ?::uuid
     WHERE scope_type = ? AND coalesce(scope_id, '') = ? AND state = ?""",
    $next, $actor, $scope.scopeType, scope.scopeId, $expected) == 1

proc rollOverBusinessDate*(db: DbConn, scope: ScopeRef, nextDate: string,
                           actor: Id): bool =
  ## Rollover: baris yang sudah `CLOSED` pindah ke tanggal buku berikutnya dengan state
  ## `OPEN`. Hanya sah dari `CLOSED` (return `false` bila belum ditutup).
  ## Tanggalnya sendiri **tidak** divalidasi di sini — pemanggil memakai `nextWorkingDay`
  ## dari kalender supaya konsisten dengan hari libur/akhir pekan.
  db.execAffectedRows(sql"""
    UPDATE platform.business_date
       SET current_business_date = ?::date, state = 'OPEN', updated_at = now(),
           updated_by = ?::uuid
     WHERE scope_type = ? AND coalesce(scope_id, '') = ? AND state = 'CLOSED'""",
    nextDate, $actor, $scope.scopeType, scope.scopeId) == 1
