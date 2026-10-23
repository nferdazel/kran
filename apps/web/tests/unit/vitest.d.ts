/**
 * Deklarasi minimal API `vitest` untuk test unit web.
 *
 * `@kran/web` sengaja **tidak** mendeklarasikan vitest: menambah dependensi baru butuh ADR
 * (AGENTS §1.6). Test dijalankan dengan binary milik `packages/ui` (satu-satunya runner vitest di
 * workspace):
 *
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * `tsconfig.json` memeriksa `tests/**`, jadi tanpa deklarasi ini `svelte-check` gagal dengan
 * "Cannot find module 'vitest'". Hanya API yang benar-benar dipakai di `tests/unit`.
 */
declare module "vitest" {
  type TestCallback = () => void | Promise<void>;

  export function describe(name: string, callback: TestCallback): void;
  export function it(name: string, callback: TestCallback): void;
  export function test(name: string, callback: TestCallback): void;

  export interface Matchers {
    toBe(expected: unknown): void;
    toEqual(expected: unknown): void;
    toBeTruthy(): void;
    toBeFalsy(): void;
    toHaveLength(length: number): void;
    toContain(item: unknown): void;
    toMatch(pattern: RegExp | string): void;
    toBeGreaterThan(value: number): void;
  }

  export function expect<T = unknown>(actual: T): Matchers;
}
