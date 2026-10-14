## Klien WebSocket minimal untuk uji (RFC 6455): handshake + frame text.
##
## Kenapa ditulis sendiri: `itapi_ws.nim` harus membuktikan peristiwa benar-benar sampai ke
## **klien nyata** lewat soket TCP, bukan hanya sampai ke objek hub. Menambah dependensi klien WS
## hanya untuk test akan menambah permukaan yang harus dipercaya; yang dibutuhkan di sini hanya
## handshake + frame text, dan itu ~170 baris.
##
## Batasan yang sengaja tidak diimplementasikan, dan **ditolak keras** (bukan diabaikan diam-diam):
## fragmentasi (`FIN=0`) dan kompresi (`permessage-deflate`) — server tidak memakainya.

# `std/sha1` ditandai deprecated di Nim 2.2 (mengarahkan ke paket `checksums` yang belum terpasang).
# SHA-1 di sini bukan pilihan keamanan: RFC 6455 mewajibkan SHA-1 pada handshake. Menambah
# dependensi demi menghilangkan peringatan itu tidak sebanding.
import std/[base64, json, net, random, sha1, strutils, times]

const WsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type
  WsClient* = object
    socket: Socket

  WsHandshake* = object
    status*: int
    headers*: seq[(string, string)]
    body*: string

proc close*(client: var WsClient) =
  ## Kirim frame close (0x8) lalu tutup soket; kegagalan diabaikan (koneksi mungkin sudah putus).
  try:
    client.socket.send("\x88\x80\0\0\0\0")
  except CatchableError:
    discard
  try:
    client.socket.close()
  except CatchableError:
    discard

proc readByte(socket: Socket, timeoutMs: int): string =
  ## Satu byte, atau "" bila tidak ada data dalam batas waktu.
  ## Nim menunggu **seluruh** `size` byte pada overload `recv(..., size, timeout)`, jadi untuk
  ## "baca apa pun yang tersedia" panjang harus 1 byte per panggilan.
  var chunk = ""
  try:
    if socket.recv(chunk, 1, timeout = timeoutMs) <= 0:
      return ""
  except TimeoutError:
    return ""
  chunk

proc readExact(socket: Socket, count, timeoutMs: int): string =
  while result.len < count:
    var chunk = ""
    let read = socket.recv(chunk, count - result.len, timeout = timeoutMs)
    if read <= 0:
      raise newException(IOError, "koneksi ditutup atau timeout saat membaca")
    result.add chunk

proc readHttpResponse(socket: Socket, timeoutMs: int): WsHandshake =
  var raw = ""
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while not raw.contains("\r\n\r\n"):
    if epochTime() > deadline:
      raise newException(IOError, "timeout menunggu balasan HTTP")
    let one = socket.readByte(timeoutMs = min(timeoutMs, 1000))
    if one.len == 0 and epochTime() > deadline:
      raise newException(IOError, "koneksi ditutup saat membaca balasan HTTP")
    raw.add one

  let splitAt = raw.find("\r\n\r\n")
  let head = raw[0 ..< splitAt]
  let remainder = raw[splitAt + 4 .. ^1]
  let lines = head.split("\r\n")
  let statusParts = lines[0].split(' ')
  if statusParts.len < 2:
    raise newException(IOError, "baris status tidak valid: " & lines[0])
  result.status = parseInt(statusParts[1])
  for i in 1 ..< lines.len:
    let colon = lines[i].find(':')
    if colon > 0:
      result.headers.add (lines[i][0 ..< colon].strip(), lines[i][colon + 1 .. ^1].strip())
  result.body = remainder

proc readBody(socket: Socket, handshake: var WsHandshake, timeoutMs: int) =
  ## Hanya untuk respons yang bukan 101: baca sisa body sesuai `Content-Length`
  ## (`Connection: Upgrade` membuat soket tidak bisa dipakai membaca sampai EOF).
  var length = 0
  for (name, value) in handshake.headers:
    if cmpIgnoreCase(name, "Content-Length") == 0:
      length = parseInt(value)
  if length > 0:
    if handshake.body.len < length:
      handshake.body.add socket.readExact(length - handshake.body.len, timeoutMs)
    handshake.body = handshake.body[0 ..< length]

proc randomKey(): string =
  var key: array[16, char]
  for i in 0 ..< key.len:
    key[i] = chr(rand(256))
  base64.encode(key)

proc buildRequest(host: string, port: int, path, key: string,
                  headers: openArray[(string, string)]): string =
  result = "GET " & path & " HTTP/1.1\r\n" &
    "Host: " & host & ":" & $port & "\r\n" &
    "Upgrade: websocket\r\n" &
    "Connection: Upgrade\r\n" &
    "Sec-WebSocket-Key: " & key & "\r\n" &
    "Sec-WebSocket-Version: 13\r\n"
  for (name, value) in headers:
    result.add name & ": " & value & "\r\n"
  result.add "\r\n"

