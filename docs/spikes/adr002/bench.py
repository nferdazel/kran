"""Klien beban kecil (asyncio) — dipakai adil untuk semua kandidat server.

Semua server diukur dengan klien yang sama supaya perbandingan relatif masuk akal.
Ini bukan alat benchmark kelas wrk: batas atasnya adalah klien Python sendiri.
"""

import asyncio
import sys
import time

TOTAL = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
CONC = int(sys.argv[2]) if len(sys.argv) > 2 else 50
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8081
PATH = "/api/v1/ping"


async def one(host, port, path):
    reader, writer = await asyncio.open_connection(host, port)
    writer.write(
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode()
    )
    await writer.drain()
    data = await reader.read(4096)
    writer.close()
    return data


async def worker(n, counter, host, port):
    for _ in range(n):
        try:
            d = await one(host, port, PATH)
            if d.startswith(b"HTTP/1.1 200"):
                counter[0] += 1
            else:
                counter[1] += 1
        except Exception:
            counter[1] += 1


async def main():
    per = TOTAL // CONC
    counter = [0, 0]
    t0 = time.perf_counter()
    await asyncio.gather(*(worker(per, counter, "127.0.0.1", PORT) for _ in range(CONC)))
    dt = time.perf_counter() - t0
    print(
        f"port={PORT} ok={counter[0]} gagal={counter[1]} "
        f"waktu={dt:.2f}s rps={counter[0] / dt:,.0f}"
    )


asyncio.run(main())
