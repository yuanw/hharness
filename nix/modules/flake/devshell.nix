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
          pkg-config
        ];
        # Needed so GHC/cabal can link transitive C deps (e.g. zlib via claude → tls).
        # `packages` alone does not run library setup hooks; `buildInputs` does.
        buildInputs = [ pkgs.zlib ];
        shellHook = ''
          export LIBRARY_PATH="${pkgs.zlib}/lib''${LIBRARY_PATH:+:}''${LIBRARY_PATH}"
          export CPATH="${pkgs.zlib.dev}/include''${CPATH:+:}''${CPATH}"
          # Default model for pi-agent-hs / ampcode-files-agent (Sonnet); override per provider.
          export ANTHROPIC_MODEL="''${ANTHROPIC_MODEL:-claude-sonnet-4-5-20250929}"
        '';
      };
    };
}
