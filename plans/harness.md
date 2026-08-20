# Plan: Omarchy Harness — the OS as a DeepSeek Harness profile

Revision 1.

## Problem

Omarchy already treats coding agents as first-class citizens, but it treats them as **guests**: a default CLI picked from a list, launched in a TUI window, pointed at `~/Work`, handed a markdown skill, and trusted to shell out. That is "an agent on Linux." It is not "a Linux that an agent can drive."

DeepSeek Harness (`dsh`) is the missing control plane. It is an MIT-licensed agent runtime whose rule is **everything is a plugin**: the model adapter, tool registry, session log, sandbox, approval policy, and the agent loop itself are Cordis plugins composed at boot from a profile. A running `dsh` is not an app with an extension API. It is a plugin tree.

Today those two systems do not meet:

- Omarchy's effectors (`omarchy theme set`, `omarchy-shell` IPC, Hyprland, pacman, notifications, snapshots) are excellent, typed, and already the safe way to change the machine — but the model only reaches them by guessing bash, or by reading a skill that tells it to guess bash.
- Harness has seams for tools, sandbox, approval, skills, jobs, and ACP — but its default world is a project workspace, not a graphical session.
- The session log that Harness treats as source of truth never sees an OS mutation. Theme changes, package installs, and window moves are invisible to resume, fork, replay, and policy.
- Privilege is inverted for agents: Omarchy's rule is `sudo` in a terminal and `pkexec` when there is no TTY, while every shipped agent launcher starts in a don't-stop-to-ask mode. The skill even warns that an agent can make a mess of `~/.config`.

The product gap is not "ship `dsh` in the menu." It is to **invert the relationship**: Harness becomes the session's control plane, and Omarchy becomes the capability world that plane composes. The human still has keybindings, the menu, and the bar. Those surfaces become clients of the same event log the model reads, instead of a parallel control path the agent cannot see.

## Shape

One overlay, not a fork of either tree:

- **Do not fork** [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). Upstream is a developer preview; Cordis already lets an out-of-tree bundle patch every row. Pin a tested `dsh` release the way `oh-my-dsh` does, and stack our own bundle on `dsh-base`.
- **Do not replace** Hyprland, Quickshell, or the `omarchy-*` CLI. Those remain the data plane. Harness never talks to pacman, hyprctl, or DBus as a pile of ad-hoc argv. It talks to Omarchy commands and shell IPC, which already own backups, theming, and privilege.
- **Do not merge** the three plugin systems. Cordis plugins (agent capabilities), Quickshell plugins (desktop surfaces), and `omarchy-*` binaries (OS effectors) are different grains. The work is to compose them, not to collapse them.

What ships:

- A Cordis bundle `dsh-omarchy` and a profile `omarchy` that boots as a user systemd service for the graphical session.
- Typed OS tools and a small set of `ctx.omarchy.*` seams, so "set the theme" is a tool with a schema, not a bash string.
- The existing `default/agents/skills/omarchy` tree mounted as a Harness skill provider.
- Desktop surfaces that speak ACP / `session/event`: a shell overlay for conversation and approval, plus `omarchy harness …` for headless turns.
- Policy: observe freely, mutate the session with confirmation when it is hard to undo, mutate the system only through `ctx.approval` and the existing `sudo`/`pkexec` line.

```text
 User / keybind / menu / bar / overlay / omarchy harness …
                         │
                         │  ACP  ·  ctx.commands  ·  session/event
                         ▼
              DeepSeek Harness  (profile: omarchy)
         dsh-base  +  dsh-omarchy  +  user cordis.patch.yml
     ctx.sessions  ctx.tools  ctx.approval  ctx.sandbox  ctx.skills
                         │
                         │  typed tools, not raw bash as the OS spine
                         ▼
              Omarchy effectors  (data plane)
     bin/omarchy-*   omarchy-shell IPC   hyprctl
     systemd --user  pkexec / sudo       notify / snapshot
```

A turn that changes the machine looks like any other Harness turn. The durable facts live in the session log. The live work is interceptable. The UI renders from the same events.

