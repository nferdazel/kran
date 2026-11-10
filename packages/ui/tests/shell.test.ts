import { createRawSnippet } from "svelte";
import { render } from "svelte/server";
import { describe, expect, it } from "vitest";

import AppShell from "../src/components/AppShell.svelte";
import NavItem from "../src/components/NavItem.svelte";
import Sidebar, { type SidebarGroup } from "../src/components/Sidebar.svelte";
import Topbar from "../src/components/Topbar.svelte";

/**
 * Shell contract (T-285, SPEC section 2). Rendered through `svelte/server` for the same reason as
 * `components.test.ts`: no jsdom dependency. Only markup that exists on first render is asserted
 * here; the off-canvas open/Escape/focus behaviour needs a DOM and is covered by the Playwright
 * a11y gate, not by this file.
 */
function text(markup: string) {
  return createRawSnippet(() => ({ render: () => markup }));
}

/** Snippet that accepts the shell's arguments, so `{@render sidebar(...)}` type-checks. */
function snippetWithApi(markup: string) {
  return createRawSnippet(() => ({ render: () => markup }));
}

const groups: SidebarGroup[] = [
  {
    id: "cash",
    label: "Cash",
    links: [
      { href: "/app/teller", label: "Teller", current: true },
      { href: "/app/vault", label: "Vault", current: false },
    ],
  },
];

describe("NavItem", () => {
  it("active item carries aria-current=page; inactive does not", () => {
    const active = render(NavItem, { props: { href: "/app/teller", label: "Teller", current: true } });
    expect(active.body).toContain('aria-current="page"');

    const inactive = render(NavItem, { props: { href: "/app/vault", label: "Vault" } });
    expect(inactive.body).not.toContain("aria-current");
  });
});

describe("Sidebar", () => {
  it("renders one navigation landmark with permission-filtered links and group labels", () => {
    const { body } = render(Sidebar, { props: { groups, navLabel: "Primary navigation" } });

    expect(body).toMatch(/<nav class="sidebar__nav[^"]*" aria-label="Primary navigation"/);
    expect(body).toContain("Cash");
    expect(body).toContain('href="/app/teller"');
    expect(body).toContain('href="/app/vault"');
    expect(body).toContain('aria-current="page"');
  });

  it("does not render a second h1-level heading (group label is a paragraph)", () => {
    const { body } = render(Sidebar, { props: { groups, navLabel: "Primary navigation" } });
    expect(body).not.toContain("<h2");
  });
});

describe("Topbar", () => {
  const props = {
    breadcrumb: [{ label: "KRAN" }, { label: "Ledger" }],
    menuLabel: "Open navigation",
    breadcrumbLabel: "Breadcrumb",
    menuOpen: false,
    sidebarId: "app-sidebar",
    onMenuToggle: () => {},
  };

  it("always renders the menu button that names the panel, with state", () => {
    const { body } = render(Topbar, { props });

    expect(body).toContain('aria-label="Open navigation"');
    expect(body).toContain('aria-controls="app-sidebar"');
    expect(body).toContain('aria-expanded="false"');
    expect(body).toContain("data-shell-menu-button");
  });

  it("marks the last crumb as the current page", () => {
    const { body } = render(Topbar, { props });
    expect(body).toMatch(/aria-current="page"[^>]*>Ledger/);
  });
});

describe("AppShell", () => {
  it("renders the skip link, #main and both composed regions", () => {
    const { body } = render(AppShell, {
      props: {
        skipLabel: "Skip to main content",
        sidebar: snippetWithApi("<p>sidebar</p>"),
        topbar: snippetWithApi("<p>topbar</p>"),
        children: text("<p>content</p>"),
      },
    });

    expect(body).toContain('href="#main"');
    expect(body).toContain('id="main"');
    expect(body).toContain('id="app-sidebar"');
    expect(body).toContain("<p>sidebar</p>");
    expect(body).toContain("<p>topbar</p>");
    expect(body).toContain("<p>content</p>");
  });
});
