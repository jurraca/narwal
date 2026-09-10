{
  description = "Narwal — Nix binary cache proxy over Nostr + Blossom";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = prev: final: rec {
      beamPackages = prev.beamMinimal29Packages;
      elixir = beamPackages.elixir_1_20;
      hex = beamPackages.hex;
    };

    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgsFor system;
      inherit (pkgs) beamPackages;
    in {
      default = beamPackages.mixRelease {
        pname = "narwal";
        version = "0.1.0";
        src = ./.;

        mixNixDeps = import ./deps.nix { inherit pkgs beamPackages; };

        buildInputs = [ pkgs.openssl ];
      };

      narwal = self.packages.${system}.default;
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = pkgs.callPackage ./shell.nix {};
    });

    nixosModules = {
      narwal = import ./module.nix;
      default = self.nixosModules.narwal;
    };
  };
}
