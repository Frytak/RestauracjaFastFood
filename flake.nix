{
  description = "Procesowo-wątkowa symulacja restauracji fast food (projekt SO).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks.flakeModule
      ];

      perSystem =
        {
          config,
          self',
          pkgs,
          ...
        }:
        let
          name = "restauracja";
          src = ./.;
        in
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = name;
            version = "0.1.0";
            inherit src;

            nativeBuildInputs = with pkgs; [
              cmake
              ninja
              pkg-config
            ];

            cmakeFlags = [ (pkgs.lib.cmakeFeature "CMAKE_BUILD_TYPE" "Release") ];

            meta = {
              description = "Symulacja restauracji fast food na procesach i wątkach";
              mainProgram = "kierownik";
              platforms = pkgs.lib.platforms.linux;
            };
          };

          apps.default = {
            type = "app";
            program = "${self'.packages.default}/bin/kierownik";
            meta.description = "Uruchom symulację restauracji (rola kierownika)";
          };

          devShells.default = pkgs.mkShell {
            inherit name;

            packages = with pkgs; [
              cmake
              ninja
              pkg-config
              clang-tools
              clang
              gdb
              valgrind
              catch2_3
              typst
              iproute2
              procps
            ];

            shellHook = config.pre-commit.installationScript;
          };

          checks = {
            # The artifact must at least build; `nix flake check` must never
            # pass on a project that does not.
            default = self'.packages.default;

            # A `tests` check (ctest in a runCommand) comes once tests/ has
            # something to run.
          };

          treefmt = {
            programs.nixfmt.enable = true;
            programs.deadnix.enable = true;
            programs.statix.enable = true;
            programs.clang-format.enable = true;
            programs.cmake-format.enable = true;
          };

          pre-commit.settings.hooks = {
            treefmt.enable = true;
            convco.enable = true;
          };
        };
    };
}
