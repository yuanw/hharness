{ inputs, lib, ... }:
{
  imports = [ inputs.haskell-flake.flakeModule ];

  perSystem = { self', inputs', pkgs, system, config, ... }:
    {
      haskellProjects.default = {
        projectFlakeName = "hharness";
      };

      packages.default = self'.packages.hharness-ai;

      devShells.default = lib.mkForce (pkgs.mkShell {
        name = "hharness-dev-shell";
        meta.description = "Haskell development environment for hharness";
        inputsFrom = [
          config.haskellProjects.default.outputs.devShell
          config.pre-commit.devShell
        ];
        packages = with pkgs; [
          just
          nixd
          cabal-install
          ghc
          ghciwatch
          pkg-config
          hpack
        ];
        buildInputs = [ pkgs.zlib ];
        shellHook = ''
          export LIBRARY_PATH="${pkgs.zlib}/lib''${LIBRARY_PATH:+:}''${LIBRARY_PATH}"
          export CPATH="${pkgs.zlib.dev}/include''${CPATH:+:}''${CPATH}"
          export ANTHROPIC_MODEL="''${ANTHROPIC_MODEL:-claude-sonnet-4-5-20250929}"
        '';
      });
    };
}
