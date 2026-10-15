## Identitas HTTP dari permintaan: cookie sesi & konteks koneksi (spec §13, §18.2).
##
## Satu tempat untuk membaca cookie sesi dan mengambil IP/perangkat yang ikut tercatat di audit.
## Dipakai modul realtime (handshake WS) maupun handler REST — dua konsumen, satu aturan.

import std/[strutils]

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

proc clientIp*(req: Request): string =
  ## IP pemanggil untuk audit. `X-Forwarded-For` diutamakan karena di belakang proxy (Caddy,
  ## proxy Vite di dev) alamat koneksi selalu alamat proxy. Nilai yang tidak sah **tidak**
  ## diperbaiki di sini: kolom `inet` DB yang menolaknya, dan gagal jelas lebih baik daripada
  ## tercatat salah.
  let forwarded = req.headers["X-Forwarded-For"].split(',')[0].strip()
  if forwarded.len > 0:
    return forwarded
  withoutPort(req.remoteAddress)

proc deviceOf*(req: Request): string =
  ## User-Agent dipotong (`maxDeviceLength`), bukan disimpan utuh.
  let userAgent = req.headers["User-Agent"]
  if userAgent.len <= maxDeviceLength:
    userAgent
  else:
    userAgent[0 ..< maxDeviceLength]
