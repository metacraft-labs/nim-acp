{
  description = "nim-acp - Agent Client Protocol library for Nim";

  inputs = {
    mcl-standard-hook-source = {
      url = "github:metacraft-labs/devops-modules/6ba34072850f7348e1669a6daf8a0acb79669434";
      flake = false;
    };
    managed-hook-reprobuild.url = "github:metacraft-labs/reprobuild/064daf5b154ea6a0758ddb2dcbcbc07685216e44";
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/<this repo>` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            fi
            unset _own_repo_root
          '';

          legacyPreCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files.enable = true;
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          # Preserve the original native 500 KB cap while adopting the complete
          # named standard set and retaining the merge-conflict and lint gates.
          standardHooks = import (inputs.mcl-standard-hook-source + "/git-hooks/standard-hooks.nix") {
            inherit pkgs;
            lib = pkgs.lib;
            src = inputs.mcl-standard-hook-source;
            maxKB = 500;
          };
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            configPath = ".pre-commit-config.nix.yaml";
            hooks = standardHooks // {
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
          nativeHookFactory =
            configuration:
            pkgs.runCommand "nim-acp-native-hook-factory"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.bash
                  configuration.config.package
                ];
              }
              ''
                export PRE_COMMIT_HOME="$TMPDIR/nim-acp-native-hook-cache"
                export XDG_CACHE_HOME="$TMPDIR/nim-acp-native-factory-cache"
                export GIT_CONFIG_GLOBAL="$TMPDIR/nim-acp-native-factory-gitconfig"
                export GIT_CONFIG_NOSYSTEM=1
                : > "$GIT_CONFIG_GLOBAL"
                mkdir -p "$PRE_COMMIT_HOME" "$XDG_CACHE_HOME" fixture
                cd fixture
                git init --template= >/dev/null
                if git config --get core.hooksPath; then
                  echo 'Unexpected native factory hooksPath authority' >&2
                  exit 1
                fi
                test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
                ln -s ${configuration.config.configFile} ${configuration.config.configPath}
                mkdir -p "$out"
                for hook in pre-commit pre-push; do
                  ${pkgs.lib.getExe configuration.config.package} install -c ${configuration.config.configPath} -t "$hook"
                  install -m 0755 ".git/hooks/$hook" "$out/$hook"
                done
              '';
          expectedNativeHook = nativeHookFactory preCommit;
          expectedLegacyNativeHook = nativeHookFactory legacyPreCommit;
          hookOwnershipGuard = ./nix/hook-ownership-guard.py;
          hookTransaction = ./nix/hook-transaction.py;
          actualNativeInstaller = pkgs.writeShellScript "nim-acp-native-hook-installer" preCommit.shellHook;
          managedHookConstructor = inputs.managed-hook-reprobuild.packages.${system}.reprobuild;
          guardedHookInstall = ''
            if [ -n "''${REPROBUILD_REPRO:-}" ] && [ "$REPROBUILD_REPRO" != "${managedHookConstructor}/bin/repro" ]; then
              echo 'Foreign inherited managed constructor authority' >&2
              exit 1
            fi
            export REPROBUILD_REPRO="${managedHookConstructor}/bin/repro"
            ${pkgs.python3}/bin/python3 ${hookTransaction} "$_own_repo_root" ${hookOwnershipGuard} ${expectedNativeHook} ${pkgs.git}/share/git-core/templates ${expectedLegacyNativeHook} ${preCommit.config.configFile} ${legacyPreCommit.config.configFile} ${actualNativeInstaller} ${pkgs.git}/bin/git ${pkgs.bash}/bin/bash >&2
            _nim_acp_hook_status=$?
            if [ "$_nim_acp_hook_status" -ne 0 ]; then
              unset _nim_acp_hook_status
              exit 1
            fi
            unset _nim_acp_hook_status
          '';
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            REPROBUILD_REPRO = "${managedHookConstructor}/bin/repro";
            NIM_ACP_FULL_HOOK_CONFIG = preCommit.config.configFile;
            NIM_ACP_EXPECTED_NATIVE_HOOKS = expectedNativeHook;
            NIM_ACP_HOOK_INSTALLER = pkgs.writeShellScript "nim-acp-guarded-hook-installer" (
              ownRepoOnly guardedHookInstall
            );
            packages = [
              managedHookConstructor
              preCommit.config.package
            ]
            ++ preCommit.enabledPackages
            ++ (with pkgs; [
              nim
              nimble
              just
              nodejs
              nixfmt-rfc-style
              git
              bash
              python3
              direnv
              uv
            ]);
            shellHook = ''
              ${ownRepoOnly guardedHookInstall}
            '';
          };
          # Expose the owning constructor without activating its shell hook.
          # The original checkout Git is passed explicitly by the CI step.
          packages.ci-initial-samples = pkgs.writeShellScriptBin "nim-acp-initial-samples" ''
            exec ${pkgs.python3}/bin/python3 ${./ci}/initialize-checkout-samples.py ${pkgs.git}/bin/git "$@"
          '';
          packages.native-hook-config = preCommit.config.configFile;
          packages.legacy-native-hook-config = legacyPreCommit.config.configFile;
          packages.expected-native-hooks = expectedNativeHook;
          packages.expected-legacy-native-hooks = expectedLegacyNativeHook;
          packages.managed-hook-constructor = managedHookConstructor;
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "nim-acp";
            version = builtins.readFile ./VERSION;
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src nim_acp.nimble VERSION README.md $out/
            '';
          };
        };
    };
}
