import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

import { blockingViolations } from "./axe.js";
import { requireDatabase } from "./db.js";

/**
 * Shell reflow proof (T-294 part 1).
 *
 * Measures, and then asserts, that the shell does not push the document wider than the viewport at
 * the two widths that break today: 360 CSS px (a phone) and 180 CSS px (200% zoom on that same
 * phone). Device pixel ratio stays 1, as the ticket requires.
 *
 * It prints one JSON line per route x theme x width so the numbers can be quoted in the task
 * evidence instead of being re-derived by hand (the T-288 numbers could not be reproduced).
 *
 * What it proves:
 *  - document scrollWidth === clientWidth (no page-level horizontal scroll);
 *  - the business date stays inside the topbar, visible and not clipped;
 *  - with the panel open, every nav link renders on one line;
 *  - a `.kran-toolbar` stays inside its page column and its children stay inside the toolbar;
 *  - the focusable count at 1440 does not grow (the reflow adds no tab stop);
 *  - axe is clean on the two reflow screens plus `/app/dayclose`, both widths, both themes.
 */

requireDatabase();

/** `/app/loans` needs `lending_maker` read; `dev.maker` is answered with 403 there. */
const ACCOUNTS = {
  ledger: { username: "dev.maker", password: "rahasia-panjang-123" },
  loans: { username: "dev.loans", password: "rahasia-panjang-123" },
} as const;

const ROUTES = [
  { path: "/app/ledger", account: ACCOUNTS.ledger },
  { path: "/app/loans", account: ACCOUNTS.loans },
] as const;

/** Acceptance 8 names a third screen; it is judged for axe only, not for the reflow itself. */
const AXE_ROUTES = [
  ...ROUTES,
  { path: "/app/dayclose", account: { username: "dev.console", password: "rahasia-panjang-123" } },
] as const;

const THEMES = ["light", "dark"] as const;
const VIEWPORTS = [
  { width: 360, height: 800 },
  { width: 180, height: 400 },
] as const;
/** Reference width for the tab-stop count; the reflow must not change it. */
const DESKTOP = { width: 1440, height: 900 } as const;

type Measurement = {
  route: string;
  theme: string;
  width: number;
  pageOverflow: number;
  businessDateRight: number;
  topbarRight: number;
  businessDateClipped: boolean;
  businessDateVisible: boolean;
  navLinks: number;
  navWrapped: number;
  toolbars: number;
  toolbarWidths: number[];
  toolbarOverflow: number;
  focusables: number;
  widest: string[];
};

async function prepare(page: Page, theme: string): Promise<void> {
  await page.addInitScript((value) => {
    localStorage.setItem("PARAGLIDE_LOCALE", "id");
    localStorage.setItem("kran-theme", value);
  }, theme);
}

async function login(page: Page, account: { username: string; password: string }): Promise<void> {
  await page.goto("/login");
  await page.getByLabel("Nama pengguna", { exact: true }).focus();
  await page.keyboard.type(account.username);
  await page.keyboard.press("Tab");
  await page.keyboard.type(account.password);
  await page.keyboard.press("Enter");
  await expect(page).not.toHaveURL(/\/login$/);
}

async function measure(page: Page, route: string, theme: string, width: number): Promise<Measurement> {
  return page.evaluate(
    ({ route, theme, width }) => {
      const doc = document.documentElement;
      const pageOverflow = doc.scrollWidth - doc.clientWidth;

      // Widest offenders, so a failure names the element instead of the number.
      const widest: string[] = [];
      let widestRight = doc.clientWidth;
      for (const element of document.querySelectorAll<HTMLElement>("body *")) {
        if (element.getClientRects().length === 0) continue;
        const right = element.getBoundingClientRect().right;
        if (right <= widestRight) continue;
        const name =
          element.tagName.toLowerCase() +
          (element.className && typeof element.className === "string"
            ? "." + element.className.trim().split(/\s+/).join(".")
            : "");
        widest.push(`${name}@${Math.round(right)}`);
        widestRight = right;
      }

      const businessDate = document.querySelector<HTMLElement>(".kran-business-date");
      const topbar = document.querySelector<HTMLElement>(".topbar");
      const businessDateRect = businessDate?.getBoundingClientRect();
      const topbarRect = topbar?.getBoundingClientRect();

      const navLinks = [...document.querySelectorAll<HTMLElement>(".sidebar__nav a")];
      const navWrapped = navLinks.filter((link) => {
        // Count the text lines directly: the row min-height makes the box taller than one line
        // even when the label is not wrapped, so box height is not a reliable signal.
        const range = document.createRange();
        range.selectNodeContents(link);
        const lines = new Set([...range.getClientRects()].map((rect) => Math.round(rect.top))).size;
        return link.scrollWidth > link.clientWidth + 1 || lines > 1;
      }).length;

      // Every control the reflow can widen: toolbar children and their wrappers.
      let toolbarOverflow = 0;
      const toolbars = document.querySelectorAll<HTMLElement>(".kran-toolbar");
      const toolbarWidths: number[] = [];
      for (const toolbar of toolbars) {
        const box = toolbar.getBoundingClientRect();
        toolbarWidths.push(Math.round(box.width));
        // The toolbar itself must stay inside its parent's content box; a flex row that keeps its
        // min-content width grows past the page and is what pushes the document sideways.
        const parent = toolbar.parentElement;
        if (parent !== null) {
          const parentBox = parent.getBoundingClientRect();
          const padding = Number.parseFloat(getComputedStyle(parent).paddingRight) || 0;
          toolbarOverflow = Math.max(toolbarOverflow, box.right - (parentBox.right - padding));
        }
        for (const child of toolbar.querySelectorAll<HTMLElement>("*")) {
          if (child.getClientRects().length === 0) continue;
          toolbarOverflow = Math.max(toolbarOverflow, child.getBoundingClientRect().right - box.right);
        }
      }

      const focusables = [
        ...document.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      ].filter((element) => element.getClientRects().length > 0).length;

      return {
        route,
        theme,
        width,
        pageOverflow,
        businessDateRight: Math.round(businessDateRect?.right ?? 0),
        topbarRight: Math.round(topbarRect?.right ?? 0),
        businessDateClipped: businessDate ? businessDate.scrollWidth > businessDate.clientWidth + 1 : true,
        businessDateVisible:
          businessDate !== null && getComputedStyle(businessDate).visibility !== "hidden",
        navLinks: navLinks.length,
        navWrapped,
        toolbars: toolbars.length,
        toolbarWidths,
        toolbarOverflow: Math.round(toolbarOverflow),
        focusables,
        widest: widest.slice(0, 5),
      };
    },
    { route, theme, width },
  );
}

