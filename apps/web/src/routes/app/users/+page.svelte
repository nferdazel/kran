<script lang="ts">
  /**
   * Administrasi pengguna & role (T-117): daftar akun operator, penugasan/pencabutan role, dan
   * siklus status akun. Server adalah otoritas terakhir; layar ini menyaring aksi yang tidak masuk
   * akal dari status/scope role, lalu memetakan penolakan server (`params.reason`) ke pesan katalog.
   *
   * Keputusan yang mengikat:
   *  - Gerbang izin `platform.user.manage` (spec §13): tanpa izin, layar menampilkan pesan ditolak
   *    dan **tidak** memanggil API (server tetap 403 bila dipaksa).
   *  - Konfirmasi = satu lapisan **inline** (DESIGN §7), bukan `window.confirm` dan bukan modal.
   *  - Role ber-scope `BRANCH` memunculkan input cabang; role institusi menyembunyikannya. Aturan
   *    bentuknya sama dengan server (`assignRoleError`, cerminan `roleAssignmentProblem`).
   *
   * Tabel sengaja tetap ditulis di sini, bukan lewat `DataTable`: panel kelola adalah baris kedua di
   * dalam tabel yang sama, dan komponen bersama belum punya bentuk itu. Aturan visualnya tetap milik
   * `packages/ui` (`.kran-table`, `.kran-badge`, …); tidak ada CSS lokal di berkas ini.
   */
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { roleLabel } from "#lib/app/roles.js";
  import {
    assignErrorText,
    assignRoleError,
    availableStatusActions,
    statusLabel,
    userProblemMessage,
    type StatusAction,
  } from "#lib/app/users.js";
  import type { RoleSummary, SessionInfo, UserRoleGrant, UserSummary } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session: SessionInfo = $derived(data.session);
  const allowed = $derived(session.permissions.includes("platform.user.manage"));

  let users = $state<UserSummary[]>([]);
  let roles = $state<RoleSummary[]>([]);
  let loading = $state(true);
  let errorMessage = $state("");
  let actionError = $state("");
  let notice = $state("");
  let busy = $state("");
  /** Baris yang panelnya sedang terbuka; `null` = tidak ada. */
  let expandedId = $state<string | null>(null);
  /** Konfirmasi inline yang sedang terbuka. */
  let confirm = $state<
    | { kind: "revoke"; userId: string; role: string; branchId: string | null }
    | { kind: "status"; userId: string; action: StatusAction }
    | null
  >(null);

  // Form penugasan (berlaku untuk baris yang sedang terbuka).
  let selectedRoleCode = $state("");
  let branchInput = $state("");
  let formError = $state("");

  const selectedRole = $derived(roles.find((role) => role.code === selectedRoleCode));

  /** Warna hanya penguat: makna status tetap dari teksnya (DESIGN §1, §8). */
  function statusTone(status: string): "positive" | "warning" | "negative" | "neutral" {
    if (status === "ACTIVE") return "positive";
    if (status === "LOCKED") return "warning";
    if (status === "SUSPENDED") return "negative";
    return "neutral";
  }

  async function load(showLoading = true): Promise<void> {
    if (!allowed) {
      loading = false;
      return;
    }
    if (showLoading) loading = true;
    errorMessage = "";
    try {
      const [usersReply, rolesReply] = await Promise.all([
        api.GET("/api/v1/users"),
        api.GET("/api/v1/roles"),
      ]);
      if (usersReply.error) {
        errorMessage = userProblemMessage(usersReply.error);
        return;
      }
      if (rolesReply.error) {
        errorMessage = userProblemMessage(rolesReply.error);
        return;
      }
      users = usersReply.data?.items ?? [];
      roles = rolesReply.data?.items ?? [];
    } catch {
      errorMessage = m.error_generic();
    } finally {
      loading = false;
    }
  }

  function errorFrom(problem: unknown): string {
    return api.isProblem(problem) ? userProblemMessage(problem) : m.error_generic();
  }

  function clearOutcome(): void {
    actionError = "";
    notice = "";
    formError = "";
    confirm = null;
  }

  function toggle(user: UserSummary): void {
    clearOutcome();
    selectedRoleCode = "";
    branchInput = "";
    expandedId = expandedId === user.userId ? null : user.userId;
  }

  async function assign(event: SubmitEvent, user: UserSummary): Promise<void> {
    event.preventDefault();
    clearOutcome();
    const problem = assignRoleError(selectedRole, branchInput);
    if (problem !== null) {
      formError = assignErrorText(problem);
      return;
    }
    const branch = branchInput.trim();
    busy = user.userId;
    try {
      const { response, error } = await api.POST("/api/v1/users/{userId}/roles", {
        params: { path: { userId: user.userId } },
        body: { role: selectedRoleCode, ...(branch === "" ? {} : { branchId: branch }) },
      });
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      notice = m.users_assign_done();
      selectedRoleCode = "";
      branchInput = "";
      await load(false);
    } catch {
      actionError = m.error_generic();
    } finally {
      busy = "";
    }
  }

  async function revoke(grant: UserRoleGrant, user: UserSummary): Promise<void> {
    if (busy !== "") return;
    clearOutcome();
    busy = user.userId;
    try {
      const { response, error } = await api.DELETE("/api/v1/users/{userId}/roles/{role}", {
        params: {
          path: { userId: user.userId, role: grant.role },
          ...(grant.branchId === null ? {} : { query: { branchId: grant.branchId } }),
        },
      });
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      notice = m.users_revoke_done();
      await load(false);
    } catch {
      actionError = m.error_generic();
    } finally {
      busy = "";
    }
  }

  async function changeStatus(user: UserSummary, action: StatusAction): Promise<void> {
    if (busy !== "") return;
    clearOutcome();
    busy = user.userId;
    try {
      const result =
        action === "disable"
          ? await api.POST("/api/v1/users/{userId}/disable", {
              params: { path: { userId: user.userId } },
            })
          : action === "enable"
            ? await api.POST("/api/v1/users/{userId}/enable", {
                params: { path: { userId: user.userId } },
              })
            : await api.POST("/api/v1/users/{userId}/unlock", {
                params: { path: { userId: user.userId } },
              });
      if (!result.response.ok) {
        actionError = errorFrom(result.error);
        return;
      }
      notice =
        action === "disable"
          ? m.users_disable_done()
          : action === "enable"
            ? m.users_enable_done()
            : m.users_unlock_done();
      await load(false);
    } catch {
      actionError = m.error_generic();
    } finally {
      busy = "";
    }
  }

  function statusLabelOf(action: StatusAction): string {
    if (action === "disable") return m.users_disable();
    if (action === "enable") return m.users_enable();
    return m.users_unlock();
  }

  function statusConfirmOf(action: StatusAction): string {
    if (action === "disable") return m.users_disable_confirm();
    if (action === "enable") return m.users_enable_confirm();
    return m.users_unlock_confirm();
  }

  function scopeLabel(scope: string): string {
    return scope === "BRANCH" ? m.users_scope_branch() : m.users_scope_institution();
  }

  onMount(() => {
    void load();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.users_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.users_title()}</h1>
    <p class="kran-page-header__intro">{m.users_intro()}</p>
  </div>
</div>

{#if !allowed}
  <Alert tone="negative" title={m.users_denied()} />
{:else if loading}
  <p role="status">{m.users_loading()}</p>
{:else}
  {#if errorMessage}
    <Alert tone="negative" title={errorMessage}>
      <Button type="button" onclick={() => void load()}>{m.app_retry()}</Button>
    </Alert>
  {/if}
  {#if actionError}
    <Alert tone="negative" title={actionError} />
  {/if}
  {#if notice}
    <Alert tone="positive" title={notice} />
  {/if}

  <section class="kran-section" aria-labelledby="users-heading">
    <h2 class="kran-section__title" id="users-heading">{m.users_title()}</h2>
    {#if users.length === 0}
      <EmptyState title={m.users_empty()} />
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
      <div
        class="kran-table-wrap"
        role="region"
        tabindex="0"
        aria-label={m.common_table_region({ name: m.users_title() })}
      >
        <table class="kran-table">
          <caption class="kran-visually-hidden">{m.users_title()}</caption>
          <thead>
            <tr>
              <th scope="col">{m.users_col_username()}</th>
              <th scope="col">{m.users_col_name()}</th>
              <th scope="col">{m.users_col_status()}</th>
              <th scope="col">{m.users_col_roles()}</th>
              <th scope="col">{m.users_col_actions()}</th>
            </tr>
          </thead>
          <tbody>
            {#each users as user (user.userId)}
              <tr>
                <th scope="row">{user.username}</th>
                <td>{user.fullName}</td>
                <td>
                  <StatusBadge tone={statusTone(user.status)}>{statusLabel(user.status)}</StatusBadge>
                </td>
                <td>
                  {#if user.roles.length === 0}
                    <span class="kran-muted">{m.users_roles_empty()}</span>
                  {:else}
                    <ul class="kran-list-plain">
                      {#each user.roles as grant (`${grant.role}|${grant.branchId ?? ""}`)}
                        <li class="kran-actions">
                          <StatusBadge tone="info">{roleLabel(grant.role)}</StatusBadge>
                          {#if grant.branchId !== null}
                            <span class="kran-muted">
                              {m.users_role_branch({ branch: grant.branchId })}
                            </span>
                          {/if}
                        </li>
                      {/each}
                    </ul>
                  {/if}
                </td>
                <td>
                  <Button
                    type="button"
                    aria-expanded={expandedId === user.userId}
                    onclick={() => toggle(user)}
                  >
                    {expandedId === user.userId ? m.users_close() : m.users_manage()}
                  </Button>
                </td>
              </tr>

              {#if expandedId === user.userId}
                <tr>
                  <td colspan="5">
                    <div class="kran-stack kran-stack--loose">
                      <section class="kran-section" aria-labelledby={`users-roles-${user.userId}`}>
                        <h3 class="kran-section__title" id={`users-roles-${user.userId}`}>
                          {m.users_roles_heading()}
                        </h3>
                        {#if user.roles.length === 0}
                          <p class="kran-muted">{m.users_roles_empty()}</p>
                        {:else}
                          <ul class="kran-list-plain">
                            {#each user.roles as grant (`${grant.role}|${grant.branchId ?? ""}`)}
                              <li class="kran-toolbar">
                                <span class="kran-actions">
                                  <StatusBadge tone="info">{roleLabel(grant.role)}</StatusBadge>
                                  {#if grant.branchId !== null}
                                    <span class="kran-muted">
                                      {m.users_role_branch({ branch: grant.branchId })}
                                    </span>
                                  {/if}
                                </span>
                                {#if confirm?.kind === "revoke" &&
                                confirm.userId === user.userId &&
                                confirm.role === grant.role &&
                                confirm.branchId === grant.branchId}
                                  <span class="kran-actions">
                                    <span class="kran-muted">{m.users_revoke_confirm()}</span>
                                    <Button
                                      variant="primary"
                                      type="button"
                                      disabled={busy === user.userId}
                                      onclick={() => void revoke(grant, user)}
                                    >
                                      {busy === user.userId
                                        ? m.users_revoking()
                                        : m.users_revoke({ role: roleLabel(grant.role) })}
                                    </Button>
                                    <Button type="button" onclick={clearOutcome}>
                                      {m.users_cancel()}
                                    </Button>
                                  </span>
                                {:else}
                                  <Button
                                    type="button"
                                    onclick={() => {
                                      clearOutcome();
                                      confirm = {
                                        kind: "revoke",
                                        userId: user.userId,
                                        role: grant.role,
                                        branchId: grant.branchId,
                                      };
                                    }}
                                  >
                                    {m.users_revoke({ role: roleLabel(grant.role) })}
                                  </Button>
                                {/if}
                              </li>
                            {/each}
                          </ul>
                        {/if}
                      </section>

                      <section class="kran-section" aria-labelledby={`users-assign-${user.userId}`}>
                        <h3 class="kran-section__title" id={`users-assign-${user.userId}`}>
                          {m.users_assign_heading()}
                        </h3>
                        <form
                          class="kran-form"
                          onsubmit={(event) => void assign(event, user)}
                          novalidate
                        >
                          <div class="kran-field">
                            <label class="kran-label" for={`users-role-${user.userId}`}>
                              {m.users_assign_role_label()}
                            </label>
                            <select
                              class="kran-input"
                              id={`users-role-${user.userId}`}
                              bind:value={selectedRoleCode}
                            >
                              <option value="">—</option>
                              {#each roles as role (role.code)}
                                <option value={role.code}>
                                  {roleLabel(role.code)} ({scopeLabel(role.scope)})
                                </option>
                              {/each}
                            </select>
                          </div>
                          {#if selectedRole?.scope === "BRANCH"}
                            <div class="kran-field">
                              <label class="kran-label" for={`users-branch-${user.userId}`}>
                                {m.users_assign_branch_label()}
                              </label>
                              <input
                                class="kran-input"
                                id={`users-branch-${user.userId}`}
                                bind:value={branchInput}
                                autocomplete="off"
                                spellcheck="false"
                                aria-describedby={`users-branch-hint-${user.userId}`}
                              />
                              <p class="kran-muted" id={`users-branch-hint-${user.userId}`}>
                                {m.users_assign_branch_hint()}
                              </p>
                            </div>
                          {/if}
                          {#if formError !== ""}
                            <Alert tone="negative" title={formError} />
                          {/if}
                          <div class="kran-actions">
                            <Button
                              variant="primary"
                              type="submit"
                              disabled={busy === user.userId || selectedRoleCode === ""}
                            >
                              {busy === user.userId ? m.users_assigning() : m.users_assign_submit()}
                            </Button>
                          </div>
                        </form>
                      </section>

                      <section class="kran-section" aria-labelledby={`users-status-${user.userId}`}>
                        <h3 class="kran-section__title" id={`users-status-${user.userId}`}>
                          {m.users_status_heading()}
                        </h3>
                        <div class="kran-actions">
                          {#each availableStatusActions(user.status) as action (action)}
                            {#if confirm?.kind === "status" &&
                            confirm.userId === user.userId &&
                            confirm.action === action}
                              <span class="kran-actions">
                                <span class="kran-muted">{statusConfirmOf(action)}</span>
                                <Button
                                  variant="primary"
                                  type="button"
                                  disabled={busy === user.userId}
                                  onclick={() => void changeStatus(user, action)}
                                >
                                  {busy === user.userId
                                    ? m.users_working()
                                    : statusLabelOf(action)}
                                </Button>
                                <Button type="button" onclick={clearOutcome}>
                                  {m.users_cancel()}
                                </Button>
                              </span>
                            {:else}
                              <Button
                                type="button"
                                onclick={() => {
                                  clearOutcome();
                                  confirm = { kind: "status", userId: user.userId, action };
                                }}
                              >
                                {statusLabelOf(action)}
                              </Button>
                            {/if}
                          {/each}
                        </div>
                      </section>
                    </div>
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
{/if}
