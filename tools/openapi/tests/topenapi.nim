import std/[json, os, strutils, unittest]

import ../lib

## Test `tools/openapi` (spec §20 contract test). Kontrak contoh ditulis ke direktori sementara
## supaya tiap kasus bisa diuji terpisah tanpa menyentuh kontrak asli.

const contohKontrak = """
openapi: 3.1.0
info:
  title: Contoh
  version: 0.0.0
paths:
  /healthz:
    get:
      operationId: getHealth
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Health"
        "405":
          $ref: "#/components/responses/Problem"
  /api/v1/sesi:
    get:
      operationId: getSession
      security:
        - sessionCookie: []
      responses:
        "200":
          description: ok
        "405":
          $ref: "#/components/responses/Problem"
        "501":
          $ref: "#/components/responses/Problem"
        "503":
          $ref: "#/components/responses/Problem"
components:
  schemas:
    Health:
      type: object
      additionalProperties: false
      required: [status, version, uptimeSeconds, role]
      properties:
        status:
          type: string
          enum: [ok]
        version:
          type: string
        uptimeSeconds:
          type: integer
          minimum: 0
        role:
          type: string
          enum: [api, worker, ctl, migrate]
"""

proc writeTemp(content: string, name: string): string =
  let dir = getTempDir() / "openapi-test"
  createDir(dir)
  result = dir / name
  writeFile(result, content)

proc route(httpMethod, path, operationId: string): DeclaredRoute =
  DeclaredRoute(httpMethod: httpMethod, path: path, operationId: operationId)

suite "loadContract":
  test "operasi terbaca dengan method huruf besar":
    let c = loadContract(contohKontrak, "contoh")
    check c.operations.len == 2
    check c.operations[0].path == "/healthz"
    check c.operations[0].httpMethod == "GET"
    check c.operations[0].operationId == "getHealth"

  test "bukan OpenAPI = error jelas":
    expect ValueError:
      discard loadContract("title: bukan openapi\n", "contoh")

  test "tanpa paths = error jelas":
    expect ValueError:
      discard loadContract("openapi: 3.1.0\n", "contoh")

  test "file tidak ada = error jelas":
    expect ValueError:
      discard loadContractFile("/tmp/tidak-ada-kontrak-ini.yaml")

  test "file dari disk terbaca":
    let path = writeTemp(contohKontrak, "contoh.yaml")
    check loadContractFile(path).operations.len == 2
    removeFile(path)

suite "findings (parity rute vs kontrak)":
  test "sama = tanpa temuan":
    let c = loadContract(contohKontrak, "contoh")
    check findings(@[route("GET", "/healthz", "getHealth"),
                      route("GET", "/api/v1/sesi", "getSession")], c).len == 0

  test "rute implementasi yang tidak ada di kontrak = temuan":
    let c = loadContract(contohKontrak, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                         route("GET", "/api/v1/sesi", "getSession"),
                         route("GET", "/debug", "getDebug")], c)
    check f.len == 1
    check "tidak ada di kontrak" in f[0]

  test "operasi kontrak yang belum diimplementasikan = temuan":
    let c = loadContract(contohKontrak, "contoh")
    let f = findings(@[], c)
    check f.len == 2
    for item in f:
      check "tidak diimplementasikan" in item

  test "operationId berbeda = temuan":
    let c = loadContract(contohKontrak, "contoh")
    let f = findings(@[route("GET", "/healthz", "healthCheck"),
                         route("GET", "/api/v1/sesi", "getSession")], c)
    check f.len == 1
    check "operationId tidak cocok" in f[0]

  test "operasi tanpa 405 = temuan (respons router tidak dideklarasikan)":
    let tanpa405 = contohKontrak.replace("""
        "405":
          $ref: "#/components/responses/Problem"
""", "")
    let c = loadContract(tanpa405, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                        route("GET", "/api/v1/sesi", "getSession")], c)
    check f.len == 2
    for item in f:
      check "tidak mendeklarasikan 405" in item

  test "operasi ber-auth tanpa 501 = temuan":
    let tanpa501 = contohKontrak.replace("""
        "501":
          $ref: "#/components/responses/Problem"
""", "")
    let c = loadContract(tanpa501, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                        route("GET", "/api/v1/sesi", "getSession")], c)
    check f.len == 1
    check "tidak mendeklarasikan 501" in f[0]

  test "operasi ber-auth tanpa 503 = temuan (penangan terakhir pool DB)":
    # 503 datang dari `router.errorHandler` untuk setiap operasi ber-DB, bukan dari handler:
    # kontrak yang tidak menyebutnya membuat klien menganggapnya mustahil.
    let tanpa503 = contohKontrak.replace("""        "503":
          $ref: "#/components/responses/Problem"
""", "")
    let c = loadContract(tanpa503, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                        route("GET", "/api/v1/sesi", "getSession")], c)
    check f.len == 1
    check "tidak mendeklarasikan 503" in f[0]

  test "operasi berbadan tanpa 415 = temuan (tipe media tidak dideklarasikan)":
    let denganBadan = contohKontrak.replace("""      security:
        - sessionCookie: []
""", """      security:
        - sessionCookie: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
""")
    let c = loadContract(denganBadan, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                        route("GET", "/api/v1/sesi", "getSession")], c)
    check f.len == 1
    check "tidak mendeklarasikan 415" in f[0]

  test "operasi berbadan dengan 415 = tanpa temuan":
    let denganBadan = contohKontrak.replace("""      security:
        - sessionCookie: []
      responses:
        "200":
          description: ok
""", """      security:
        - sessionCookie: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
      responses:
        "415":
          $ref: "#/components/responses/Problem"
        "200":
          description: ok
""")
    let c = loadContract(denganBadan, "contoh")
    check findings(@[route("GET", "/healthz", "getHealth"),
                      route("GET", "/api/v1/sesi", "getSession")], c).len == 0

  test "rute duplikat di tabel implementasi = temuan":
    let c = loadContract(contohKontrak, "contoh")
    let f = findings(@[route("GET", "/healthz", "getHealth"),
                         route("GET", "/api/v1/sesi", "getSession"),
                         route("GET", "/healthz", "getHealth")], c)
    check f.len == 1
    check "duplikat" in f[0]

