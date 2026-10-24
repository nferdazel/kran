## Identitas HTTP dari permintaan: cookie sesi & konteks koneksi (spec §13, §18.2).
##
## Satu tempat untuk membaca cookie sesi dan mengambil IP/perangkat yang ikut tercatat di audit.
## Dipakai modul realtime (handshake WS) maupun handler REST — dua konsumen, satu aturan.

import std/[net, strutils]

import mummy

const
  SessionCookieName* = "kran_session"

  ## Panjang User-Agent yang disimpan: cukup untuk korelasi, bukan sidik jari penuh
  ## (spec §18.2 logging). Nilainya teknis, bukan kebijakan bisnis.
  maxDeviceLength* = 120 # nomagic:ok batas teknis panjang kolom audit

proc cookieValue*(req: Request, name: string): string =
  ## Nilai cookie pertama dengan nama `name`; "" bila tidak ada. Bentuk yang dikirim browser
  ## sederhana (`nama=nilai`, dipisah `;`), jadi tidak perlu pustaka pengurai cookie.
  for part in req.headers["Cookie"].split(';'):
    let item = part.strip()
    if item.startsWith(name & "="):
      return item[name.len + 1 .. ^1]
  ""

proc bearerToken*(req: Request): string =
  const prefix = "Bearer "
  let authorization = req.headers["Authorization"]
  if authorization.len > prefix.len and
      cmpIgnoreCase(authorization[0 ..< prefix.len], prefix) == 0:
    return authorization[prefix.len .. ^1].strip()
  ""

proc identityFromRequest*(req: Request): string =
  ## Token sesi dari cookie (spec §13: HttpOnly) atau `Authorization: Bearer`; "" = anonim.
  ## Yang diambil hanya **token mentah** — penafsirannya (token → sesi → pengguna → izin) ada di
  ## `access.nim` supaya transport tidak tahu aturan bisnis.
  let fromCookie = cookieValue(req, SessionCookieName)
  if fromCookie.len > 0:
    return fromCookie
  bearerToken(req)

proc withoutPort*(address: string): string =
  ## `127.0.0.1:55000` → `127.0.0.1`, `[::1]:55000` → `::1`. Bentuk tanpa port dibiarkan.
  if address.startsWith("["):
    let close = address.find(']')
    if close > 0:
      return address[1 ..< close]
    return address
  if address.count(':') == 1:
    let colon = address.find(':')
    if colon > 0:
      return address[0 ..< colon]
  address

proc isLoopback(address: string): bool =
  ## Apakah alamat koneksi berasal dari host ini sendiri (Caddy/proxy Vite berjalan di host yang
  ## sama). Dipakai sebagai syarat mempercayai `X-Forwarded-For`.
  address == "127.0.0.1" or address == "::1" or address == "::ffff:127.0.0.1"

const maxIpLength* = 45 # nomagic:ok panjang teks IPv6 terpanjang, sama dengan batas kolom `inet`

proc clientIpFrom*(peerAddress, forwardedFor: string): string =
  ## Pilihan IP dari alamat koneksi + header `X-Forwarded-For` (T-130/SEC-2). Dipisah dari
  ## `Request` supaya aturannya bisa diuji tanpa server.
  ##
  ## Header hanya dipercaya bila koneksi datang dari loopback — di produksi Caddy berjalan di host
  ## yang sama, di dev proxy Vite juga. Tanpa syarat itu, klien mana pun bisa memalsukan kolom
  ## `inet` audit (dan kunci pembatas login) cukup dengan mengirim header sendiri. Isi header
  ## divalidasi sebagai alamat IP; yang tidak sah diabaikan, bukan diteruskan ke DB — sebelumnya
  ## satu header ngawur membuat penulisan yang diaudit gagal 500.
  let peer = withoutPort(peerAddress)
  if not isLoopback(peer):
    return peer
  let forwarded = forwardedFor.split(',')[0].strip()
  if forwarded.len == 0:
    return peer
  let candidate = withoutPort(forwarded)
  if candidate.len > maxIpLength:
    return peer
  try:
    discard parseIpAddress(candidate)
    candidate
  except ValueError:
    peer

proc clientIp*(req: Request): string =
  ## IP pemanggil untuk audit (spec §18.2) — aturannya di `clientIpFrom`.
  clientIpFrom(req.remoteAddress, req.headers["X-Forwarded-For"])

proc deviceOf*(req: Request): string =
  ## User-Agent dipotong (`maxDeviceLength`), bukan disimpan utuh.
  let userAgent = req.headers["User-Agent"]
  if userAgent.len <= maxDeviceLength:
    userAgent
  else:
    userAgent[0 ..< maxDeviceLength]
