{
  description = "Narwal — Nix binary cache proxy over Nostr + Blossom";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = final: prev: {
      beamPackages = prev.beamMinimal29Packages.extend (pself: psuper: {
        elixir = psuper.elixir_1_20;
      });
      elixir = final.beamPackages.elixir;
      hex = final.beamPackages.hex;
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

        mixNixDeps = pkgs.callPackages ./deps.nix { };

        buildInputs = [ pkgs.openssl ];

        meta = {
          mainProgram = "narwal";
        };
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