suite "responseSchema":
  test "skema respons 200 diresolusi dari $ref":
    let c = loadContract(contohKontrak, "contoh")
    let schema = c.responseSchema("/healthz", "get", "200")
    check schema["type"].getStr() == "object"

  test "operasi yang tidak ada = error jelas":
    let c = loadContract(contohKontrak, "contoh")
    expect ValueError:
      discard c.responseSchema("/tidak-ada", "GET", "200")

  test "status yang tidak didefinisikan = error jelas":
    let c = loadContract(contohKontrak, "contoh")
    expect ValueError:
      discard c.responseSchema("/healthz", "GET", "418")

suite "validateValue (subset JSON Schema)":
  let kontrak = loadContract(contohKontrak, "contoh")
  let schema = kontrak.responseSchema("/healthz", "GET", "200")

  test "nilai sesuai skema = tanpa temuan":
    let value = %*{"status": "ok", "version": "0.1.0", "uptimeSeconds": 3, "role": "api"}
    check kontrak.validateValue(schema, value, "$").len == 0

  test "properti wajib hilang = temuan":
    let value = %*{"status": "ok", "version": "0.1.0"}
    let problems = kontrak.validateValue(schema, value, "$")
    check problems.len == 2
    check "uptimeSeconds" in problems[0]

  test "tipe salah = temuan":
    let value = %*{"status": "ok", "version": 1, "uptimeSeconds": 0, "role": "api"}
    let problems = kontrak.validateValue(schema, value, "$")
    check problems.len == 1
    check "version" in problems[0]
    check "integer" in problems[0]

  test "properti tambahan ditolak (additionalProperties: false)":
    let value = %*{"status": "ok", "version": "0.1.0", "uptimeSeconds": 0,
                   "role": "api", "extra": 1}
    let problems = kontrak.validateValue(schema, value, "$")
    check problems.len == 1
    check "extra" in problems[0]

  test "nilai di luar enum = temuan":
    let value = %*{"status": "degraded", "version": "0.1.0", "uptimeSeconds": 0, "role": "api"}
    let problems = kontrak.validateValue(schema, value, "$")
    check problems.len == 1
    check "enum" in problems[0]

  test "minimum dilanggar = temuan":
    let value = %*{"status": "ok", "version": "0.1.0", "uptimeSeconds": -1, "role": "api"}
    let problems = kontrak.validateValue(schema, value, "$")
    check problems.len == 1
    check "minimum" in problems[0]

  test "array diperiksa per elemen (lokasi menyebut indeks)":
    let c = loadContract("""
openapi: 3.1.0
info:
  title: Contoh
  version: 0.0.0
paths:
  /x:
    get:
      operationId: getX
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                type: object
                additionalProperties: false
                required: [checks]
                properties:
                  checks:
                    type: array
                    items:
                      type: object
                      additionalProperties: false
                      required: [name, status]
                      properties:
                        name:
                          type: string
                        status:
                          type: string
                          enum: [ok, failed]
""", "contoh2")
    let s = c.responseSchema("/x", "GET", "200")
    check c.validateValue(s, %*{"checks": [{"name": "db", "status": "ok"}]}, "$").len == 0
    let problems = c.validateValue(s, %*{"checks": [{"name": "db"}]}, "$")
    check problems.len == 1
    check "$.checks[0]" in problems[0]

suite "resolveRef":
  test "$ref eksternal ditolak":
    var kontrak = loadContract(contohKontrak, "contoh")
    expect ValueError:
      discard kontrak.resolveRef(%*{"$ref": "https://contoh/skema.yaml"})

  test "$ref tidak dikenal ditolak":
    var kontrak = loadContract(contohKontrak, "contoh")
    expect ValueError:
      discard kontrak.resolveRef(%*{"$ref": "#/components/schemas/TidakAda"})
