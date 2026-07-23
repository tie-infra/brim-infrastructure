# Repository instructions

This repository defines production NixOS infrastructure. Prefer declarative,
reproducible, and reviewable changes over imperative fixes. Make changes at the
right abstraction boundary. Refactor, remove obsolete code, and update related
documentation and validation as needed to leave the repository clean, coherent,
and healthy. Prefer a complete, maintainable solution over a small diff.

## Commands

Run commands from the repository root.

Format changed Nix files:

```sh
nix fmt ./path/to/file.nix
```

Run the primary repository check:

```sh
nix flake check --all-systems
```

Evaluate a host without activating it:

```sh
nix eval --raw \
  .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
```

Build a host when the available builder supports its target system:

```sh
nix build --no-link \
  .#nixosConfigurations.<host>.config.system.build.toplevel
```

Build an added or overlaid package through a host's configured package set:

```sh
nix build --no-link \
  .#nixosConfigurations.<host>.pkgs.<package>
```

Build through a remote Nix store over SSH and print the remote output path:

```sh
nix build \
  --eval-store auto \
  --store ssh-ng://<user>@<build-host> \
  --no-link \
  --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.toplevel
```

Copy a printed output and its closure from the remote store into the local
store:

```sh
nix copy \
  --no-check-sigs \
  --from ssh-ng://<user>@<build-host> \
  /nix/store/<output-path>
```

Check all changed text for whitespace errors:

```sh
git diff --check
```

Replace the placeholders as appropriate. Remote builds remain in the remote
store; use the printed path with the copy command above to fetch the closure
locally. Building does not authorize activation, boot, or deployment.

### Flakes and untracked files

The commands above resolve the repository as a Git-backed flake. Nix includes
uncommitted changes to files known to Git, but omits untracked files. A new
module, package, patch, or data file can therefore produce a misleading
path-not-found error. Add intended source files to the index before normal
flake evaluation; a commit is not required:

```sh
git add ./path/to/new-file
```

Do not use an explicit path flake to work around an untracked file. It can copy
the whole worktree into the Nix store, including untracked and ignored content
and Git metadata.

## Repository shape

- `flake.nix` declares pinned inputs and composes flake-parts modules.
- `nixpkgs.nix` creates the shared package set and applies overlays.
- `nixos-system.nix` defines modules shared by every host.
- `configurations.nix` assembles each host from small host modules.
- `hosts/<name>/` contains host-specific hardware, networking, and service
  integration.
- `modules/` contains reusable NixOS modules with typed option interfaces.
- `packages/` contains automatically discovered package definitions. Use
  `<name>.nix` for a standalone definition or `<name>/package.nix` when patches,
  sources, or other support files should be colocated.
- `overlays/` contains hand-written overlay functions, typically transformations
  based on an existing Nixpkgs package; keep substantial package definitions in
  `packages/`.
- `secrets/*.sops.yaml` contains encrypted SOPS data. `zapret/` contains data
  consumed by its package and module configuration.

Use `modules/garage.nix` as a representative option-based service module,
`modules/garage-webui.nix` as a systemd hardening example,
and `packages/pufferpanel/package.nix` as a package definition example.

For host-level composition and SOPS integration, follow the closest analogous
module under `hosts/<name>/`.

These are structural references; isolated exceptions in existing code are not
precedents for bypassing the rules below.

The package set is instantiated once and injected into NixOS through
`readOnlyPkgs`. Do not import another Nixpkgs instance or set host-local
`nixpkgs.config` or `nixpkgs.overlays`. Follow the versions and option schemas
from the locked Nixpkgs input, not from a different release. Package definitions
and full replacements under `packages/` are exposed automatically. Add an
explicit entry in `nixpkgs.nix` only for an overlay that transforms an existing
package, such as an `overrideAttrs` based on `prev`.

## Nix conventions

- Treat `nixfmt` and `deadnix`, invoked through `nix fmt`, as authoritative.
  Pass changed paths when possible, then inspect the diff for unrelated edits.
- Preserve flake purity. Declare and pin dependencies as flake inputs or fixed
  output sources; do not use `<nixpkgs>`, ambient channels, or unpinned fetches.
- Prefer simple attribute sets and `let` bindings. Avoid broad `with` scopes and
  avoid `rec` unless recursive attributes are genuinely required.
- Quote URLs. Use `lib` helpers instead of reimplementing common operations.
- Treat derivation outputs and store paths as unknown, untrusted values. Do not
  interpolate them into Bash, systemd directives, JSON, TOML, YAML, or other
  foreign structured syntax.
- Pass paths through structured boundaries: dependency and runtime input lists,
  Nix module or package options, generated settings files produced with
  `pkgs.formats`, or environment variables defined through structured Nix
  attributes. In shell code, invoke declared tools by name and quote every
  variable expansion. Use format-specific escaping only when no structured
  boundary exists.
- In indented Nix strings, use `${...}` for intentional Nix interpolation and
  `''${...}` for shell expansion.
- Keep shell code to short, linear glue around existing tools. For substantial
  parsing, data structures, control flow, concurrency, error handling, or
  testing, write a small helper in a suitable general-purpose language such as
  Python, Go, Rust, Zig, or C#. Choose the language for the problem and its
  ecosystem, and package the helper and its dependencies with Nix.
- Comments should explain intent, constraints, or surprising upstream behavior.
  Keep useful source links and explain any `mkForce`, disabled test, patch, or
  security relaxation next to the exception.
