{ root, inputs, ... }:
{
  perSystem = { config, pkgs, lib, ... }:
    # Default shell.
    {
      devShells.default = pkgs.mkShell {
        name = "blog-dev-shell";
        meta.description = "Haskell development environment";
        # See https://community.flake.parts/haskell-flake/devshell#composing-devshells
        inputsFrom = [
          #          inputs.dream2nix.modules.dream2nix.nodejs-devshell-v3
          #config.haskellProjects.default.outputs.devShell # See ./nix/modules/haskell.nix
          config.pre-commit.devShell # See ./nix/modules/formatter.nix
        ];
        packages = with pkgs; [
          just
          nixd
          cabal-install
          ghc
          ghciwatch
          zlib
        ];
        shellHook = ''
          export LIBRARY_PATH="${pkgs.zlib}/lib''${LIBRARY_PATH:+:}''${LIBRARY_PATH}"
          export CPATH="${pkgs.zlib.dev}/include''${CPATH:+:}''${CPATH}"
        '';
      };
    };
}
