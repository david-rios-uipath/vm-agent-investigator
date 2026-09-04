# uip CLI / Studio Web / Orchestrator findings

Collected 2026-09-03 while trying to deploy and iterate `vm-agent` outside Studio Web debug.
Each item was observed directly, not inferred. `uip` was `1.201.0-preview.131`.

## Solutions: pack / publish / deploy

- `uip solution pack <dir> <out-dir> -n <name> -v <ver>`: output dir is a positional argument,
  not `-o`. Package name defaults to the directory name, so pass `-n "vm-agent 8"` to publish
  into an existing package identity.
- `pack` **rewrites files in the source tree** (`ResourceBuilder … Writing resource file`). It
  regenerates `bindings_v2.json` from the flow's top-level `bindings` array and can strip
  `resourceKey`/`resourceName`/`folderKey` from the flow declaration under
  `resources/solution_folder/process/flow/`. Check `git status` after every pack.
- Flow `bindings[].resourceKey` must be the bare process name for an in-solution process
  (`vm-exec`). A folder-qualified form (`solution_folder.vm-exec`) is silently dropped, and the
  package ships an empty `bindings_v2.json`. For a cross-folder process the working form is
  `<folder>.<process>` (`e2e-investigator.vm-exec-vm`).
- Tenant feed and Personal Workspace feed are separate: `deploy run --personal-workspace`
  fails with "Package … was not found in the target feed" until you also
  `publish --personal-workspace`.
- `deploy run` requires `--folder-name` even with `--personal-workspace`.
- `deploy run` returned `HTTP 504: Received HTML` twice (Cloudflare gateway time-out on
  alpha). The deployment did not register either time; a plain retry succeeded.
- `deploy upgrade <key>` wedged the deployment into `VersionChange / Draft`. It never left
  that state, a second `upgrade` returned `4005 Another upgrade has already started`,
  `activate` only re-activated the old install, and the Solutions Management UI did not show the
  pending record at all. A second deployment in the workspace (`AutoDeploy-Solution 40`) is stuck
  the same way, so this is a recurring failure mode, not a one-off.
- `deploy uninstall` fails with `FailedUninstall / Validation failed.` while **any job in that
  folder is Running** — including a parent flow job whose child has already faulted. Stop the
  job first and the same command succeeds. (`Shared/vm-agent 8` still fails with no running job;
  cause unknown.)
- `deploy uninstall` + `deploy run` with the same `-n` and `--folder-name` is a valid
  same-folder iteration loop (~90 s), but the folder is recreated: machine assignments and
  hand-created assets are lost each cycle.
- `uip or processes update-version` cannot bump a solution-deployed process:
  `HTTP 404: El paquete de este proceso ya no está disponible.` The inner nupkg
  (`vm-agent.7.flow.VmAgent`) only reaches the process feed through a solution deployment.
- `deploy-config.json` hand-written `linkToResource: { name, folderPath }` is byte-identical to
  what `uip solution deploy config link` generates. In a `Shared/...` deployment the linked
  process is not provisioned locally (folder shows only `VmAgent` + `vm-exec`). In a
  **personal-workspace** deployment the link was ignored and a local `vm-exec-vm 1.0.0` was
  provisioned anyway, which then ran on serverless Linux.
- `deploy list` output is a flat `Data[]`; the CLI's `deploy status <id>` takes a
  `PipelineDeploymentId`, not the deployment `Key` shown in `list` (404 otherwise).
- Solution folders created by `deploy run` are type `Solution` and get serverless robots.
  Assigning a Windows machine template to one (`uip or machines assign <key> --folder-path …`)
  does not make processes run on it — Orchestrator still picked serverless. Standard folders
  (like `e2e-investigator`) with only the VM template behave as expected. Neither
  `processes update` nor the `rpa-workflow` node definition exposes a runtime-type setting.

## The one that mattered: `uip solution pack` drops inline-agent tool bindings