- Prefer the smallest abstraction that makes ownership and reuse clearer. A
  one-host value normally belongs in that host's module, not in a new global
  option.

## NixOS modules and host configuration

- Put reusable behavior behind a typed option interface. Use conventional
  namespaces, `lib.mkEnableOption`, `lib.mkPackageOption`, a local `cfg` binding,
  and `lib.mkIf cfg.enable` where applicable.
- Give public options a precise type and description. Add safe defaults and
  useful examples when they clarify behavior. Use `pkgs.formats` and a typed
  `settings` option for Nix-representable application configuration.
- Use `lib.mkDefault` in shared policy when hosts should remain able to override
  it. Use `lib.mkForce` only for a documented conflict that cannot be expressed
  by normal module merging.
- Keep imports static. Register reusable modules in `nixos-system.nix` and host
  slices in `configurations.nix`.
- Replace an upstream NixOS module when extending it would produce a worse
  interface or implementation. Disable the upstream module in `disabledModules`,
  register the replacement with the shared modules, preserve useful option
  compatibility, and document why the replacement is necessary.
- Never change `system.stateVersion` as part of a routine NixOS upgrade. Change
  it only for a deliberate migration after reviewing the release notes.
- Prefer module options over ad-hoc generated files and imperative setup. When a
  file is required, generate it from typed settings and connect service restarts
  with `restartTriggers` or the relevant SOPS `restartUnits`.
- For systemd executables, set `serviceConfig.ExecSearchPath` with
  `lib.makeBinPath` and use executable names in `ExecStart` and related
  directives. Do not interpolate package output paths into unit directives.
- Preserve least privilege in systemd services. Prefer `DynamicUser` or a
  dedicated system user, managed state/runtime directories, an explicit
  capability allowlist, and the hardening options already used here.
- Bind backend services to loopback when they are exposed through Caddy. Open
  firewall ports only when external access is intentional and documented.

## Packages and overlays

- Use Nixpkgs extension points freely when they are the right abstraction:
  package arguments with `override`, derivations with `overrideAttrs`, and
  project-wide package additions or replacements with overlays.
- Prefer the most specific override API exposed by a package or language
  framework, such as `overridePythonAttrs` for Python packages or
  `overrideModAttrs` for a Go module dependency derivation. Use generic
  `overrideAttrs` only when no narrower hook models the change.
- Patch broken third-party package behavior or add missing features at the
  package layer instead of compensating in NixOS modules or host configuration.
  Keep patches beside the package definition or override, explain the upstream
  problem or gap, cover the resulting behavior with a build or test, and remove
  the patch once the pinned upstream version contains the change.
- Define packages as functions compatible with `callPackage` and place them
  under `packages/`; `lib.packagesFromDirectoryRecursive` exposes them without
  an explicit overlay entry. In explicit overlays, use `final` for dependencies
  and newly composed packages, and `prev` for the package being overridden.
- To expose existing executables under other names, prefer `runCommand` with
  `makeBinaryWrapper`. Pass executable packages through derivation attributes
  rather than interpolating their output paths into the build script.
- Use the most specific Nixpkgs builder available. Keep build-time tools in
  `nativeBuildInputs`, runtime/library dependencies in the appropriate input,
  and enable `strictDeps` when the builder does not already do so. Set
  `__structuredAttrs = true` by default; document builders that require opting
  out.
- Pin source, vendor, and language dependency hashes. A version update should
  update its source hash, vendor hash, generated dependency files, patches, and
  tests together as applicable.
- Keep builds offline and deterministic. Do not fetch dependencies during build
  phases.
- Provide useful `passthru.tests` where practical and complete `meta`, including
  a factual description, homepage, license, maintainers, and `mainProgram` for a
  primary executable.

## Secrets and operational safety

- Never add plaintext credentials, private keys, tokens, or passwords to Nix
  expressions, Git, command output, or the Nix store.
- Do not decrypt or rewrite `secrets/*.sops.yaml` unless the task explicitly
  requires a secret change. Use SOPS for such edits and preserve `.sops.yaml`
  recipient rules.
- Pass secrets to services through `sops.secrets`, SOPS templates, or credential
  files. Do not interpolate secret contents into store-backed generated files.
- Treat changes to networking, firewall rules, SSH access, users, disks,
  persistence, boot, and CI deployment as high impact. Review them as complete
  operational changes and call out their effect in the handoff.

## Validation and Git

- Inspect `git status` before editing and preserve unrelated worktree changes.
  Do not revert, reformat, or delete work that is outside the task.
- For documentation or data-only changes, run `git diff --check`.
- For Nix changes, format the changed paths and run
  `nix flake check --all-systems`.
- For module, host, package, overlay, or lock-file changes, also evaluate the
  affected NixOS toplevel. Build it when a suitable builder is available.
- Report checks that were not run or could not run, with the reason. Do not hide
  a failing check by weakening or deleting it.
- Keep `flake.lock` changes intentional and scoped to dependency work. Do not
  commit `result` links, decrypted files, or editor artifacts.
- Do not create commits unless asked. When asked, turn the staged changes into
  a clean history of small, well-scoped commits rather than one broad change
  set. Each commit should represent one coherent change and include the tests,
  documentation, and migrations needed to keep that change internally
  consistent. Follow the existing concise Conventional Commit style, such as
  `feat(<scope>): ...`, `fix: ...`, or `chore(<scope>): ...`.
