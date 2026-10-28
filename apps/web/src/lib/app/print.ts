/**
 * Glue dokumen cetak (T-094a slip, T-094b statement): klien endpoint baca + view-model murni.
 *
 * Batas yang dipegang (D-127):
 *  - Cetak memakai browser print (`window.print`), bukan PDF server. Tidak ada berkas PDF.
 *  - Dokumen hanya menampilkan apa yang dikembalikan server. Tak ada saldo berjalan per baris
 *    (tidak disimpan) dan tak ada saldo total yang dikarang; total di sini semata jumlah baris
 *    subledger, bukan rekonsiliasi GL.
 *  - Uang tetap string desimal; penjumlahan lewat `@kran/ui/money` (tanpa float).
 *
 * Logika murni (validasi rentang, urut baris, total, label) dipisah dari komponen supaya bisa
 * diuji vitest tanpa DOM dan tanpa DB.
 */
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { api } from "#lib/app/api.js";
import { formatMoney } from "#lib/app/format.js";
import { addMoney } from "@kran/ui/money";

export type CashTransactionSlip = components["schemas"]["CashTransactionSlip"];
export type AccountStatement = components["schemas"]["AccountStatement"];
export type StatementRow = components["schemas"]["StatementRow"];
export type StatementDirection = StatementRow["direction"];
export type SlipDirection = CashTransactionSlip["direction"];

/** Batas baris teknis server (T-094b). Nilai **bukan** ambang bisnis; hanya ukuran respons. */
export const STATEMENT_ROW_LIMIT = 500;

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

/** `YYYY-MM-DD` yang benar-benar ada — sejalan dengan `isIsoDate` server (http_util.nim). */
export function isIsoDate(value: string): boolean {
  const text = value.trim();
  if (!ISO_DATE_PATTERN.test(text)) return false;
  const [year, month, day] = text.split("-").map(Number) as [number, number, number];
  if (month < 1 || month > 12 || day < 1) return false;
  // Hari ke-0 bulan (0-based) berikutnya = hari terakhir bulan kalender ini.
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day <= lastDay;
}

/** Rentang statement dari query/ketikan: `ok` bila format sah dan `from <= to`. */
export function validateRange(
  from: string,
  to: string,
): { ok: true; from: string; to: string } | { ok: false; reason: "required" | "invalid" } {
  const fromText = from.trim();
  const toText = to.trim();
  if (fromText === "" || toText === "") return { ok: false, reason: "required" };
  if (!isIsoDate(fromText) || !isIsoDate(toText) || fromText > toText) {
    return { ok: false, reason: "invalid" };
  }
  return { ok: true, from: fromText, to: toText };
}

export function rangeError(reason: "required" | "invalid"): string {
  return reason === "required" ? m.print_range_required() : m.print_range_invalid();
}

/**
 * Urutkan baris menurut tanggal (stabil: urutan masukan dipakai sebagai tie-breaker). Server sudah
 * mengurutkan; ini pengaman view-model supaya dokumen tetap urut walau respons berubah.
 */
export function sortStatementRows(rows: StatementRow[]): StatementRow[] {
  return rows
    .map((row, index) => ({ row, index }))
    .sort((a, b) => {
      const byDate = a.row.businessDate.localeCompare(b.row.businessDate);
      return byDate !== 0 ? byDate : a.index - b.index;
    })
    .map((entry) => entry.row);
}

export interface StatementTotals {
  inflow: string;
  outflow: string;
  net: string;
}

/** Total masuk/keluar = jumlah baris subledger (bukan rekonsiliasi GL, bukan saldo berjalan). */
export function statementTotals(rows: StatementRow[]): StatementTotals {
  let inflow = "0.00";
  let outflow = "0.00";
  for (const row of rows) {
    if (row.direction === "IN") inflow = addMoney(inflow, row.amount);
    else outflow = addMoney(outflow, row.amount);
  }
  return { inflow, outflow, net: addMoney(inflow, `-${outflow}`) };
}

export function slipDirectionLabel(direction: SlipDirection): string {
  return direction === "DEPOSIT" ? m.slip_direction_deposit() : m.slip_direction_withdrawal();
}

export function statementDirectionLabel(direction: StatementDirection): string {
  return direction === "IN" ? m.statement_direction_in() : m.statement_direction_out();
}

const STATEMENT_KIND_LABELS: Record<StatementRow["kind"], () => string> = {
  CASH: () => m.statement_kind_cash(),
  TRANSFER: () => m.statement_kind_transfer(),
  MATURITY: () => m.statement_kind_maturity(),
};

/** Label sumber baris statement. Nilai di luar kontrak ditampilkan apa adanya, bukan ditebak. */
export function statementKindLabel(kind: StatementRow["kind"]): string {
  const template = STATEMENT_KIND_LABELS[kind];
  return template === undefined ? kind : template();
}

const STATEMENT_STATUS_LABELS: Record<AccountStatement["status"], () => string> = {
  ACTIVE: () => m.statement_status_active(),
  CLOSED: () => m.statement_status_closed(),
  DORMANT: () => m.statement_status_dormant(),
};

/** Label status rekening di rekening koran. Dormant bukan "ditutup" — rekeningnya masih hidup. */
export function statementStatusLabel(status: AccountStatement["status"]): string {
  const template = STATEMENT_STATUS_LABELS[status];
  return template === undefined ? status : template();
}

/** Tanda arah ditulis sebagai tanda + kata, bukan warna saja (spec §15.4). */
export function signedAmount(direction: StatementDirection, amount: string): string {
  return `${direction === "IN" ? "+" : "-"}${formatMoney(amount, { decimals: 2 })}`;
}

/** Referensi baris: id transaksi tunai atau id PB (tepat satu terisi). */
export function statementReference(row: StatementRow): string {
  return row.transactionId ?? row.transferId ?? "";
}

/** Pesan galat dokumen cetak dari status HTTP (401 ditangani pemanggil dengan pindah ke login). */
export function printProblemMessage(status: number): string {
  if (status === 404) return m.print_not_found();
  if (status === 403) return m.print_denied();
  return m.print_error();
}

export function loadCashTransactionSlip(transactionId: string) {
  return api.GET("/api/v1/teller/cash-transactions/{transactionId}", {
    params: { path: { transactionId } },
  });
}

export function loadAccountStatement(accountId: string, from: string, to: string) {
  return api.GET("/api/v1/deposit/accounts/{accountId}/statement", {
    params: { path: { accountId }, query: { from, to } },
  });
}
