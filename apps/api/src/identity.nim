## Identitas HTTP dari permintaan: cookie sesi & konteks koneksi (spec §13, §18.2).
##
## Satu tempat untuk membaca cookie sesi dan mengambil IP/perangkat yang ikut tercatat di audit.
## Dipakai modul realtime (handshake WS) maupun handler REST — dua konsumen, satu aturan.

import std/[net, options, os, strutils]

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

type
  Cidr* = object
    ## Satu rentang `alamat/prefix`. Hanya dipakai untuk memutuskan apakah peer boleh dipercaya
    ## mengirim `X-Forwarded-For`, bukan untuk hal lain.
    network*: IpAddress
    prefix*: int

proc parseCidr*(spec: string): Option[Cidr] =
  ## `10.89.0.0/16`, `127.0.0.1` (tanpa prefix = /32 atau /128), `::1/128`. `none` bila tidak sah.
  let text = spec.strip()
  if text.len == 0:
    return none(Cidr)
  let slash = text.rfind('/')
  let addressPart = if slash > 0: text[0 ..< slash] else: text
  var network: IpAddress
  try:
    network = parseIpAddress(addressPart)
  except ValueError:
    return none(Cidr)
  let maxPrefix = if network.family == IPv6: 128 else: 32
  if slash <= 0:
    return some(Cidr(network: network, prefix: maxPrefix))
  var prefix: int
  try:
    prefix = parseInt(text[slash + 1 .. ^1])
  except ValueError:
    return none(Cidr)
  if prefix < 0 or prefix > maxPrefix:
    return none(Cidr)
  some(Cidr(network: network, prefix: prefix))

proc prefixMatches(a, b: openArray[byte], prefix: int): bool =
  ## Apakah `prefix` bit pertama dari `a` dan `b` sama.
  var bits = 0
  for i in 0 ..< a.len:
    if bits >= prefix:
      return true
    if prefix - bits >= 8:
      if a[i] != b[i]:
        return false
      bits += 8
    else:
      let mask = byte(0xFF shl (8 - (prefix - bits)))
      return (a[i] and mask) == (b[i] and mask)
  true

proc contains*(range: Cidr, address: IpAddress): bool =
  ## Perbandingan bit-per-bit. Keluarga berbeda selalu `false` (IPv4 bukan IPv6-mapped).
  if range.network.family != address.family:
    return false
  case range.network.family
  of IPv4:
    prefixMatches(range.network.address_v4, address.address_v4, range.prefix)
  of IPv6:
    prefixMatches(range.network.address_v6, address.address_v6, range.prefix)

proc parseCidrList*(spec: string): seq[Cidr] =
  ## Daftar dipisah koma; entri yang tidak sah dilewati (konfigurasi salah tidak boleh membuat
  ## proses menolak start atau semua IP jadi tepercaya).
  for part in spec.split(','):
    let parsed = parseCidr(part)
    if parsed.isSome:
      result.add parsed.get()

const trustedProxyEnv* = "KRAN_TRUSTED_PROXY_CIDRS"
  ## Rentang peer yang boleh dipercaya mengirim `X-Forwarded-For`, selain loopback yang selalu
  ## dipercaya. Di qouver, API berjalan di container podman dan Caddy di host: peer-nya alamat
  ## gateway bridge (10.89.0.x), bukan loopback. Variabel ini **menimpa** default di bawah; untuk
  ## mempersempit ke satu rentang, isi dengan rentang yang benar.

const defaultTrustedProxyCidrs = "10.88.0.0/16, 10.89.0.0/16, 10.90.0.0/16"
  ## Default bentuk deployment kita: jaringan rootless podman menempati 10.88/10.89/10.90
  ## (`kran-api.container` menyebut 10.89.0.x), dan port API di-publish hanya ke 127.0.0.1 di
  ## host — tidak ada jalan bagi klien internet menjadi peer di rentang ini. Tanpa default ini,
  ## API di container melihat **satu** peer untuk semua klien: kolom `inet` audit tidak berguna
  ## dan pembatas login menjadi satu ember 10 percobaan/menit untuk seluruh institusi. Ini bentuk
  ## jaringan, bukan nilai bisnis.

const maxTrustedProxies = 8 # nomagic:ok batas teknis jumlah rentang proxy per deployment

type
  TrustedProxySet* = object
    ## Rentang tepercaya versi nilai (bukan `seq`): dipegang sebagai variabel global proses, dan
    ## global yang memuat memori GC tidak boleh disentuh dari handler `{.gcsafe.}`.
    entries: array[maxTrustedProxies, Cidr]
    count: int

proc initTrustedProxies*(spec: string): TrustedProxySet =
  ## Daftar dipisah koma; entri tidak sah dilewati (konfigurasi salah tidak boleh membuat proses
  ## menolak start atau semua IP jadi tepercaya). Kelebihan entri juga dilewati: delapan rentang
  ## sudah jauh melebihi bentuk deployment kita.
  for parsed in parseCidrList(spec):
    if result.count >= maxTrustedProxies:
      break
    result.entries[result.count] = parsed
    inc result.count

