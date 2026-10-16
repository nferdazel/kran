## Test enkripsi field-level (T-054). Tanpa DB.
##
## **Vektor di bawah bukan keluaran kode ini, juga bukan dari pustaka yang sama.** AES-256-GCM
## dan KDF (HMAC-SHA256) dihitung independen dengan Node `node:crypto` (preseden
## `platform/tests/tpassword.nim`, yang memakai oracle Python). Perintah pembuatnya:
##
##   node -e '
##     const {createCipheriv,createHmac}=require("node:crypto");
##     const b64url=b=>Buffer.from(b).toString("base64").replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
##     const KEK=Buffer.from("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f","hex");
##     const H=(k,m)=>createHmac("sha256",k).update(m).digest();
##     const dek=H(KEK,"kran:dek:v1:party");
##     const nonce=Buffer.from("000102030405060708090a0b","hex");
##     const c=createCipheriv("aes-256-gcm",dek,nonce); c.setAAD(Buffer.from("party"));
##     const ct=Buffer.concat([c.update(Buffer.from("3172010101900001")),c.final()]);
##     console.log("kekB64  =",KEK.toString("base64"));
##     console.log("cipher  =","kran:enc:v1:v1:"+b64url(nonce)+":"+b64url(Buffer.concat([ct,c.getAuthTag()])));
##     console.log("bidx    =",createHmac("sha256",H(KEK,"kran:bidx:v1:party")).update("3172010101900001").digest("hex"));
##   '
##
## Jadi test ini membandingkan implementasi Nim dengan oracle lain, bukan dengan dirinya sendiri.

import std/[base64, os, strutils, tables, unittest]

import "platform-lib/crypto/fieldcrypto"

const
  # base64 dari 32 byte 0x00..0x1f
  kekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
  # Node: AES-256-GCM(dek=HMAC(KEK,"kran:dek:v1:party"), nonce=000102..0b, aad="party",
  #        pt="3172010101900001")
  cipherParty = "kran:enc:v1:v1:AAECAwQFBgcICQoL:utKc0AfZ5julO4UsqmEC-CCWKDBJvycT56JLVh5C_LI"
  # Node: HMAC(HMAC(KEK,"kran:bidx:v1:party"), "3172010101900001")
  bidxParty = "14af987dc0befac0259ba76fc902c97e64dd9233ed1135efe647ed6cb4032ccf"
  bidxParty2 = "882b5ee5f1bc05fce79a463c45e6dd781bf3d0833b0ca9e22b717c8fd7d125a9"

let tmpRoot = getTempDir() / ("kran-fieldcrypto-" & $getCurrentProcessId())
createDir(tmpRoot)

proc kekContent(): string =
  "v1:" & kekB64 & "\n"

proc fc1(): FieldCrypto =
  parseKekFile(kekContent(), "test-kek")

proc writeKek(name, content: string, mode600 = true): string =
  result = tmpRoot / name
  writeFile(result, content)
  when not defined(windows):
    if mode600:
      setFilePermissions(result, {fpUserRead, fpUserWrite})
    else:
      setFilePermissions(result, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})

proc enc(data: string): string =
  base64.encode(data, safe = true).strip(chars = {'='})

proc decErr(fc: FieldCrypto, table, ct: string): bool =
  ## `true` bila dekripsi gagal dengan `DecryptError` (bukan mengembalikan output apa pun).
  try:
    discard decryptField(fc, table, ct)
    false
  except DecryptError:
    true

suite "fieldcrypto: vektor independen Node (AES-256-GCM + KDF)":
  test "ciphertext buatan Node didekripsi Nim (AES-256-GCM + KDF cocok)":
    check decryptField(fc1(), "party", cipherParty) == "3172010101900001"

  test "blind index cocok dengan oracle Node (KDF double-HMAC)":
    check blindIndex(fc1(), "party", "3172010101900001") == bidxParty
    check blindIndex(fc1(), "party", "3172010101900002") == bidxParty2

  test "kunci aktif ditandai kid di ciphertext":
    check cipherParty.startsWith("kran:enc:v1:v1:")

