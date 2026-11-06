{
  description = "balena-plus -- a thin, name-resolving wrapper around the balena CLI";

  inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Widening this is the whole generalization story: add "aarch64-linux"
      # or "aarch64-darwin" here and every output below follows. Kept to
      # x86_64-linux until someone actually needs more.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # self.rev only exists for a clean git tree; a dirty checkout has
      # dirtyRev instead, and `nix build` of a plain directory has neither.
      # "unknown" disables the update check, which is the right answer for
      # anything not installed from a published revision.
      rev = self.rev or "unknown";

      balena-plus =
        pkgs:
        pkgs.writeShellApplication {
          name = "balena-plus";

          # Note what is NOT here: balena-cli. writeShellApplication emits
          # `export PATH="<runtimeInputs>:$PATH"` (inheritPath defaults true), so
          # leaving it out means the wrapper uses whatever balena the user
          # already has rather than pulling a second ~630MB copy into the
          # closure. ensure_login explains it if there isn't one.
          #
          # coreutils is explicit for `timeout`, which the update check needs.
          runtimeInputs = with pkgs; [
            python3
            fzf
            coreutils
          ];

          # Generated preamble + the script. install.sh writes these same
          # assignments in its no-nix branch, so there is one mechanism, not two.
          text = ''
            # Generated preamble -- flake.nix injects these.
            plus_completion=${./completion.bash}
            self_rev=${rev}
          ''
          + builtins.readFile ./balena-plus.sh;

          meta.description = "Wrapper around the balena CLI: device-name resolution, fleet picker, login on demand, and ssh/tunnel/logs/ps/uuid/devices helpers";
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          plus = balena-plus pkgs;
        in
        {
          default = plus;
          balena-plus = plus;

          # For a machine with no balena-cli at all. install.sh reaches for
          # this only when `command -v balena` comes up empty, so nobody who
          # already has the CLI downloads a second one.
          balena-plus-with-cli = pkgs.symlinkJoin {
            name = "balena-plus-with-cli";
            paths = [
              plus
              pkgs.balena-cli
            ];
            meta.description = "${plus.meta.description} (bundles balena-cli)";
          };
        }
      );

      # `nix flake check` -- builds both packages, and writeShellApplication
      # runs shellcheck over the script as part of that.
      checks = forAllSystems (system: {
        inherit (self.packages.${system}) balena-plus balena-plus-with-cli;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
