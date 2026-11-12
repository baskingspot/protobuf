{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];

            # Project-specific tools. protobuf provides protoc, which is the
            # source of truth for the wire fixtures under test/data.
            # json_format in python's protobuf is the source of truth for the
            # proto3 JSON fixtures; no other JSON implementation is in the
            # tree, so this is what keeps that mapping honest.
            packages = with pkgs; [
              protobuf
              (python3.withPackages (ps: [ ps.protobuf ]))
            ];
          };
        };
    };
}