suite "fieldcrypto: roundtrip":
  test "berbagai panjang, termasuk kosong & multibyte":
    for pt in ["", "a", "ab", "x".repeat(15), "x".repeat(16), "x".repeat(17),
               "x".repeat(31), "x".repeat(32), "x".repeat(1000),
               "Ibu Siti Ångström 😀", "NIK 3172 0101 0190 0001, alamat: Jl. Mawar No. 5"]:
      let ct = encryptField(fc1(), "party", pt)
      check ct.startsWith("kran:enc:v1:v1:")
      check decryptField(fc1(), "party", ct) == pt

  test "100 iterasi: setiap dekripsi tetap benar":
    var state = 12345'u64
    for i in 0 ..< 100:
      state = state * 6364136223846793005'u64 + 1442695040888963407'u64
      let n = int(state shr 33) mod 300
      var pt = newStringOfCap(n)
      for j in 0 ..< n:
        pt.add char(32 + (j mod 95))
      let ct = encryptField(fc1(), "party", pt)
      check decryptField(fc1(), "party", ct) == pt

  test "nonce acak: dua enkripsi plaintext sama menghasilkan ciphertext berbeda":
    let a = encryptField(fc1(), "party", "rahasia")
    let b = encryptField(fc1(), "party", "rahasia")
    check a != b
    check decryptField(fc1(), "party", a) == "rahasia"
    check decryptField(fc1(), "party", b) == "rahasia"

  test "plaintext tidak tersimpan apa adanya":
    let ct = encryptField(fc1(), "party", "3172010101900001")
    check not ct.contains("3172010101900001")

suite "fieldcrypto: tamper & AAD":
  test "bit dibalik di ciphertext/tag/nonce → DecryptError":
    let ct = encryptField(fc1(), "party", "rahasia-nik")
    var parts = ct.split(':')
    check parts.len == 6
    # ciphertext (bagian awal blob)
    var blob = base64.decode(parts[5])
    blob[0] = chr(ord(blob[0]) xor 1)
    parts[5] = enc(blob)
    check decErr(fc1(), "party", parts.join(":"))
    # tag (16 byte terakhir blob)
    parts = ct.split(':')
    var blob2 = base64.decode(parts[5])
    blob2[^1] = chr(ord(blob2[^1]) xor 1)
    parts[5] = enc(blob2)
    check decErr(fc1(), "party", parts.join(":"))
    # nonce
    parts = ct.split(':')
    var nonce = base64.decode(parts[4])
    nonce[0] = chr(ord(nonce[0]) xor 1)
    parts[4] = enc(nonce)
    check decErr(fc1(), "party", parts.join(":"))

  test "kid diubah/dihilangkan → DecryptError":
    var parts = cipherParty.split(':')
    parts[3] = "v9"
    check decErr(fc1(), "party", parts.join(":"))
    parts[3] = ""
    check decErr(fc1(), "party", parts.join(":"))

  test "versi algoritme / format tak dikenal → DecryptError":
    for bad in [cipherParty.replace("kran:enc:v1:", "kran:enc:v2:"),
                cipherParty.replace("kran:enc:v1:", "kran:enc:v0:"),
                "kran:enc:v1:v1:not-base64!!:x",
                "kran:enc:v1:v1:AAECAwQFBgcICQoL",
                "apa saja",
                ""]:
      check decErr(fc1(), "party", bad)

  test "ciphertext tabel A didekripsi sebagai tabel B → gagal (AAD + DEK berbeda)":
    let ct = encryptField(fc1(), "party", "rahasia-nik")
    check decryptField(fc1(), "party", ct) == "rahasia-nik"
    check decErr(fc1(), "lending", ct)
    check decErr(fc1(), "users", ct)
    # vektor Node (aad "party") juga harus gagal di tabel lain
    check decErr(fc1(), "lending", cipherParty)

