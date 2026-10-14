/**
 * Klien API CBS (spec §13): tipe dari kontrak OpenAPI 3.1 (`openapi-typescript`) + wrapper fetch
 * tipis (`openapi-fetch`). Tidak ada logika bisnis di sini — hanya transport bertipe.
 *
 * Konvensi yang dipegang klien ini:
 *  - Error server selalu `application/problem+json` (RFC 9457) dengan `i18nKey` + `params`;
 *    UI menerjemahkannya lewat katalog i18n, bukan menampilkan `title` mentah.
 *  - Cookie sesi `HttpOnly` dikirim otomatis (same-origin), jadi tidak ada token di JS.
 *  - Uang selalu string desimal; jangan mengubahnya menjadi `number` untuk perhitungan.
 */
import createClient, { type Middleware } from "openapi-fetch";

import type { paths } from "./generated/schema.d.ts";

export type ApiPaths = paths;

export interface CbsClientOptions {
  /** Basis URL; default same-origin (BFF). */
  baseUrl?: string;
  /** Dipakai test/observabilitas: menyuntikkan implementasi fetch (mis. dari Playwright). */
  fetchImpl?: typeof fetch;
}

/** Bentuk amplop error RFC 9457 sesuai kontrak (`components/schemas/Problem`). */
export interface Problem {
  type: string;
  title: string;
  status: number;
  detail?: string;
  code: string;
  i18nKey: string;
  params?: Record<string, string>;
  traceId: string;
}

export type CbsClient = ReturnType<typeof createClient<paths>> & {
  /** True bila respons terakhir (atau objek mana pun) adalah amplop problem. */
  isProblem: (value: unknown) => value is Problem;
};

export function createCbsClient(options: CbsClientOptions = {}): CbsClient {
  const client = createClient<paths>({
    baseUrl: options.baseUrl ?? "",
    ...(options.fetchImpl ? { fetch: options.fetchImpl } : {}),
  });

  const traceIdMiddleware: Middleware = {
    async onRequest({ request }) {
      // Korelasi log/audit: server meneruskan `X-Request-Id` ke `traceId` (lihat apps/api/src/problem.nim).
      if (!request.headers.has("X-Request-Id")) {
        request.headers.set("X-Request-Id", crypto.randomUUID());
      }
      return request;
    },
  };
  client.use(traceIdMiddleware);

  return Object.assign(client, {
    isProblem(value: unknown): value is Problem {
      if (typeof value !== "object" || value === null) return false;
      const candidate = value as Partial<Problem>;
      return (
        typeof candidate.type === "string" &&
        typeof candidate.code === "string" &&
        typeof candidate.i18nKey === "string" &&
        typeof candidate.traceId === "string"
      );
    },
  });
}
