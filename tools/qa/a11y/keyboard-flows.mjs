#!/usr/bin/env node
/**
 * Keyboard flow runner for the a11y gate.
 *
 * A keyboard flow is a list of steps; each step either acts (focus/click/press)
 * or asserts (focus target, visibility, ARIA state, focus ring, focus trap).
 * Flows with a selector containing "TODO:" are reported BLOCKED, never PASS:
 * an unwritten check is not a green gate.
 *
 * Exit codes: 0 all PASS, 1 any FAIL, 2 only BLOCKED.
 *
 * Usage:
 *   node tools/qa/a11y/keyboard-flows.mjs --config keyboard-mockup
 *   node tools/qa/a11y/keyboard-flows.mjs --config keyboard-app --url http://127.0.0.1:5173
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../../..");

function parseArgs(argv) {
  const out = { flags: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) out.flags[key] = true;
    else {
      out.flags[key] = next;
      i += 1;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.flags.config) {
  console.error("Missing --config <name|path>. Try: --config keyboard-mockup");
  process.exit(64);
}

function resolveConfig(name) {
  for (const candidate of [name, path.join(HERE, "config", `${name}.json`)]) {
    if (fs.existsSync(candidate)) return path.resolve(candidate);
  }
  throw new Error(`Config not found: ${name}`);
}

const cfgPath = resolveConfig(args.flags.config);
const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const label = args.flags.label ?? cfg.label ?? path.basename(cfgPath, ".json");
const outDir = path.resolve(REPO, args.flags.out ?? cfg.out ?? ".local/qa/results");
const baseUrl = args.flags.url ?? cfg.url;
const only = args.flags.only ? String(args.flags.only).split(",") : null;
const modulesDir = path.resolve(REPO, cfg.modulesDir ?? "apps/web/node_modules");

async function loadModule(dir, relatives, what) {
  for (const rel of relatives) {
    const candidate = path.join(dir, rel);
    if (fs.existsSync(candidate)) return import(pathToFileURL(candidate).href);
  }
  throw new Error(`${what} not found in ${dir}. Run "pnpm install" in apps/web.`);
}

const { chromium } = await loadModule(
  modulesDir,
  ["@playwright/test/index.mjs", "@playwright/test/index.js", "playwright/index.mjs", "playwright/index.js"],
  "Playwright",
);

// ---------------------------------------------------------------- steps

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function hasTodo(flow) {
  const text = JSON.stringify(flow.steps ?? []) + JSON.stringify(flow.preconditions ?? []);
  const matches = text.match(/TODO:[^"\\]+/g) ?? [];
  return [...new Set(matches)];
}

async function activeElement(page) {
  return page.evaluate(() => {
    const el = document.activeElement;
    if (!el || el === document.body) return { tag: "body", selector: "body" };
    const parts = [el.tagName.toLowerCase()];
    if (el.id) parts.push(`#${el.id}`);
    for (const attr of ["data-testid", "name", "aria-label", "aria-controls", "role", "type"]) {
      const value = el.getAttribute(attr);
      if (value) parts.push(value === attr ? `[${attr}]` : `[${attr}="${value}"]`);
    }
    return { tag: el.tagName.toLowerCase(), selector: parts.join("") };
  });
}

async function runStep(page, step, index) {
  const note = step.note ?? "";

  if (step.focus) {
    await page.locator(step.focus).first().focus();
    return { ok: true, detail: `focus ${step.focus}`, note };
  }

  if (step.click) {
    await page.locator(step.click).first().click();
    await page.waitForTimeout(step.wait ?? 50);
    return { ok: true, detail: `click ${step.click}`, note };
  }

  if (step.viewport) {
    await page.setViewportSize({ width: step.viewport, height: cfg.viewport?.height ?? 900 });
    await page.waitForTimeout(step.wait ?? 120);
    return { ok: true, detail: `viewport ${step.viewport}`, note };
  }

  if (step.press) {
    const times = step.times ?? 1;
    for (let i = 0; i < times; i += 1) await page.keyboard.press(step.press);
    await page.waitForTimeout(step.wait ?? 60);
    return { ok: true, detail: `press ${step.press}${times > 1 ? ` x${times}` : ""}`, note };
  }

  if (step.wait) {
    await page.waitForTimeout(step.wait);
    return { ok: true, detail: `wait ${step.wait}ms`, note };
  }

  if (step.expectFocus) {
    const active = await activeElement(page);
    const matched = await page.evaluate((selector) => {
      const el = document.activeElement;
      return Boolean(el && el.matches?.(selector));
    }, step.expectFocus);
    assert(matched, `focus expected on ${step.expectFocus}, active is ${active.selector}`);
    return { ok: true, detail: `focus on ${step.expectFocus}`, note };
  }

  if (step.expectFocusIn) {
    const inside = await page.evaluate((selector) => {
      const container = document.querySelector(selector);
      return Boolean(container && document.activeElement && container.contains(document.activeElement));
    }, step.expectFocusIn);
    const active = await activeElement(page);
    assert(inside, `focus expected inside ${step.expectFocusIn}, active is ${active.selector}`);
    return { ok: true, detail: `focus inside ${step.expectFocusIn}`, note };
  }

  if (step.expectVisible || step.expectHidden) {
    const selector = step.expectVisible ?? step.expectHidden;
    const wantVisible = Boolean(step.expectVisible);
    const timeout = step.timeout ?? 3000;
    const state = wantVisible ? "visible" : "hidden";
    try {
      await page.waitForSelector(selector, { state, timeout });
    } catch {
      throw new Error(`${selector} did not become ${state} within ${timeout}ms`);
    }
    return { ok: true, detail: `${selector} is ${state}`, note };
  }

  if (step.expectAttr) {
    const { selector, name, value } = step.expectAttr;
    const actual = await page.locator(selector).first().getAttribute(name);
    assert(
      String(actual) === String(value),
      `${selector}[${name}] = ${actual}, expected ${value}`,
    );
    return { ok: true, detail: `${selector}[${name}]="${value}"`, note };
  }

  if (step.expectCount) {
    const { selector, min, max } = step.expectCount;
    const count = await page.locator(selector).count();
    if (min !== undefined) assert(count >= min, `${selector} count ${count} < ${min}`);
    if (max !== undefined) assert(count <= max, `${selector} count ${count} > ${max}`);
    return { ok: true, detail: `${selector} count ${count}`, note };
  }

  if (step.expectFocusRingOnActive) {
    const minWidth = step.expectFocusRingOnActive.minWidth ?? 2;
    const ring = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el || el === document.body) return { missing: true };
      const style = getComputedStyle(el);
      // The mockup scales stages with CSS zoom; computed outline is in rendered
      // pixels, so normalize back to CSS pixels before comparing to the token.
      const host = el.closest("[data-screen]");
      const zoom = host ? parseFloat(getComputedStyle(host).zoom) || 1 : 1;
      return {
        outlineStyle: style.outlineStyle,
        outlineWidth: (parseFloat(style.outlineWidth) || 0) / zoom,
        boxShadow: style.boxShadow,
        zoom,
        selector: el.tagName.toLowerCase() + (el.id ? `#${el.id}` : ""),
      };
    });
    assert(!ring.missing, "no focused element to check the focus ring on");
    const visibleRing =
      (ring.outlineStyle !== "none" && ring.outlineWidth >= minWidth) ||
      (ring.boxShadow !== "none" && ring.boxShadow !== "");
    assert(
      visibleRing,
      `no visible focus ring on focused element ${ring.selector} (outline ${ring.outlineStyle} ${ring.outlineWidth.toFixed(2)}px CSS)`,
    );
    return {
      ok: true,
      detail: `focus ring ${ring.outlineWidth.toFixed(2)}px ${ring.outlineStyle} on ${ring.selector} (zoom ${ring.zoom})`,
      note,
    };
  }

  if (step.expectFocusRing) {
    const { selector, minWidth = 2 } = step.expectFocusRing;
    await page.locator(selector).first().focus();
    const ring = await page.evaluate((target) => {
      const el = document.querySelector(target);
      if (!el) return null;
      const style = getComputedStyle(el);
      return {
        outlineStyle: style.outlineStyle,
        outlineWidth: style.outlineWidth,
        boxShadow: style.boxShadow,
      };
    }, selector);
    assert(ring !== null, `${selector} not found for focus ring check`);
    const width = parseFloat(ring.outlineWidth) || 0;
    const visibleRing =
      (ring.outlineStyle !== "none" && width >= minWidth) ||
      (ring.boxShadow !== "none" && ring.boxShadow !== "");
    assert(
      visibleRing,
      `no visible focus ring on ${selector} (outline ${ring.outlineStyle} ${ring.outlineWidth}, box-shadow ${ring.boxShadow})`,
    );
    return { ok: true, detail: `focus ring ${ring.outlineWidth} ${ring.outlineStyle}`, note };
  }

  if (step.expectNoFocusEscape) {
    const { container, maxTabs = 30 } = step.expectNoFocusEscape;
    const escapedAt = [];
    for (let i = 0; i < maxTabs; i += 1) {
      await page.keyboard.press("Tab");
      const inside = await page.evaluate((selector) => {
        const node = document.querySelector(selector);
        return Boolean(node && document.activeElement && node.contains(document.activeElement));
      }, container);
      if (!inside) {
        const active = await activeElement(page);
        escapedAt.push(active.selector);
        break;
      }
    }
    assert(
      escapedAt.length === 0,
      `focus escaped ${container} after Tab (landed on ${escapedAt[0]})`,
    );
    return { ok: true, detail: `${maxTabs} Tab presses stayed inside ${container}`, note };
  }

  throw new Error(`step ${index} has no recognised verb: ${JSON.stringify(step)}`);
}

// ---------------------------------------------------------------- run

const startedAt = new Date();
const results = [];
let fails = 0;
let blocked = 0;

const browser = await chromium.launch();

for (const flow of cfg.flows) {
  if (only && !only.includes(flow.id)) continue;

  const record = {
    flow: flow.id,
    name: flow.name,
    k: flow.k ?? [],
    verdict: "FAIL",
    reason: null,
    steps: [],
    durationMs: 0,
  };
  const started = Date.now();
  process.stdout.write(`[flow] ${flow.id} ... `);

  const todos = hasTodo(flow);
  if (todos.length > 0) {
    record.verdict = "BLOCKED";
    record.reason = `unwritten selector(s): ${todos.join(", ")}`;
    blocked += 1;
    results.push(record);
    process.stdout.write(`BLOCKED - ${record.reason}\n`);
    continue;
  }

  const context = await browser.newContext({
    viewport: { width: flow.viewport ?? cfg.viewport?.width ?? 1440, height: cfg.viewport?.height ?? 900 },
    colorScheme: flow.theme === "dark" ? "dark" : "light",
    reducedMotion: "reduce",
    locale: cfg.locale ?? "id-ID",
  });

  try {
    const page = await context.newPage();
    await page.goto(baseUrl, { waitUntil: "load", timeout: 30000 });
    await page.waitForTimeout(cfg.settle ?? 100);

    for (const [index, step] of (flow.steps ?? []).entries()) {
      try {
        const outcome = await runStep(page, step, index);
        record.steps.push({ index, status: "PASS", ...outcome });
      } catch (error) {
        record.steps.push({
          index,
          status: "FAIL",
          detail: error.message.split("\n")[0],
          note: step.note ?? "",
        });
        throw error;
      }
    }
    record.verdict = "PASS";
  } catch (error) {
    record.verdict = "FAIL";
    record.reason = error.message.split("\n")[0];
  } finally {
    record.durationMs = Date.now() - started;
    await context.close().catch(() => {});
    if (record.verdict === "FAIL") fails += 1;
    process.stdout.write(
      `${record.verdict}${record.reason ? ` - ${record.reason}` : ""} (${record.durationMs}ms)\n`,
    );
  }

  results.push(record);
}

await browser.close();

// ---------------------------------------------------------------- report

const summary = {
  label,
  target: baseUrl,
  config: path.relative(REPO, cfgPath),
  startedAt: startedAt.toISOString(),
  finishedAt: new Date().toISOString(),
  counts: {
    flows: results.length,
    pass: results.filter((r) => r.verdict === "PASS").length,
    fail: results.filter((r) => r.verdict === "FAIL").length,
    blocked: results.filter((r) => r.verdict === "BLOCKED").length,
  },
  exitCode: fails > 0 ? 1 : blocked > 0 ? 2 : 0,
  flows: results,
};

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, `${label}.json`), `${JSON.stringify(summary, null, 2)}\n`);

const lines = [`# Keyboard flows - ${label}`, ""];
lines.push(`- Target: \`${baseUrl}\``);
lines.push(`- Config: \`${summary.config}\``);
lines.push(`- Run: ${summary.startedAt} -> ${summary.finishedAt}`);
lines.push(
  `- Totals: ${summary.counts.flows} flows, ${summary.counts.pass} PASS, ${summary.counts.fail} FAIL, ${summary.counts.blocked} BLOCKED`,
);
lines.push(`- Exit code: ${summary.exitCode}`, "");
lines.push("| Flow | K | Verdict | Steps passed | Note |");
lines.push("|---|---|---|---|---|");
for (const r of results) {
  const passed = r.steps.filter((s) => s.status === "PASS").length;
  lines.push(`| ${r.flow} | ${r.k.join(", ") || "-"} | ${r.verdict} | ${passed}/${r.steps.length} | ${r.reason ?? ""} |`);
}

for (const r of results) {
  lines.push("", `## ${r.flow} - ${r.name ?? ""}`, "");
  if (r.reason) lines.push(`Result: **${r.verdict}** - ${r.reason}`, "");
  if (r.steps.length > 0) {
    lines.push("| # | Status | Step | Note |", "|---|---|---|---|");
    for (const step of r.steps) {
      lines.push(`| ${step.index} | ${step.status} | ${step.detail.replace(/\|/g, "\\|")} | ${step.note.replace(/\|/g, "\\|")} |`);
    }
  }
}

fs.writeFileSync(path.join(outDir, `${label}.md`), `${lines.join("\n")}\n`);

console.log(
  `${label}: ${summary.counts.flows} flows -> ${summary.counts.pass} PASS, ${summary.counts.fail} FAIL, ${summary.counts.blocked} BLOCKED`,
);
console.log(`json: ${path.relative(REPO, path.join(outDir, `${label}.json`))}`);
console.log(`md:   ${path.relative(REPO, path.join(outDir, `${label}.md`))}`);

process.exit(summary.exitCode);
