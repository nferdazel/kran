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
   */
  import { onMount } from "svelte";

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

<div class="users-head">
  <h1 class="users-title">{m.users_title()}</h1>
  <p class="users-intro">{m.users_intro()}</p>
</div>

{#if !allowed}
  <p class="kran-alert" role="alert">{m.users_denied()}</p>
{:else if loading}
  <p role="status">{m.users_loading()}</p>
{:else}
  {#if errorMessage}
    <p class="kran-alert" role="alert">{errorMessage}</p>
    <p>
      <button class="kran-button" type="button" onclick={() => void load()}>{m.app_retry()}</button>
    </p>
  {/if}
  {#if actionError}
    <p class="kran-alert" role="alert">{actionError}</p>
  {/if}
  {#if notice}
    <p role="status">{notice}</p>
  {/if}

  <section class="kran-card" aria-labelledby="users-heading">
    <h2 id="users-heading">{m.users_title()}</h2>
    {#if users.length === 0}
      <p class="kran-muted">{m.users_empty()}</p>
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
      <div class="kran-table-wrap" role="region" tabindex="0" aria-label={m.common_table_region({ name: m.users_title() })}>
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
                  <span class="kran-badge">{statusLabel(user.status)}</span>
                </td>
                <td>
                  {#if user.roles.length === 0}
                    <span class="kran-muted">{m.users_roles_empty()}</span>
                  {:else}
                    <ul class="users-roles">
                      {#each user.roles as grant (`${grant.role}|${grant.branchId ?? ""}`)}
                        <li>
                          <span class="kran-badge kran-badge--info">{roleLabel(grant.role)}</span>
                          {#if grant.branchId !== null}
                            <span class="kran-muted users-branch">
                              {m.users_role_branch({ branch: grant.branchId })}
                            </span>
                          {/if}
                        </li>
                      {/each}
                    </ul>
                  {/if}
                </td>
                <td>
                  <button
                    class="kran-button"
                    type="button"
                    aria-expanded={expandedId === user.userId}
                    onclick={() => toggle(user)}
                  >
                    {expandedId === user.userId ? m.users_close() : m.users_manage()}
                  </button>
                </td>
              </tr>

              {#if expandedId === user.userId}
                <tr class="users-panel-row">
                  <td colspan="5">
                    <div class="users-panel">
                      <section aria-labelledby={`users-roles-${user.userId}`}>
                        <h3 id={`users-roles-${user.userId}`}>{m.users_roles_heading()}</h3>
                        {#if user.roles.length === 0}
                          <p class="kran-muted">{m.users_roles_empty()}</p>
                        {:else}
                          <ul class="users-grant-list">
                            {#each user.roles as grant (`${grant.role}|${grant.branchId ?? ""}`)}
                              <li class="users-grant">
                                <span>
                                  <span class="kran-badge kran-badge--info">{roleLabel(grant.role)}</span>
                                  {#if grant.branchId !== null}
                                    <span class="kran-muted users-branch">
                                      {m.users_role_branch({ branch: grant.branchId })}
                                    </span>
                                  {/if}
                                </span>
                                {#if confirm?.kind === "revoke" &&
                                confirm.userId === user.userId &&
                                confirm.role === grant.role &&
                                confirm.branchId === grant.branchId}
                                  <span class="users-buttons">
                                    <span class="kran-muted">{m.users_revoke_confirm()}</span>
                                    <button
                                      class="kran-button kran-button--primary"
                                      type="button"
                                      disabled={busy === user.userId}
                                      onclick={() => void revoke(grant, user)}
                                    >
                                      {busy === user.userId ? m.users_revoking() : m.users_revoke({ role: roleLabel(grant.role) })}
                                    </button>
                                    <button class="kran-button" type="button" onclick={clearOutcome}>
                                      {m.users_cancel()}
                                    </button>
                                  </span>
                                {:else}
                                  <button
                                    class="kran-button"
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
                                  </button>
                                {/if}
                              </li>
                            {/each}
                          </ul>
                        {/if}
                      </section>

                      <section aria-labelledby={`users-assign-${user.userId}`}>
                        <h3 id={`users-assign-${user.userId}`}>{m.users_assign_heading()}</h3>
                        <form class="users-assign" onsubmit={(event) => void assign(event, user)} novalidate>
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
                            <p class="users-form-error" role="alert">{formError}</p>
                          {/if}
                          <button
                            class="kran-button kran-button--primary"
                            type="submit"
                            disabled={busy === user.userId || selectedRoleCode === ""}
                          >
                            {busy === user.userId ? m.users_assigning() : m.users_assign_submit()}
                          </button>
                        </form>
                      </section>

                      <section aria-labelledby={`users-status-${user.userId}`}>
                        <h3 id={`users-status-${user.userId}`}>{m.users_status_heading()}</h3>
                        <div class="users-buttons">
                          {#each availableStatusActions(user.status) as action (action)}
                            {#if confirm?.kind === "status" && confirm.userId === user.userId && confirm.action === action}
                              <span class="users-buttons">
                                <span class="kran-muted">{statusConfirmOf(action)}</span>
                                <button
                                  class="kran-button kran-button--primary"
                                  type="button"
                                  disabled={busy === user.userId}
                                  onclick={() => void changeStatus(user, action)}
                                >
                                  {busy === user.userId ? m.users_working() : statusLabelOf(action)}
                                </button>
                                <button class="kran-button" type="button" onclick={clearOutcome}>
                                  {m.users_cancel()}
                                </button>
                              </span>
                            {:else}
                              <button
                                class="kran-button"
                                type="button"
                                onclick={() => {
                                  clearOutcome();
                                  confirm = { kind: "status", userId: user.userId, action };
                                }}
                              >
                                {statusLabelOf(action)}
                              </button>
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

<style>
  .users-head {
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .users-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .users-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 60ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .users-roles,
  .users-grant-list {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
  }

  .users-grant {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
    justify-content: space-between;
  }

  .users-branch {
    font-size: var(--text-sm);
    overflow-wrap: anywhere;
  }

  .users-panel {
    display: grid;
    gap: var(--space-4);
    padding-block: var(--space-2);
  }

  .users-assign {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    max-inline-size: 30rem;
  }

  .users-buttons {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }

  .users-form-error {
    color: var(--color-text-danger, var(--color-text));
    margin: 0;
  }
</style>