proc openUpgrade(host: string, port: int, path: string,
                 headers: openArray[(string, string)]):
    tuple[socket: Socket, response: WsHandshake] =
  ## Buka soket + kirim permintaan upgrade. Soket dikembalikan **terbuka** supaya pemanggil
  ## memutuskan lanjut (101) atau membacanya sebagai respons biasa (401/403/426).
  # `buffered = false` penting: pada socket buffered, `recv(socket, data, size, timeout)` menunggu
  # sampai `size` byte terkumpul (atau timeout, lalu membuang yang sudah dibaca). Respons WebSocket
  # kecil dan tidak selalu memenuhi `size`, jadi klien akan "tidak pernah menerima" apa pun.
  result.socket = newSocket(buffered = false)
  result.socket.connect(host, Port(port))
  result.socket.send(buildRequest(host, port, path, randomKey(), headers))
  result.response = result.socket.readHttpResponse(5000)

proc handshake*(host: string, port: int, path: string,
                headers: openArray[(string, string)] = []): WsHandshake =
  ## Handshake sekali pakai: mengembalikan respons apa adanya (101 atau problem+json) lalu menutup.
  let opened = openUpgrade(host, port, path, headers)
  defer: opened.socket.close()
  result = opened.response
  if result.status != 101:
    opened.socket.readBody(result, 5000)

proc connect*(host: string, port: int, path: string,
              headers: openArray[(string, string)] = []): WsClient =
  ## Handshake + koneksi siap pakai. Gagal keras bila server tidak menaikkan.
  let opened = openUpgrade(host, port, path, headers)
  if opened.response.status != 101:
    var response = opened.response
    opened.socket.readBody(response, 5000)
    opened.socket.close()
    raise newException(IOError, "handshake gagal: status " & $response.status & " " & response.body)
  result.socket = opened.socket

proc sendText*(client: var WsClient, payload: string) =
  ## Frame dari klien **wajib** termask (RFC 6455 §5.3) — server menolak frame tak termask.
  var frame = "\x81"
  const maskBit = 0x80
  if payload.len < 126:
    frame.add chr(maskBit or payload.len)
  elif payload.len <= 0xFFFF:
    frame.add chr(maskBit or 126)
    frame.add chr((payload.len shr 8) and 0xFF)
    frame.add chr(payload.len and 0xFF)
  else:
    frame.add chr(maskBit or 127)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      frame.add chr((payload.len shr shift) and 0xFF)
  var mask = ""
  for i in 0 ..< 4:
    mask.add chr(rand(256))
  frame.add mask
  for i in 0 ..< payload.len:
    frame.add chr(ord(payload[i]) xor ord(mask[i mod 4]))
  client.socket.send(frame)

proc readFrame(client: var WsClient, timeoutMs: int): tuple[opcode: int, payload: string] =
  let header = client.socket.readExact(2, timeoutMs)
  if (ord(header[0]) and 0x80) == 0:
    raise newException(IOError, "server mengirim frame terfragmentasi (tidak didukung uji)")
  let opcode = ord(header[0]) and 0x0F
  if (ord(header[1]) and 0x80) != 0:
    raise newException(IOError, "server mengirim frame termask (tidak sesuai RFC 6455)")
  var length = ord(header[1]) and 0x7F
  if length == 126:
    let ext = client.socket.readExact(2, timeoutMs)
    length = (ord(ext[0]) shl 8) or ord(ext[1])
  elif length == 127:
    let ext = client.socket.readExact(8, timeoutMs)
    length = 0
    for i in 0 ..< 8:
      length = (length shl 8) or ord(ext[i])
  result = (opcode: opcode, payload: client.socket.readExact(length, timeoutMs))

proc nextText*(client: var WsClient, timeoutMs: int): string =
  ## Payload text berikutnya. Ping dijawab, pong diabaikan, close mengembalikan "".
  ## Timeout menaikkan `IOError` supaya test gagal dengan pesan jelas, bukan lolos sunyi.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let frame = client.readFrame(timeoutMs = max(50, timeoutMs))
    case frame.opcode
    of 0x1:
      return frame.payload
    of 0x9:
      client.socket.send("\x8A\x80\0\0\0\0")
    of 0xA:
      discard
    of 0x8:
      return ""
    else:
      discard
  raise newException(IOError, "timeout menunggu frame text dari server")

proc nextFrame*(client: var WsClient, timeoutMs: int): JsonNode =
  ## Frame JSON berikutnya (peristiwa atau pesan kontrol).
  let raw = client.nextText(timeoutMs)
  if raw.len == 0:
    raise newException(IOError, "server menutup koneksi")
  parseJson(raw)

proc nextOfType*(client: var WsClient, frameType: string, timeoutMs: int): JsonNode =
  ## Frame berikutnya dengan `type` tertentu, melewati peristiwa lain yang menyelip.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let frame = client.nextFrame(timeoutMs = max(50, timeoutMs))
    if frame{"type"}.getStr("") == frameType:
      return frame
  raise newException(IOError, "tidak ada frame bertipe '" & frameType & "' dalam batas waktu")