```text
turn/start
  claim user intent ("switch to tokyo-night, then snapshot")
  assemble omarchy skill + OS tool schemas + history
  -> agent/pre-step
     step/start
     agent/request -> llm/stream -> assistant/message
     tool/call omarchy_theme_set
       tools/pre-execute (permission preset, maybe ask)
       execute -> omarchy theme set tokyo-night
       tools/post-execute
     tool/result  (theme changed; session event omarchy/theme)
     tool/call omarchy_snapshot_create
       tools/pre-execute -> ctx.approval (desktop prompt / pkexec)
       execute -> omarchy snapshot …
     tool/result
     step/end
  -> agent/turn-stopping
turn/end
```

## Rejected approaches

- **A new kernel / distro from scratch**: Omarchy is already the opinionated Arch + Hyprland + Quickshell OS. Rebuilding Linux to host an agent throws away the CLI, the menu, snapshots, and the update pipeline. The harness-native OS is a control-plane inversion of this tree, not a different kernel.
- **Fork `deepseek-harness` into this repo**: permanent drift against a preview that will break APIs. Cordis exists so we do not patch a privileged core. Pin, overlay, dump-config, patch by id.
- **MCP wrapping every `omarchy-*` binary**: MCP is the right door for *third-party* tools. As the OS spine it loses session events, approval waterfalls, sandbox policy, and the ability to swap a provider (local session vs a remote box) without rewriting consumers. MCP can sit beside the seams, not under them.
- **One generated tool per CLI command**: `omarchy commands --json` is the discovery source, not the tool catalog. Many commands are interactive wizards, TUIs, or hidden plumbing. A model with 200 write tools will bash through them. Curate a small typed catalog; keep `omarchy_cli` as an allowlisted escape hatch.
- **Raw `bash` as the OS control tool**: Harness already has a sandboxed shell for project files. `$HOME`, `/etc`, and `/usr` are not a project. Unrestricted bash is how agents already make a mess of configs. OS mutations go through typed tools that call Omarchy.
- **Replace the agent launcher list**: Claude, Codex, Pi, and the rest stay. Harness is the *OS* agent, not a ban on coding CLIs. Subagent providers can still delegate a coding turn to those products. `omarchy-agent` keeps launching the user's default coding CLI into `~/Work`.
- **dsh web as the desktop**: the shipped browser UI is a valid debug and headless-admin surface. The session's primary conversation belongs in Quickshell, themed, keybound, and able to raise an approval card without opening Chromium.
- **A "Harness edition" that uninstalls the GUI**: that is the Server plan's job. This plan is the desktop control plane. A later headless profile can stack `dsh-omarchy` minus the shell overlay on Omarchy Server; it is not v1.
- **Trust `$HOME` as the Harness workspace**: coding agents already refuse this, and `omarchy-agent` relocates to `~/Work`. The OS agent gets a dedicated session root (`~/.local/state/omarchy/harness/workspace`) plus explicit filesystem policy for `~/.config`. It does not get the whole home directory as cwd.

## Design

### 1. Profile and bundle

A running graphical session boots one long-lived `dsh` with profile `omarchy`.

Composition order, same as upstream:

1. `@deepseek-ai/dsh-base` — model adapters, tools, persistence, sandbox, approval, credentials, telemetry
2. `dsh-omarchy` — our bundle: OS seams, OS tools, skill mount, ACP host bindings, desktop prompt sections
3. optional `dsh-web-app` when the user wants the browser UI on loopback
4. the profile's `cordis.patch.yml`
5. `$DSH_HOME/cordis.patch.yml` (user overlay)
6. `--patch` for tests and `omarchy harness dump-config`

`$DSH_HOME` is `~/.local/state/omarchy/harness/home`, not `~/.dsh`. Packaging owns the profile templates under `$OMARCHY_PATH/harness/`. User overlays live under `~/.config/omarchy/harness/` so a dotfile manager can version them. Generated runtime state (sessions, logs, sockets) stays in `~/.local/state/`.

Pin the upstream npm release in the bundle's package.json. `omarchy update` does not silently float to `dsh@next`. A canary job can, later; v1 does not.

