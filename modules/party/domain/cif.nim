## Format nomor CIF (T-070, spec §10.5 "format nomor … check digit").
##
## Murni: tidak menyentuh DB/parameter. **Bentuk** nomor (prefix, lebar urutan, ada/tidak check
## digit) datang dari parameter `party.cif.format`; yang tinggal di kode hanyalah cara membaca pola
## itu dan algoritme check digit (Luhn mod 10).
##
## Token yang dipahami:
##   `{seq}`   nomor urut apa adanya
##   `{seq:N}` nomor urut dengan lebar N, dipad nol di kiri (harus muat)
##   `{check}` digit Luhn; hanya boleh muncul sekali dan **hanya di akhir**
##
## Sisanya literal. Nomor yang dihasilkan dibatasi karakter aman untuk nomor bisnis
## (`A-Z a-z 0-9 - _ . /`) dan panjang maksimum 32 (batas kolom `party.party.cif`).

import std/strutils

const
  maxCifLength* = 32 # nomagic:ok batas teknis kolom party.party.cif
  maxSeqWidth = 18   # nomagic:ok batas teknis: jumlah digit maksimum nilai int64
  digitBase = ord('9') - ord('0') + 1
  maxDigit = ord('9') - ord('0')
  cifChars = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_', '.', '/'}

proc luhnCheckDigit*(payload: string): char =
  ## Digit Luhn untuk `payload` sehingga `payload & hasil` lolos verifikasi mod 10.
  ## Hanya karakter digit yang dihitung; literal non-digit dilewati (bukan dianggap nol).
  ## Raise `ValueError` bila payload tidak memuat satu digit pun.
  var sum = 0
  var seenDigit = false
  var doubleNext = true
  for i in countdown(payload.high, 0):
    let c = payload[i]
    if c notin {'0' .. '9'}:
      continue
    seenDigit = true
    var d = ord(c) - ord('0')
    if doubleNext:
      d *= 2
      if d > maxDigit:
        d -= maxDigit
    sum += d
    doubleNext = not doubleNext
  if not seenDigit:
    raise newException(ValueError, "payload CIF tidak memuat digit")
  chr(ord('0') + ((digitBase - (sum mod digitBase)) mod digitBase))

proc formatCif*(pattern: string, seqNo: int64): string =
  ## Menyusun nomor CIF dari pola parameter dan nomor urut.
  ## Raise `ValueError` untuk pola/urutan yang tidak sah — konfigurasi rusak harus terlihat,
  ## bukan menghasilkan nomor aneh.
  if seqNo < 1:
    raise newException(ValueError, "nomor urut CIF minimal 1")
  if pattern.len == 0:
    raise newException(ValueError, "pola CIF kosong")

  var payload = ""
  var seenSeq = false
  var seenCheck = false
  var i = 0
  while i < pattern.len:
    let c = pattern[i]
    if c == '{':
      let close = pattern.find('}', i + 1)
      if close < 0:
        raise newException(ValueError, "token CIF tidak ditutup: " & pattern)
      let token = pattern[i + 1 ..< close]
      if token == "check":
        if seenCheck:
          raise newException(ValueError, "token {check} hanya boleh sekali")
        if close != pattern.high:
          raise newException(ValueError, "token {check} harus di akhir pola")
        seenCheck = true
      elif token == "seq" or token.startsWith("seq:"):
        if seenSeq:
          raise newException(ValueError, "token {seq...} hanya boleh sekali")
        seenSeq = true
        var width = 0
        if token.len > "seq:".len:
          let rawWidth = token["seq:".len .. ^1]
          for ch in rawWidth:
            if ch notin {'0' .. '9'}:
              raise newException(ValueError, "lebar {seq} bukan angka: " & rawWidth)
          width = parseInt(rawWidth)
          if width < 1 or width > maxSeqWidth:
            raise newException(ValueError, "lebar {seq} harus 1..18")
        let digits = $seqNo
        if width > 0:
          if digits.len > width:
            raise newException(ValueError,
              "nomor urut " & digits & " tidak muat di lebar " & $width)
          payload.add repeat('0', width - digits.len)
        payload.add digits
      else:
        raise newException(ValueError, "token CIF tidak dikenal: {" & token & "}")
      i = close + 1
    elif c == '}':
      raise newException(ValueError, "tanda } tanpa pembuka di pola CIF")
    else:
      payload.add c
      inc i

  if not seenSeq:
    raise newException(ValueError, "pola CIF wajib memuat {seq...}")

  var rendered = payload
  if seenCheck:
    rendered.add luhnCheckDigit(payload)

  if rendered.len == 0 or rendered.len > maxCifLength:
    raise newException(ValueError,
      "panjang CIF harus 1.." & $maxCifLength & " (dapat " & $rendered.len & ")")
  for ch in rendered:
    if ch notin cifChars:
      raise newException(ValueError, "karakter CIF tidak sah: " & $ch)
  rendered
