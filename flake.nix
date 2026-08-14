{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "sub2_chaos -- chat-voted chaos in Subnautica 2: a Go vote sidecar plus a UE4SS Lua mod. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the others, and a hardcoded
  # system list this repo cannot edit. That list is currently broken: it still
  # contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # This repo is two halves that talk through a JSON file (see docs/ADR/0001
      # and 0002), so the shell is deliberately polyglot:
      #
      #   vote-engine/  Go module, `go 1.25` in go.mod, CI pins go-version 1.25
      #   mod/, tests/  UE4SS Lua, CI pins luaVersion 5.4 (leafo/gh-actions-lua)
      #
      # `nix flake check` realises this closure, so a typo'd attr name fails at
      # the flake gate instead of surfacing as "command not found" halfway
      # through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      toolchain = pkgs: [
        # ---- the Go sidecar (vote-engine/) ----
        # Bare `pkgs.go` is the documented exception to the pin-by-major rule:
        # there is no major-pinned Go alias in nixpkgs (`go_1_24` does not
        # exist), so GOTOOLCHAIN=local below is what keeps the version honest.
        # This also supplies `gofmt`, which `dev-fmt` uses.
        pkgs.go
        pkgs.gopls

        # ---- the UE4SS Lua mod (mod/, tests/, tools/) ----
        # lua5_4 matches CI exactly and ships both `lua` (for tests/run.lua) and
        # `luac` (for the parse check in `dev-lint`). Do NOT also add luajit:
        # both ship bin/lua, and mkShell resolves that collision silently by
        # letting one shadow the other -- only buildEnv reports it.
        #
        # No luarocks: nothing here has a rockspec, and the mod loads its
        # dependencies (mod/Scripts/json.lua) from the mod folder at runtime.
        pkgs.lua5_4

        # ---- present in every repo in the fleet ----
        # jq earns its place twice over here: the entire mod <-> sidecar contract
        # is JSON (events.json, chaos_state.json, chaos_status.json).
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty on purpose, and that is not an oversight. The Go module set is
      # pure Go (gopkg.in/yaml.v3, github.com/gorilla/websocket) and builds with
      # CGO_ENABLED=0; the Lua side is stock 5.4 with no C rocks. There is no
      # manylinux wheel and no node prebuild anywhere in the tree, so nothing
      # dlopens a library that the nix linker never saw. Leaving this empty also
      # leaves the caller's ambient LD_LIBRARY_PATH completely untouched.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value, UNSET something or touch the work tree goes in the
      # shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Without this, the `go 1.25` directive in vote-engine/go.mod can make Go
        # fetch another toolchain over the network mid-build. With it you get an
        # instant legible "go.mod requires go >= X (running go Y;
        # GOTOOLCHAIN=local)" instead. If go.mod ever outruns nixpkgs, bump
        # flake.lock -- do not unset this.
        GOTOOLCHAIN = "local";

        # Avoids "error obtaining VCS status" in worktrees and agent checkouts
        # owned by another uid. Unknown-to-command flags in GOFLAGS are ignored,
        # so vet/test/mod tidy still work. Never put -mod=vendor or -mod=mod
        # here: this module has no vendor/ directory.
        GOFLAGS = "-buildvcs=false";

        # Load-bearing, not cosmetic. Nothing in this module imports "C", but
        # with cgo enabled `go vet ./...` still tries to build runtime/cgo and
        # dies with `cgo: C compiler "gcc" not found` inside the `nix run`
        # wrappers, whose PATH is exactly `toolchain` and contains no compiler.
        # CI's `GOOS=windows go build` is cgo-free for the same reason, so this
        # matches what CI actually exercises rather than diverging from it.
        CGO_ENABLED = "0";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#test`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-test` actually runs.
      #
      # `setup` is absent, and that is the honest answer: there is nothing to
      # bootstrap. Go fills its module cache on the first build (that first
      # build does need network -- see the note on `build`), and the Lua half
      # has no dependency manager at all.
      #
      # Two repo-specific shapes to know before editing any of these:
      #
      #   * The Go module is rooted at vote-engine/, not at the repo root, so
      #     every go invocation uses `go -C` rather than a bare `./...`.
      #   * tests/run.lua sets `package.path = "mod/Scripts/?.lua;tests/..."`
      #     and dofile()s its test files by relative path, so it only works with
      #     the repo root as the working directory. Hence the `cd` subshell --
      #     a subshell, so the caller's cwd survives for the next line.
      commands = pkgs: {
        build = {
          # Same flags as .github/workflows/ci.yml. The output path is already
          # covered by .gitignore (/vote-engine/vote-engine), so a build never
          # dirties the tree.
          #
          # NEEDS NETWORK ON A COLD CHECKOUT: the first go build/test in a fresh
          # $HOME downloads gorilla/websocket and yaml.v3 into the module cache.
          # After that everything here is offline. Nix cannot pin that for us
          # without vendoring the module, which is a repo change, not a flake
          # change.
          description = "(network on first run) build the vote-engine binary";
          # "$@" sits before the package argument, not at the end: `go build`
          # stops parsing flags at the first non-flag argument, and it takes the
          # LAST -o, so `dev-build -o /tmp/ve` overrides the default.
          text = ''
            go -C "$REPO_ROOT/vote-engine" build -ldflags="-s -w" \
              -o "$REPO_ROOT/vote-engine/vote-engine" "$@" .
          '';
        };
        test = {
          # Both halves, in the order CI runs them -- Lua first because it is
          # instant and needs no network, so a broken mod script fails before
          # the Go module cache is even consulted.
          description = "(network on first run) run the Lua mod tests and the Go test suite";
          text = ''
            ( cd "$REPO_ROOT" && lua tests/run.lua )
            go -C "$REPO_ROOT/vote-engine" test ./... "$@"
          '';
        };
        lint = {
          description = "(network on first run) go vet the sidecar and parse-check every Lua file";
          # `luac -p` compiles without writing output: a real syntax gate over
          # the whole mod, including the scripts tests/run.lua never loads
          # (aggro, cheats, items, void_aggro, main). It is not a style linter
          # -- the repo ships no .luacheckrc, so luacheck would fail on UE4SS
          # globals and on the test runner's own describe/it globals, which is
          # why it is deliberately not wired in here.
          #
          # -co --exclude-standard so uncommitted new .lua files are covered too
          # while .gitignore'd ones are not.
          #
          # `go vet` rejects flags after the package list, so "$@" goes before
          # `./...` rather than at the very end of the line.
          text = ''
            ( cd "$REPO_ROOT" && git ls-files -zco --exclude-standard -- '*.lua' | xargs -0 luac -p )
            go -C "$REPO_ROOT/vote-engine" vet "$@" ./...
          '';
        };
        fmt = {
          # Go only, and that is deliberate. The Lua in this repo is
          # hand-formatted (tabs plus column-aligned trailing comments) and
          # there is no .stylua.toml, so a `stylua .` here would rewrite all 30
          # .lua files and bury the next real diff. Format Lua by hand, in the
          # style of the file you are editing.
          description = "gofmt the vote-engine sources (rewrites files; Lua is hand-formatted)";
          text = ''gofmt -w "$REPO_ROOT/vote-engine" "$@"'';
        };
        run = {
          # Built and then executed from the repo root on purpose: the sidecar
          # resolves --config (default config.yaml) and --catalog (default
          # ./events.json) relative to its working directory, and those defaults
          # only line up at the top level -- see the "Quick start" note in
          # README.md.
          #
          # Needs config.yaml, which is gitignored because it can hold tokens:
          #   cp config.example.yaml config.yaml
          # For a no-game, no-stream smoke test:
          #   dev-run --simulate --bridge-file /tmp/chaos_state.json
          description = "(network on first run) build and start the vote-engine sidecar from the repo root";
          text = ''
            go -C "$REPO_ROOT/vote-engine" build -o "$REPO_ROOT/vote-engine/vote-engine" .
            cd "$REPO_ROOT"
            exec ./vote-engine/vote-engine "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical across the fleet, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless. With nativeLibs empty (as
      # it is here) this expands to nothing at all.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare relative path
      # silently means something different from a subdirectory -- and in this
      # repo every verb has to reach either vote-engine/ or the top level.
      # Note we do NOT cd here: commands act on the caller's cwd on purpose.
      rootPreamble = ''
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any zip built in here -- `zip -r Sub2Chaos-mod.zip`,
            # the way release.yml packages the mod -- then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No `go mod download`, no
            # `go build`. Bootstrapping in the hook makes a cold
            # `nix develop -c dev-test` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it -- and in this repo
            # that is a real pipeline, e.g.
            # `nix develop -c cat events.json | jq -r '.events[].id'`. $- is the
            # only reliable discriminator: it lacks `i` for `nix develop -c` and
            # has it at an interactive prompt. Do not test $PS1 (unset in both)
            # or $IN_NIX_SHELL (set in both). >&2 is the second layer, for the
            # case where a caller runs us on a pty.
            case $- in
              *i*) echo "sub2_chaos dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. NEVER add
      # a check that always passes: an agent reads "all checks passed!" as a
      # signal, and a fake check makes `nix flake check` a liar.
      #
      # The repo's real test suites are NOT here on purpose: `go test` wants a
      # populated module cache and a writable $HOME, neither of which exists in
      # the build sandbox. `dev-test` is the gate for those.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files
      # -- of which this repo has plenty (30 .lua, a dozen .go, .yaml, .json).
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
