## Registry task day-close (spec §11.4) — murni, tanpa I/O.
##
## Kontrak yang ditegakkan saat registrasi (fail-fast saat boot, bukan saat run):
##   - id unik, berawalan `<module>.`, dan modulnya sama dengan field `module`;
##   - level tidak kosong, `run` terisi, `countChunks` terisi bila partisi `BY_CHUNK_COUNT`;
##   - dependensi **sudah terdaftar** (urutan boot menentukan DAG) dan tidak menunjuk diri sendiri.
##
## Dengan aturan "dependensi harus sudah terdaftar", siklus tidak mungkin terbentuk. `resolve`
## tetap memakai topological sort (Kahn) supaya urutan eksekusi deterministik dan pelanggaran
## kontrak (mis. registry dimutasi dari luar tipe) tetap terdeteksi.

import std/[algorithm, strutils, tables]

import kernel/dayclose

import ./types

type
  Registry* = ref object
    order*: seq[TaskId]
    byId*: Table[TaskId, DayCloseTask]

proc newRegistry*(): Registry =
  Registry(order: @[], byId: initTable[TaskId, DayCloseTask]())

proc validModuleName*(s: string): bool =
  if s.len == 0 or s[0] < 'a' or s[0] > 'z':
    return false
  for ch in s:
    if ch notin {'a' .. 'z', '0' .. '9', '-'}:
      return false
  true

proc register*(r: Registry, task: DayCloseTask) =
  ## Raise `DayCloserError` (bukan Result): registrasi berjalan sekali saat boot, dan registry
  ## yang salah harus menghentikan proses — bukan diteruskan dengan task yang hilang.
  if task.id.len == 0:
    raise newException(DayCloserError, "task day-close tanpa id")
  if not validModuleName(task.module):
    raise newException(DayCloserError,
      "modul task tidak sah ('" & task.module & "') untuk task " & task.id)
  if not task.id.startsWith(task.module & "."):
    raise newException(DayCloserError,
      "id task harus berawalan '" & task.module & ".': " & task.id)
  if task.id.len <= task.module.len + 1:
    raise newException(DayCloserError, "id task kosong setelah awalan modul: " & task.id)
  if task.id in r.byId:
    raise newException(DayCloserError, "task day-close ganda: " & task.id)
  if task.levels == {}:
    raise newException(DayCloserError, "task " & task.id & " tanpa level penutupan")
  if task.run.isNil:
    raise newException(DayCloserError, "task " & task.id & " tanpa prosedur run")
  if task.partition == psByChunkCount and task.countChunks.isNil:
    raise newException(DayCloserError,
      "task " & task.id & " memakai BY_CHUNK_COUNT tanpa countChunks")
  for dep in task.dependsOn:
    if dep == task.id:
      raise newException(DayCloserError, "task " & task.id & " bergantung pada dirinya")
    if dep notin r.byId:
      raise newException(DayCloserError,
        "task " & task.id & " bergantung pada task yang belum terdaftar: " & dep)
  for key in task.requiredParams:
    if key.strip.len == 0:
      raise newException(DayCloserError, "task " & task.id & " punya requiredParams kosong")
  r.byId[task.id] = task
  r.order.add task.id

proc len*(r: Registry): int =
  r.order.len

proc contains*(r: Registry, id: TaskId): bool =
  id in r.byId

proc taskById*(r: Registry, id: TaskId): DayCloseTask =
  if id notin r.byId:
    raise newException(DayCloserError, "task day-close tidak terdaftar: " & id)
  r.byId[id]

proc all*(r: Registry): seq[DayCloseTask] =
  for id in r.order:
    result.add r.byId[id]

proc resolve*(r: Registry, levels: set[CloseLevel]): seq[DayCloseTask] =
  ## Task yang relevan untuk himpunan level tersebut, urut topologis (deterministik: id
  ## terkecil lebih dulu di antara yang siap). `levels` harus berupa kaskade kalender lengkap
  ## (mis. EOM menyertakan EOD), karena dependensi lintas level tidak ditambahkan diam-diam.
  if levels == {}:
    raise newException(DayCloserError, "resolve dipanggil tanpa level penutupan")
  var selected: seq[TaskId]
  for id in r.order:
    let t = r.byId[id]
    var relevant = false
    for lvl in t.levels:
      if lvl in levels:
        relevant = true
        break
    if relevant:
      selected.add id
  for id in selected:
    for dep in r.byId[id].dependsOn:
      if dep notin selected:
        raise newException(DayCloserError,
          "task " & id & " bergantung pada " & dep &
          " yang tidak termasuk level " & levelsCsv(levels))

  var indegree = initTable[TaskId, int]()
  var dependents = initTable[TaskId, seq[TaskId]]()
  for id in selected:
    indegree[id] = 0
    dependents[id] = @[]
  for id in selected:
    for dep in r.byId[id].dependsOn:
      indegree[id] = indegree[id] + 1
      dependents[dep].add id

  var ready: seq[TaskId]
  for id in selected:
    if indegree[id] == 0:
      ready.add id
  ready.sort()

  while ready.len > 0:
    let id = ready[0]
    ready.delete(0)
    result.add r.byId[id]
    for dep in dependents[id]:
      indegree[dep] = indegree[dep] - 1
      if indegree[dep] == 0:
        ready.add dep
    ready.sort()

  if result.len != selected.len:
    raise newException(DayCloserError,
      "siklus dependensi task day-close terdeteksi (" & $selected.len & " task, " &
      $result.len & " terurut)")
