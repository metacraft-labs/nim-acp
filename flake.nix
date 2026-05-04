{
  description = "nim-acp - Agent Client Protocol library for Nim";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
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
          preCommit = git-hooks.lib.${system}.run {
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
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nim
              nimble
              just
              nodejs
              nixfmt-rfc-style
            ];
            shellHook = ''
              ${preCommit.shellHook}
            '';
          };
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
