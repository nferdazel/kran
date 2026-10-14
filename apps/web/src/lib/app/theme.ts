/**
 * Tema light/dark/system (spec §15.2–§15.3).
 *
 * Pilihan disimpan di `localStorage` (`cbs-theme`); profil pengguna di DB menyusul bersama
 * fitur pengaturan (spec §15.2). Tema diterapkan sebagai atribut `data-theme` di `<html>`
 * sehingga token CSS yang berganti, bukan warna per komponen.
 *
 * Skrip inline di `app.html` sudah menetapkan tema sebelum render (cegah flash); modul ini
 * menyinkronkan pilihan, atribut, `color-scheme`, dan perubahan preferensi sistem.
 */

export type ThemeChoice = "light" | "dark" | "system";
export type ResolvedTheme = "light" | "dark";

export const THEME_STORAGE_KEY = "cbs-theme";

const CHOICES: readonly ThemeChoice[] = ["light", "dark", "system"];

/** Normalisasi nilai tak dikenal (localStorage bisa diisi apa pun) → default `system`. */
export function normalizeChoice(value: string | null): ThemeChoice {
  return CHOICES.includes(value as ThemeChoice) ? (value as ThemeChoice) : "system";
}

export function readChoice(): ThemeChoice {
  try {
    return normalizeChoice(localStorage.getItem(THEME_STORAGE_KEY));
  } catch {
    // localStorage dapat diblokir (mode privat/ kebijakan); tetap jalan dengan default.
    return "system";
  }
}

export function systemPrefersDark(): boolean {
  return typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches;
}

export function resolveTheme(choice: ThemeChoice): ResolvedTheme {
  if (choice === "system") {
    return systemPrefersDark() ? "dark" : "light";
  }
  return choice;
}

/** Terapkan tema ke `<html>`: atribut + `color-scheme` (untuk kontrol bawaan browser). */
export function applyTheme(choice: ThemeChoice): ResolvedTheme {
  const resolved = resolveTheme(choice);
  const root = document.documentElement;
  root.setAttribute("data-theme", resolved);
  root.style.colorScheme = resolved;
  return resolved;
}

export function setChoice(choice: ThemeChoice): ResolvedTheme {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, choice);
  } catch {
    // Gagal menyimpan bukan alasan menggagalkan pergantian tema.
  }
  return applyTheme(choice);
}

/**
 * Ikuti perubahan preferensi sistem **selama** pilihan pengguna = `system`.
 * Mengembalikan fungsi pembersih (dipanggil saat komponen dilepas).
 */
export function watchSystemTheme(onChange: (resolved: ResolvedTheme) => void): () => void {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const handler = () => {
    if (readChoice() === "system") {
      onChange(applyTheme("system"));
    }
  };
  media.addEventListener("change", handler);
  return () => media.removeEventListener("change", handler);
}