`dsh --profile omarchy --dump-config` is the authority for "what actually booted." Every OS tool is a row that a user patch can replace.

### 2. Process model

`omarchy-harness.service` is a systemd user unit, `WantedBy=graphical-session.target`, started from first-run alongside the other session units. It runs the Harness host (Node, pinned). It does not run as root.

The host exposes:

- a Unix socket ACP server under `XDG_RUNTIME_DIR` (coding UIs and the Quickshell overlay attach here)
- a headless stdin/stdout mode for `omarchy harness run` / `omarchy harness prompt`
- optional loopback web UI, off by default, guarded like other local-only services

If the unit is dead, the desktop is still a desktop. Menu, bar, and `omarchy-*` keep working. Harness is the preferred control plane, not a boot dependency. `omarchy harness status` is an `hw-*`-style predicate so scripts and menu guards can test liveness without parsing logs.

Crash policy: the unit restarts. The overlay shows a toast via `omarchy-notification-send`. In-flight turns fail closed; the session log keeps the durable prefix. This matches Harness's own "model-visible means logged" invariant — a restarted host reconstructs context from the log, not from RAM.

### 3. Capability seams (`ctx.omarchy.*`)

Follow Harness's seam rule: a capability is a **service definition**, a **provider**, and a **consumer** (usually a model-facing tool). Swapping the provider moves every consumer. That is how the same tools can later drive a remote Omarchy box or a VM without forking the tools.

v1 seams (small, real, replaceable):

| Seam | Owns | Default provider | Consumers |
|---|---|---|---|
| `ctx.omarchy.session` | live desktop facts: theme, outputs, workspaces, shell plugins, edition | local: CLI + `omarchy-shell` IPC | observe tools, prompt sections |
| `ctx.omarchy.dispatch` | run one allowlisted `omarchy <group> <name>` with argv, cwd, and privilege policy | local subprocess as the user | write tools, `omarchy_cli` hatch |
| `ctx.omarchy.windows` | list / focus / move / close / launch | Hyprland via existing `omarchy-hyprland-*` | window tools |
| `ctx.omarchy.notify` | toasts and approval cards | `omarchy-notification-send` + shell IPC | `ctx.approval` responder, `ctx.userQuestions` |
| `ctx.omarchy.privilege` | decide `sudo` vs `pkexec` vs deny | TTY detection + the Omarchy skill's rule | dispatch, pkg, update, snapshot |
| `ctx.omarchy.snapshot` | create / list / restore system snapshots | existing snapshot commands | update tools, rollback |

What is *not* a new seam in v1: pacman, NetworkManager, PipeWire, GTK. Those stay behind `omarchy pkg`, `omarchy wifi`, `omarchy audio`, and friends. The dispatch seam is the choke point.

Prompt assembly: a `system-prompt` plugin injects an "Omarchy session" section derived from `ctx.omarchy.session` (theme, monitors, default apps, pending migrations). That section is a session event when it is model-visible, so replay stays honest.

### 4. Tool catalog

Discovery source: `omarchy commands --json` (binary, route, summary, args, aliases, `requires-sudo`). That listing is how the dispatch seam knows a route exists. It is not 1:1 with tools.

Curated model-facing tools, grouped by policy class:

**Observe** (auto-allow, read-only):

- `omarchy_status` — theme, edition, version/channel, outputs, power, pending migrations
- `omarchy_commands` — filtered command search (group, name, summary); never dumps hidden plumbing by default
- `omarchy_windows` — clients, workspaces, focused window
- `omarchy_theme_list` / `omarchy_font_list` / `omarchy_plugin_list`

**Act, session-local** (permission preset `session`; reversible or low blast radius):

- `omarchy_theme_set`, `omarchy_font_set`, `omarchy_background_set`
- `omarchy_launch`, `omarchy_capture`, `omarchy_notify`
- `omarchy_toggle` (nightlight, screensaver, and other documented toggles)
- `omarchy_bar_*` / `omarchy_plugin_enable` via the existing bar/plugin CLIs
- `omarchy_refresh` (already backups before copy)