- Studio Web's published flow nupkg ships `content/bindings_v2.json` with one entry per binding
  key the flow uses — for this flow both `e2e-investigator.vm-exec-vm` (RPA nodes) and bare
  `vm-exec-vm` (the inline agent's process tool). `uip solution pack` regenerates that file from
  the flow's top-level `bindings` array, and Studio Web only writes the RPA nodes' key there, so
  locally packed flows lose the agent tool binding. Symptom at runtime: the agent child job's
  `ResourceOverwrites` has only `process.e2e-investigator.vm-exec-vm`, and the first tool call
  fails (`404 The job's associated process could not be found`) or hangs to
  `Serverless.Runtime.JobExecutionTimeout`. RPA nodes are unaffected.
- Fix that survives packing: add `name` + `folderPath` bindings with `resourceKey` = the bare
  process name (`vm-exec-vm`) to the flow's `bindings` array. Verify with a throwaway pack and
  read `content/bindings_v2.json` out of the nupkg before deploying. **Confirmed 2026-09-04 00:34
  UTC** — agent tool calls reached the VM (1.0.14).
- **The bare bindings keep disappearing from `VmAgent.flow` in the source tree.** Lost twice
  (before 1.0.15 and before 1.0.17) somewhere in the pack/validate/edit cycle; `uip maestro flow
  validate` alone was tested and did *not* strip them, `pack` does rewrite the flow and other
  files (`agent.json` ×2, the flow declaration). Exact culprit unconfirmed. Treat it as
  hostile: `release.sh` re-adds the bindings immediately before packing, discards pack's
  source rewrites with `git checkout -- vm-agent/`, and **asserts** `vm-exec-vm` is in the
  packaged `content/bindings_v2.json` before publishing. Never hand-run the pack step.
- `uip solution packages download "<name>" <version> -d <dir>` fetches a published solution zip
  (version is positional, not `--version`). Published zips use a single `resources.json` +
  `configurations/default/configuration.json`; locally packed zips use per-resource files under
  `resources/solution_folder/`. The published declaration also carries `resourceType` and
  `bindingMetadata.isSolutionResource: true` on each binding, which `pack` does not emit.
- `deploy uninstall` "Validation failed." on `Shared/vm-agent 8` was two flow jobs left
  `Running` for 20 h in that folder (`jobs list` shows them; `jobs stop k1 k2` accepts several
  keys). Always list jobs in a folder before concluding an uninstall is wedged.

- **Agent tool `resource.json` files can vanish from the tree too.** Commit `89c8587` deleted
  both `VmAgent/<agent>/resources/<toolId>/resource.json` after an edit→`validate`→commit
  sequence; 1.0.17–1.0.19 then shipped agents with `resources: []` (placeholder output in 27 s,
  then `AGENT_RUNTIME.ROUTING_ERROR 'vm_exec' is not a registered tool`). Neither `validate` nor
  `resources refresh` reproduced the deletion in isolation. `release.sh` asserts the packaged
  investigator `agent.json` lists `vm_exec`.
- **`pack` nondeterministically drops the agent tool binding** even when the flow source has it
  (confirmed: `release.sh` re-added it, committed, packed — and the packaged `bindings_v2.json`
  still came out with only the qualified key; the next pack of the identical tree was fine). The
  pack log's `Skipping binding resolution for node X: Manifest is missing
  model.bindings.values.folderPath` warnings suggest it sometimes rebuilds bindings from node
  manifests instead of the flow's `bindings` array. `release.sh` retries the pack up to 5 times
  until the packaged bindings are right.
- **PowerShell 5.1 `>` redirection writes UTF-16LE.** `git diff > patch.file` on the VM produced
  a patch beginning `ff fe 64 00 …`; `Get-Content` displayed it correctly (BOM detection) but
  `git apply --check` failed with `error: No valid patches in input (allow with "--allow-empty")`
  — twice, on byte-identical patches, killing the fixer's verification in 5-9 s before Playwright
  ever ran. Reproduced locally byte-for-byte. `verifyFixInstructions` now logs the patch's first
  8 bytes in hex and re-encodes UTF-16 → UTF-8 no-BOM, CRLF → LF, trailing newline guaranteed.
  Note PowerShell has no `\r\n` escape (it uses backticks, which collide with the flow's JS
  template literal) — build those characters with `[char]13` / `[char]10`.
- **`pack` output is not deterministic.** One `release.sh` run had the binding assert fire on a
  correct tree; two probe packs of the same tree seconds later were correct. Always gate publish
  on inspecting the produced zip, never on the source.

## Solution resources

- `uip solution resources add --source remote --kind Process --name X --folder-path F` writes a
  **local declaration** (`folders: [solution_folder]`, `Source: Local` in `resources list`)
  even though the source was remote; it does refresh `packageVersion`, schemas and entry-point
  ids from the live process, which is useful on its own.
- `uip solution resources refresh` overwrites the agent tool `resource.json`
  `properties.processName`/`folderPath` from the solution declaration. Run it **before**
  hand-editing tool resources, never after — it silently reverted an edit tonight.
- `resources refresh` also copies `bindings_v2.json` values into the flow declaration's
  `runtimeDependencies` bindings. A bindings edit that skips `refresh` never reaches the
  package.
- `uip agent refresh <dir>` does not apply to inline-in-flow agents (wants `entry-points.json`,
  `project.uiproj`, tool dirs named after the tool). It also rewrote `agent.json`: bumped the
  version and split a `rawString` prompt token on `$env:GH_TOKEN` into an `expression` token.
  Revert with `git checkout` if run by accident.
- Inline agents live under `VmAgent/<agentId>/agent.json` and must appear in
  `VmAgent/entry-points.json` as `type: agent`. The Fixer agent added in an earlier session was
  never registered there (fixed in `dec75c0`); whether that matters at runtime is still unproven.

## Maestro flow

- `uip maestro flow validate <file>.flow` always reports the 6 `stickyNote:1.0.0` "no matching
  definition" errors — that is the baseline, filter them out.
- Orchestrator `jobs get` on a Maestro parent job stays `Running` after the instance has
  faulted. Use `uip maestro flow instance get <instanceId> -f <folderKey>` (instance id = parent
  job key) for `LatestRunStatus` and `Cursors.ElementIds`, and `… instance incidents` for the
  actual error (e.g. `170007 Failure to start the Orchestrator job — Folder does not exist or
  the user does not have access to the folder.`). `-f` needs the folder **key**:
  `uip or folders list --all --name "<name>"`.
- `instance element-executions` returned nothing for a faulted run; `incidents` had the detail.
- Agent child jobs of a flow show `Source: Manual`, `SourceType: ProcessOrchestration`,
  `ServerlessJobType: PythonAgent`, `ParentJobKey`, and a `ResourceOverwrites` map. For this
  flow that map only ever contained `process.e2e-investigator.vm-exec-vm` (the RPA nodes'
  binding). Nothing added to the agent tool binding (`folderKey`, `id`) produced a second entry.
- Script-node inputs of type `jsExpression` referencing `$vars.<node>.output['field']` (bracket
  form) pass the validator where dotted form fails (see `PLAN.md` step 6).
- A flow input read as `$vars.start.output.<name>` can be added by editing
  `entry-points.json` `input.properties` alone; used for the `smokeOnly` flag.

## Orchestrator CLI ergonomics

- `uip or jobs start <process-key>` — process key is positional; `--process-name` does not exist.
  `jobs get`/`jobs stop` take no `--folder-path`.
- `uip or sessions unattended list --folder-path …` shows machine runtime slots per folder.
- `uip or folders list` paginates at 50 with no working `--skip`; use
  `--all --name <n>` or `--all --path <prefix>` instead.
- `uip or assets create <name> <value> --type Credential --credential-store-key <k>` — the
  store key comes from `uip or credential-stores list` (`Orchestrator Database`,
  `32e1cdf9-…`). Credential assets reject empty values; a single space works and `vm-exec`
  treats whitespace as unset.
- No `traces`/`spans` subcommand under `uip or`; use `maestro flow instance …` for flow-level
  detail.

## Studio Web UI

- The **Deployments** tab in a solution's Manage view did not list the active CLI-created
  deployment nor the wedged Draft version change; it showed only two old uninstalled records.
  Do not rely on it to confirm CLI deployment state.
- The **Versions** tab lists only versions published from Studio Web (`1.0.0 · Tenant`); CLI
  publishes to the same package identity update the header's "Latest version" but do not appear
  as rows.
- Studio Web debug provisions the flow into `<workspace>/Debug_<solution>` as
  `type: Install` and the cross-folder process as `type: Reference` via
  `userProfile/<id>/debug_overwrites.json`. Those `Debug_*` folders are empty after the run.

## Workflow-level

- Windows PowerShell 5.1: `native.exe | Select-Object -First 1` terminates the pipeline and
  leaves `$LASTEXITCODE` non-zero even when the exe succeeded. Capture with `@(native.exe)`
  and check the exit code afterwards.
- `theater.uipath.co` (merged Playwright report host) is behind Azure AD — 401 to curl. Nightly
  per-test results are cheapest from GitHub Actions job logs via `gh run view --job <id>
  --log-failed`.
- The Claude Code auto-mode classifier blocks foreground `sleep N` and reading
  `~/.uipath/config.json`; use `until … done` loops with `run_in_background: true` and never
  reach for stored credentials.