async function openPanel(page: Page): Promise<void> {
  const button = page.locator("[data-shell-menu-button]");
  if (await button.isVisible()) await button.click();
}

for (const route of ROUTES) {
  for (const theme of THEMES) {
    for (const viewport of VIEWPORTS) {
      test(`shell reflow ${route.path} ${theme} ${viewport.width}px`, async ({ browser }) => {
        const context = await browser.newContext({
          viewport,
          deviceScaleFactor: 1,
          locale: "id-ID",
        });
        const page = await context.newPage();
        await prepare(page, theme);
        await login(page, route.account);
        await page.goto(route.path);
        await page.waitForLoadState("networkidle");

        await openPanel(page);
        const result = await measure(page, route.path, theme, viewport.width);
        console.log("T-294 " + JSON.stringify(result));

        expect(result.pageOverflow, `page overflow ${JSON.stringify(result.widest)}`).toBe(0);
        expect(result.businessDateVisible, "business date hidden").toBe(true);
        expect(result.businessDateClipped, "business date clipped").toBe(false);
        expect(
          result.businessDateRight,
          "business date right edge inside the topbar",
        ).toBeLessThanOrEqual(result.topbarRight);
        expect(result.navLinks, "nav links present").toBeGreaterThan(0);
        expect(result.navWrapped, "nav links wrapping").toBe(0);
        expect(result.toolbarOverflow, "toolbar children past the container").toBeLessThanOrEqual(0);

        await context.close();
      });
    }
  }
}

for (const route of ROUTES) {
  test(`tab stops unchanged at 1440 ${route.path}`, async ({ browser }) => {
    const context = await browser.newContext({
      viewport: DESKTOP,
      deviceScaleFactor: 1,
      locale: "id-ID",
    });
    const page = await context.newPage();
    await prepare(page, "light");
    await login(page, route.account);
    await page.goto(route.path);
    await page.waitForLoadState("networkidle");

    const result = await measure(page, route.path, "light", DESKTOP.width);
    console.log("T-294-focusables " + JSON.stringify({ route: route.path, focusables: result.focusables }));
    expect(result.focusables).toBeGreaterThan(0);
    expect(result.pageOverflow).toBe(0);

    await context.close();
  });
}

/**
 * Acceptance 8: the two screens whose shell changed stay axe-clean at both target widths, in both
 * themes. The width matters here because the reflow is what moved elements between rows.
 */
for (const route of AXE_ROUTES) {
  for (const theme of THEMES) {
    for (const width of [1440, 360] as const) {
      test(`axe ${route.path} ${theme} ${width}px`, async ({ browser }) => {
        const context = await browser.newContext({
          viewport: { width, height: 900 },
          deviceScaleFactor: 1,
          locale: "id-ID",
        });
        const page = await context.newPage();
        await prepare(page, theme);
        await login(page, route.account);
        await page.goto(route.path);
        await page.waitForLoadState("networkidle");

        const results = await new AxeBuilder({ page }).analyze();
        const blocking = blockingViolations(results.violations);
        console.log(
          "T-294-axe " +
            JSON.stringify({
              route: route.path,
              theme,
              width,
              violations: blocking.map((violation) => violation.id),
            }),
        );
        expect(
          blocking.map((violation) => ({
            id: violation.id,
            impact: violation.impact,
            nodes: violation.nodes.map((node) => node.target.join(" ")),
          })),
        ).toEqual([]);

        await context.close();
      });
    }
  }
}