**Act, system** (permission preset `system`; `ctx.approval` must allow; snapshot first when the command is an update):

- `omarchy_pkg_add` / `omarchy_pkg_drop`
- `omarchy_update` (the real pipeline: snapshot, packages, migrate, hook)
- `omarchy_snapshot_create` / `omarchy_snapshot_restore`
- `omarchy_system_{lock,logout,reboot,shutdown}` — shutdown/reboot always ask

**Escape hatch** (strict):

- `omarchy_cli` — argv must resolve to a known `omarchy` route, must not be hidden unless the user overlay allows it, and inherits the route's `requires-sudo` bit. Interactive TUIs and setup wizards are rejected with a message that names the desktop surface to use instead.

**Not exposed as OS tools:**

- raw `bash` against `/`, `/etc`, `/usr`
- `omarchy-dev-*` on a production install
- anything that writes `/usr/share/omarchy/`
- `omarchy-reinstall-configs` without an explicit high-severity approval (it clobbers `$HOME` from `/etc/skel`)

Coding-in-a-repo stays on Harness's existing `fs`, `shell`, and `sandbox` seams, with cwd in a project under `~/Work`. The OS agent and the coding agent are different presets (`ctx.agentPresets`): one scoped to `dsh-omarchy` tools, one to the stock coding toolset. A turn may spawn the other as a subagent rather than mixing both catalogs in one prompt.

### 5. Skills

Keep the shipped skill at `default/agents/skills/omarchy`. Do not rewrite it into TypeScript.

A Harness `ctx.skills` filesystem provider points at `$OMARCHY_PATH/default/agents/skills/` plus `~/.config/omarchy/skills/`. The existing finalize step that symlinks into `~/.{agents,claude,codex,pi/agent}/skills/` remains, so other CLIs keep working.

The skill's privilege paragraph becomes executable policy in `ctx.omarchy.privilege`, not just prose the model may ignore:

- visible terminal → `sudo`
- no TTY (overlay, notification action, user unit) → `pkexec`
- never wrap a command that already elevates
- never edit `/usr/share/omarchy/`

`diagnose-crash` stays a skill. `omarchy-agent-crash` can later hand the crash to the Harness OS preset instead of the default coding CLI; v1 may keep the current launcher and only add a Harness path behind a flag.

### 6. Approval, sandbox, and privilege

Harness already splits these, and we keep them split:

- **Sandbox** (`ctx.sandbox` + `ctx.sandboxPolicy`) confines *spawned project processes* (bash, code runtime). It does not wrap `omarchy theme set`. File-effect policy on a workspace is the wrong primitive for a compositor.
- **Approval** (`ctx.approval`) is the one-shot human decision for a tool call. Absent or unanswerable → deny. The Omarchy provider renders this as a Quickshell card (and a notification that punches DND via `omarchy-action`), not as a browser modal.
- **Privilege** is Omarchy-specific: after approval, dispatch still has to pick `sudo` or `pkexec` or refuse.

Permission presets map onto Harness's `ctx.permissionPresets`:

| Preset | What the OS agent may do without asking |
|---|---|
| `observe` | read-only tools only |
| `session` | observe + session-local acts; system acts ask |
| `system` | also pkg/update/snapshot after one-shot approval |
| `off` | deny every OS write (debug / kiosk) |

Default for a fresh user is `session`. The auto-approve flags that `omarchy-agent` passes to coding CLIs do **not** apply to the OS agent. Unattended desktop mutation is how configs get destroyed.

Destructive system tools take a Snapper snapshot first when one is not already fresh, and log `omarchy/snapshot` as a session event so rollback is a fact in the same log as the mutation.

### 7. Session log as OS history

Harness's rule stays: **model-visible means logged**. OS facts that reached the model, and OS mutations the model caused, are `SessionEvent`s.

Extend the event map (names indicative):

- `omarchy/status` — injected session snapshot at turn start when the observe section changed
- `omarchy/dispatch` — route, argv, exit, privilege path
- `omarchy/theme`, `omarchy/plugin`, `omarchy/window` — specific mutations worth rendering as cards
- `omarchy/approval` — correlated with `ctx.approval`, so a refused reboot is replayable

