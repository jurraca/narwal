{
  description = "Nix-Blossom proxy server in Elixir";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = prev: final: rec {
      beamPackages = prev.beamMinimal29Packages;
      elixir = beamPackages.elixir_1_20;
      hex = beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
      #"x86_64-darwin"
      #"aarch64-darwin"
    ];

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
    in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = pkgs.callPackage ./shell.nix {};
    });
  };
}

