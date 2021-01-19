{ static ? false
, wrap ? !static
, pkgs ? import ./nixpkgs.nix { }
, psi4 ? pkgs.psi4
, gdma ? pkgs.gdma
}:
let
  spicyrc =
    let
      text = pkgs.lib.generators.toYAML {} {
        "psi4" = "${psi4}/bin/psi4";
        "gdma" = "${gdma}/bin/gdma";
      };
    in
      pkgs.writeTextFile {
        name = "spicyrc";
        inherit text;
      };

  buildPkgs =
    if static then pkgs.pkgsCross.musl64 else pkgs;


in buildPkgs.haskell-nix.project {
  src = buildPkgs.haskell-nix.haskellLib.cleanGit {
    name = "spicy";
    src = ./..;
  };

  compiler-nix-name = "ghc8102";

  configureArgs = if static
    then builtins.toString [
      "--disable-executable-dynamic"
      "--disable-shared"
      "--ghc-option=-optl=-static"
    ] else "";

  modules = [
    { packages.spicy.components.exes.spicy.postInstall = if wrap then ''
        # Make the wrapper functions available.
        runHook ${buildPkgs.makeWrapper}/nix-support/setup-hook

        # Generate a SpicyRC file for dependencies.
        wrapProgram $out/bin/spicy \
          --set SPICYRC ${spicyrc}
      '' else "";
    }
  ];
}