Fork, resume, transcripts, and telemetry then cover "what did the agent do to my machine?" without a second audit format. The overlay and `omarchy harness transcript` render from this stream.

Do not log secrets. Credentials stay on `ctx.credentials`. Notification bodies that might contain them are redacted in the durable event.

### 8. Desktop surfaces

Three clients, one host:

1. **Shell overlay** `omarchy.harness` — a Quickshell plugin (`kinds: ["overlay", "service"]`). Summon with a keybind and a menu entry. Streaming tokens, tool cards, and approval buttons. Talks ACP to the user unit. Themed via the existing shell theme path, not a parallel CSS file.
2. **CLI** — `omarchy harness status|run|prompt|attach|dump-config|preset`. Headless turns for scripts, crash diagnosis, and `omarchy-agent-prompt`-shaped one-shots that should hit the OS preset instead of a coding CLI.
3. **Optional web** — `dsh web` on loopback, off by default, for debugging composition and for a machine you are not sitting in front of (pairs later with the Server plan).

The existing `omarchy.agents` panel stays a **usage** display for coding subscriptions. It does not become the Harness UI. A small status glyph on the bar (separate plugin, self-hiding when the unit is off) can show "turn in progress" / "approval needed."

Menu: one submenu under Setup for Harness (enable unit, permission preset, open overlay, dump-config in a terminal). Do not add aliases. Do not replace Setup > Defaults > Agent; that picker remains the coding CLI.

Keybind: a new binding that summons the overlay. Do not steal `Super + Shift + Ctrl + A` from the coding-agent launcher.

### 9. Packaging and runtime

Node is a new runtime invariant for this feature, not for the rest of Omarchy.

- Ship a pinned Node (mise or a distro package — open question) sufficient for upstream's `^22.19.0 \|\| >=24`.
- Ship the `dsh-omarchy` overlay as files under `$OMARCHY_PATH/harness/` and a small installer that `pnpm install --prod` (or a prebundled `node_modules` in the package) into the user's Harness home on first enable.
- Do not add TypeScript to `bin/`, `install/`, or `migrations/`. Those stay bash. The overlay is a bounded tree with its own tests.
- Commands: `omarchy-harness-*` with group `harness` added to `GROUP_DESCRIPTIONS`. Hidden plumbing (`omarchy-harness-host`) is fine; user-facing verbs are `status`, `run`, `prompt`, `enable`, `disable`, `preset`.

`omarchy-provision-first-run` enables the user unit only after Node and the overlay are present; the unit's `Condition*` keeps it inert otherwise. A migration enables it for existing users who opt in, not for everyone on upgrade — Harness is preview, and a surprise control plane on `omarchy update` is unacceptable.

### 10. Relationship to other plans

- **dots** (`plans/dots.md`): Harness mutations of `~/.config` are exactly the events dots should snapshot. A later hook can commit after an `omarchy/dispatch` that touched config. v1 does not implement dots.
- **backup** (`plans/backup.md`): system tools that restore or reinstall must consider backup state; they do not replace it.
- **server** (`plans/server.md`): a future `omarchy` profile without the Quickshell overlay, using the BBS menu as an ACP client, is the headless story. Not v1.

## Rollout

### Phase 0 — this document

Lock the inversion, the seam list, the tool policy classes, and the non-goals. No code until the design is accepted.

### Phase 1 — host and CLI, no desktop UI

- `harness/` overlay package: profile, bundle patch, `ctx.omarchy.dispatch` + `ctx.omarchy.session` (read-only), observe tools only.
- Pin `dsh`, `omarchy-harness.service`, `omarchy harness status|dump-config|prompt`.
- Tests: CLI metadata; unit tests that dispatch allowlists and reject hidden/interactive routes; a fake `omarchy` on `PATH` so tests do not need Hyprland.
- Manual: one page, opt-in, "this is a preview."

### Phase 2 — session-local writes and approval

