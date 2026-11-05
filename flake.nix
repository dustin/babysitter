{
  description = "babysitter";
  nixConfig.bash-prompt = "\[babysitter-dev\]$ ";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pushover-hs = {
      url = "github:dustin/pushover-hs";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, pushover-hs }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hpkgs = pkgs.haskellPackages.override {
          overrides = final: prev: {
            # Newer than nixpkgs has.
            net-mqtt = pkgs.haskell.lib.dontCheck (final.callHackageDirect {
              pkg = "net-mqtt";
              ver = "0.8.8.0";
              sha256 = "1xg3yhzis53zw9bid9kf028f19wpbb98rz6xgwbz10j3pcwjm0yi";
            } { });
            pushover-hs = pkgs.haskell.lib.dontCheck
              (final.callCabal2nix "pushover-hs" pushover-hs { });
          };
        };
        babysitter = hpkgs.callCabal2nix "babysitter" ./. { };
      in
      {
        packages.default = babysitter;
        checks.default = babysitter;

        devShells.default = hpkgs.shellFor {
          packages = _: [ babysitter ];
          withHoogle = false;
          buildInputs = with pkgs; [
            cabal-install
            ghcid
            hlint
            hpack
            stylish-haskell
            hpkgs.haskell-language-server
            zlib
          ];
        };
      });
}