suite "fieldcrypto: konfigurasi/keyring (berkas KEK)":
  test "KRAN_KEK_FILE kosong → belum terkonfigurasi, enkripsi/dekripsi menolak":
    var fc = fieldCryptoFromEnv(initTable[string, string]())
    check not fc.isConfigured
    expect NotConfiguredError:
      discard encryptField(fc, "party", "x")
    expect NotConfiguredError:
      discard decryptField(fc, "party", cipherParty)
    expect NotConfiguredError:
      discard blindIndex(fc, "party", "x")

  test "KRAN_KEK_FILE diisi berkas sah → terkonfigurasi saat startup":
    let path = writeKek("valid.key", kekContent())
    var env = initTable[string, string]()
    env[envVarKekFile] = path
    let fc = fieldCryptoFromEnv(env)
    check fc.isConfigured
    check fc.activeKid == "v1"
    check decryptField(fc, "party", cipherParty) == "3172010101900001"

  test "KRAN_KEK_FILE diisi berkas rusak → KekError saat startup (tolak start)":
    let path = writeKek("corrupt.key", "bukan-format\n")
    var env = initTable[string, string]()
    env[envVarKekFile] = path
    expect KekError:
      discard fieldCryptoFromEnv(env)

  test "fieldCryptoFromProcessEnv membaca KRAN_KEK_FILE dari proses":
    let path = writeKek("process-env.key", kekContent())
    putEnv(envVarKekFile, path)
    check fieldCryptoFromProcessEnv().isConfigured
    delEnv(envVarKekFile)
    check not fieldCryptoFromProcessEnv().isConfigured

  test "berkas KEK hilang → KekError eksplisit":
    var raised = false
    try:
      discard loadKekFile(tmpRoot / "tidak-ada.key")
    except KekError as e:
      raised = true
      check e.msg.contains("tidak ditemukan")
    check raised

  test "berkas KEK kosong / hanya komentar → KekError":
    for content in ["", "\n\n", "# hanya komentar\n"]:
      expect KekError:
        discard parseKekFile(content, "x")

  test "format baris, kid, dan panjang kunci divalidasi":
    expect KekError:
      discard parseKekFile("tanpa-pemisah\n", "x")
    expect KekError:
      discard parseKekFile("bad kid:" & kekB64 & "\n", "x")
    expect KekError:
      discard parseKekFile("v1:!!bukan-base64!!\n", "x")
    expect KekError:
      discard parseKekFile("v1:" & enc("hanya-16-byte!!") & "\n", "x")
    expect KekError:
      discard parseKekFile("v1:\n", "x")
    expect KekError:
      discard parseKekFile("v1:" & kekB64 & "\nv1:" & kekB64 & "\n", "x")

  test "beberapa kunci: kunci aktif = entri terakhir, kunci lama tetap bisa dekripsi":
    let kek2 = base64.encode(repeat('\xAA', keyBytes))
    let fc = parseKekFile("v1:" & kekB64 & "\nv2:" & kek2 & "\n", "x")
    check fc.activeKid == "v2"
    # vektor lama (kid v1) tetap terbaca walau aktif = v2
    check decryptField(fc, "party", cipherParty) == "3172010101900001"
    let ct = encryptField(fc, "party", "rahasia")
    check ct.startsWith("kran:enc:v1:v2:")
    check decryptField(fc, "party", ct) == "rahasia"

  test "mode berkas bukan 600 → KekError":
    when not defined(windows):
      expect KekError:
        discard loadKekFile(writeKek("world-readable.key", kekContent(), mode600 = false))

  test "nama tabel kosong ditolak":
    expect FieldCryptoError:
      discard encryptField(fc1(), "", "x")
    expect FieldCryptoError:
      discard blindIndex(fc1(), "", "x")

suite "fieldcrypto: blind index":
  test "deterministik, peka nilai & tabel, dan tidak membocorkan nilai":
    let fc = fc1()
    check blindIndex(fc, "party", "3172010101900001") ==
      blindIndex(fc, "party", "3172010101900001")
    check blindIndex(fc, "party", "3172010101900001") !=
      blindIndex(fc, "party", "3172010101900002")
    check blindIndex(fc, "party", "3172010101900001") !=
      blindIndex(fc, "users", "3172010101900001")
    for h in [blindIndex(fc, "party", "3172010101900001"),
              blindIndex(fc, "party", "")]:
      check not h.contains("3172010101900001")
      check h.len == 64

  test "kunci berbeda → indeks berbeda":
    let a = parseKekFile("v1:" & kekB64 & "\n", "a")
    let b = parseKekFile("v1:" & base64.encode(repeat('\x11', keyBytes)) & "\n", "b")
    check blindIndex(a, "party", "3172010101900001") !=
      blindIndex(b, "party", "3172010101900001")

  test "normalizeDigits untuk field angka (NIK/NPWP/no. HP)":
    check normalizeDigits(" 3172-0101.0190 0001 ") == "3172010101900001"
    check normalizeDigits("+62 812-3456-7890") == "6281234567890"
    check normalizeDigits("abcXYZ") == ""
    check blindIndex(fc1(), "party", normalizeDigits("3172 0101 0190 0001")) == bidxParty

suite "fieldcrypto: tanpa kebocoran rahasia":
  test "pesan galat tidak memuat plaintext maupun materi kunci":
    let fc = fc1()
    var parts = encryptField(fc, "party", "nik-rahasia-3172010101900001").split(':')
    var blob = base64.decode(parts[5])
    blob[0] = chr(ord(blob[0]) xor 1)
    parts[5] = enc(blob)
    var raised = false
    try:
      discard decryptField(fc, "party", parts.join(":"))
    except DecryptError as e:
      raised = true
      check not e.msg.contains("nik-rahasia")
      check not e.msg.contains("3172010101900001")
      check not e.msg.contains(kekB64)
    check raised

  test "kid tak dikenal dilaporkan tapi bukan materi kunci":
    var raised = false
    try:
      discard decryptField(fc1(), "party", "kran:enc:v1:v9:AAECAwQFBgcICQoL:AAAA")
    except DecryptError as e:
      raised = true
      check e.msg.contains("v9")
      check not e.msg.contains(kekB64)
    check raised

removeDir(tmpRoot)