- Theme / launch / capture / toggle / notify tools.
- `ctx.approval` → notification card + overlay buttons.
- Permission presets. Default `session`.
- Shell overlay v1: transcript, tool cards, approve/deny.
- Visual verification of overlay, approval card, and theme-set roundtrip per `agents/skills/visual-verification.md`.

### Phase 3 — system writes

- pkg, update, snapshot, power. Snapshot-before-update. `pkexec` path with no TTY.
- Crash-diagnosis path that can target the OS preset.
- Subagent: OS preset may spawn the user's default coding CLI (or a Harness coding preset) into `~/Work` without giving that child the system tool catalog.

### Phase 4 — harden and default-off → default-on

Only after the overlay has been the daily driver on real machines: enable the unit at first-run, keep the permission preset at `session`, keep coding CLIs unchanged. Promote from preview in the manual.

## Test plan

Automated tests stay in this repo's existing runners. Graphical checks follow the acceptance and visual-verification skills.

| Case | Layer | Expect |
|---|---|---|
| `omarchy commands --check` after adding `harness` group | CLI | metadata valid, no route collisions |
| observe tool lists theme without spawning a shell pipeline | overlay unit | fake dispatcher called with `theme list` or session provider |
| `omarchy_cli` on a hidden command | overlay unit | denied, no subprocess |
| `omarchy_cli` on `omarchy setup security fingerprint` | overlay unit | rejected as interactive |
| session tool `omarchy_theme_set` under preset `observe` | overlay unit | `tools/pre-execute` deny, no dispatcher call |
| system tool without approval responder | overlay unit | fail closed |
| privilege: TTY present | overlay unit | `sudo` path selected |
| privilege: no TTY | overlay unit | `pkexec` path selected |
| model-visible status injected | overlay unit | corresponding `omarchy/status` (or equivalent) in the log; replay reconstructs it |
| user unit inactive | CLI | `omarchy harness status` nonzero; desktop otherwise healthy |
| overlay summons when host down | shell test | error state, no hang |
| approval card punches DND | shell test | `app_name` is `omarchy-action` |
| visual: overlay + theme change + approval | running UI / acceptance VM | see visual-verification skill |

Do not run graphical acceptance in `./test/all`. Host tests must not require a live compositor; provider fakes are the seam's purpose.

## Open questions

1. **Node shipping**: mise-managed pinned Node vs an Arch package vs a vendored runtime. Production Omarchy currently treats mise as the way optional CLIs arrive; a session `WantedBy=graphical-session.target` wants the runtime on disk before first login.
2. **Prebundle vs install-on-enable**: a full `node_modules` in the Arch package is large and brittle; a first-enable fetch needs network and makes offline ISO installs sad. Likely: vendor a prod bundle in the package, hash-pin it.
3. **ACP vs a private Unix protocol** for the overlay: ACP is the open client protocol and keeps the door open for Zed/editor attachments. If ACP cannot carry Omarchy approval cards cleanly, we speak ACP for turns and a small side-channel for `ctx.approval` / `ctx.userQuestions`.
4. **Upstream pin cadence**: follow a named `dsh` version; who runs the canary, and does `omarchy update` ever bump it automatically?
5. **Multi-user**: each graphical user has their own user unit and `$DSH_HOME`. Root never runs the host. Is a system-wide Harness (for the Server plan's sysop) a different profile, or out of scope forever?
6. **Local models**: Ollama / LM Studio already exist in the menu. Should `ctx.llm` default to a local OpenAI-compatible endpoint when one is up, or stay cloud-first with DeepSeek's adapter?
7. **Edition predicate**: `omarchy-edition-harness` as a third edition is tempting and wrong for v1. Keep it a feature on desktop until the Server plan needs a headless profile.

## Non-goals (v1)

- Replacing Hyprland or Quickshell
- Making Harness a boot dependency
- Auto-approving OS mutations
- Teaching the model to edit `/usr/share/omarchy/`
- Unifying Cordis plugins with Quickshell `manifest.json` plugins
- Shipping a custom LLM
- Changing how coding-agent CLIs launch