proc len*(set: TrustedProxySet): int = set.count

proc toSeq*(set: TrustedProxySet): seq[Cidr] =
  for i in 0 ..< set.count:
    result.add set.entries[i]

proc trustedProxyCidrsFromEnv*(): TrustedProxySet =
  ## Dibaca dari lingkungan. Sengaja bukan parameter DB: ini bentuk deployment (alamat jaringan
  ## container), bukan kebijakan institusi, dan harus diketahui sebelum koneksi DB pertama.
  let spec = getEnv(trustedProxyEnv).strip()
  initTrustedProxies(if spec.len > 0: spec else: defaultTrustedProxyCidrs)

let processTrustedProxies* = trustedProxyCidrsFromEnv()
  ## Dibaca sekali saat modul dimuat (sebelum thread HTTP lahir), jadi setiap permintaan tidak
  ## memanggil `getenv` dan tidak ada balapan inisialisasi. Nilai deployment tidak berubah selama
  ## proses hidup; mengubahnya berarti restart, sama seperti kebijakan pool koneksi.

proc isTrustedPeer*(peer: string, trusted: TrustedProxySet): bool =
  ## Loopback selalu tepercaya (dev: Vite proxy dan test berjalan di host yang sama). Selain itu
  ## peer harus cocok dengan salah satu rentang yang dikonfigurasi.
  if isLoopback(peer):
    return true
  var address: IpAddress
  try:
    address = parseIpAddress(peer)
  except ValueError:
    return false
  for i in 0 ..< trusted.count:
    if trusted.entries[i].contains(address):
      return true

const maxIpLength* = 45 # nomagic:ok panjang teks IPv6 terpanjang, sama dengan batas kolom `inet`

proc clientIpFrom*(peerAddress, forwardedFor: string,
                   trusted: TrustedProxySet = TrustedProxySet()): string =
  ## Pilihan IP dari alamat koneksi + header `X-Forwarded-For` (T-130/SEC-2). Dipisah dari
  ## `Request` supaya aturannya bisa diuji tanpa server.
  ##
  ## Header hanya dipercaya bila peer tepercaya: loopback, atau salah satu rentang di
  ## `KRAN_TRUSTED_PROXY_CIDRS`. Di qouver Caddy berjalan di host dan API di container podman,
  ## jadi peer-nya gateway bridge — tanpa rentang itu **semua** klien tampak satu IP: kolom `inet`
  ## audit tidak berguna dan pembatas login menjadi satu ember bersama (10 percobaan/menit untuk
  ## seluruh institusi). Tanpa rentang tepercaya, klien mana pun bisa memalsukan kolom `inet` audit
  ## cukup dengan mengirim header sendiri. Isi header divalidasi sebagai alamat IP; yang tidak sah
  ## diabaikan, bukan diteruskan ke DB — sebelumnya satu header ngawur membuat penulisan yang
  ## diaudit gagal 500.
  ##
  ## Rantai `X-Forwarded-For` dibaca dari **kanan**, bukan kiri: Caddy menambahkan peer yang
  ## benar-benar terhubung ke ujung kanan, sedangkan bagian kiri bisa dikarang klien. Entri
  ## paling kanan yang bukan proxy tepercaya adalah klien sesungguhnya.
  let peer = withoutPort(peerAddress)
  if not isTrustedPeer(peer, trusted):
    return peer
  let forwarded = forwardedFor.strip()
  if forwarded.len == 0:
    return peer
  var candidates: seq[string]
  for part in forwarded.split(','):
    let entry = withoutPort(part.strip())
    if entry.len == 0 or entry.len > maxIpLength:
      continue
    try:
      discard parseIpAddress(entry)
      candidates.add entry
    except ValueError:
      discard
  for i in countdown(candidates.len - 1, 0):
    if not isTrustedPeer(candidates[i], trusted):
      return candidates[i]
  peer

proc clientIp*(req: Request, trusted: TrustedProxySet = processTrustedProxies): string =
  ## IP pemanggil untuk audit (spec §18.2) — aturannya di `clientIpFrom`. Rentang tepercaya
  ## dibaca sekali dari `KRAN_TRUSTED_PROXY_CIDRS` (lihat `processTrustedProxies`).
  clientIpFrom(req.remoteAddress, req.headers["X-Forwarded-For"], trusted)

proc deviceOf*(req: Request): string =
  ## User-Agent dipotong (`maxDeviceLength`), bukan disimpan utuh.
  let userAgent = req.headers["User-Agent"]
  if userAgent.len <= maxDeviceLength:
    userAgent
  else:
    userAgent[0 ..< maxDeviceLength]
