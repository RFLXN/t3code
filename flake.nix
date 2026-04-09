{
  description = "T3 Code desktop app for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs supportedSystems;

      desktopPackageJson = builtins.fromJSON (builtins.readFile ./apps/desktop/package.json);

      bunCpuBySystem = {
        aarch64-linux = "arm64";
        x86_64-linux = "x64";
      };

      nodeModulesHashBySystem = {
        aarch64-linux = "sha256-2LEVhI0ralzSrVdrZN6hWYAPI0alpBBFkGg5xm5q3vo=";
        x86_64-linux = "sha256-s9F++9cjkZUc5p9p0VGFhDF7qFWK/7sN+eG6nuFL6so=";
      };

      excludedPaths = [
        ".bun"
        ".turbo"
        "build"
        "node_modules"
        "release"
        "release-mock"
        "apps/desktop/dist-electron"
        "apps/server/dist"
        "apps/web/dist"
      ];

      src = lib.cleanSourceWith {
        src = ./.;
        filter =
          path: type:
          let
            relativePath = lib.removePrefix "${toString ./.}/" (toString path);
            isExcluded = lib.any (
              prefix: relativePath == prefix || lib.hasPrefix "${prefix}/" relativePath
            ) excludedPaths;
          in
          lib.cleanSourceFilter path type && !isExcluded;
      };

      perSystem = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          bunCpu = bunCpuBySystem.${system};
          nodeModulesHash = nodeModulesHashBySystem.${system};

          desktopItem = pkgs.makeDesktopItem {
            name = "t3code";
            desktopName = "T3 Code";
            genericName = "Coding agent GUI";
            exec = "t3code %U";
            icon = "t3code";
            categories = [ "Development" ];
            terminal = false;
          };

          nodeModules = pkgs.stdenvNoCC.mkDerivation {
            pname = "t3code-node-modules";
            inherit src;
            version = desktopPackageJson.version;

            impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars ++ [
              "GIT_PROXY_COMMAND"
              "SOCKS_SERVER"
            ];

            nativeBuildInputs = [
              pkgs.bun
              pkgs.nodejs_24
              pkgs."node-gyp"
              pkgs.python3
              pkgs.gnumake
              pkgs.gcc
              pkgs.writableTmpDirAsHomeHook
            ];

            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild

              export BUN_INSTALL_CACHE_DIR="$(mktemp -d)"

              bun install --frozen-lockfile --ignore-scripts --no-progress --os=linux --cpu=${bunCpu}

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out"
              cp -a ./node_modules "$out/node_modules"

              while IFS= read -r -d "" workspaceNodeModules; do
                target="$out/''${workspaceNodeModules#./}"
                mkdir -p "$(dirname "$target")"
                cp -a "$workspaceNodeModules" "$target"
              done < <(find apps packages scripts -name node_modules -type d -print0 2>/dev/null)

              runHook postInstall
            '';

            outputHash = nodeModulesHash;
            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
          };

          t3code = pkgs.stdenvNoCC.mkDerivation {
            pname = "t3code";
            version = desktopPackageJson.version;
            inherit src;

            nativeBuildInputs = [
              pkgs.bun
              pkgs.nodejs_24
              pkgs."node-gyp"
              pkgs.python3
              pkgs.gnumake
              pkgs.gcc
              pkgs.makeBinaryWrapper
              pkgs.copyDesktopItems
              pkgs.writableTmpDirAsHomeHook
            ];

            desktopItems = [ desktopItem ];

            configurePhase = ''
              runHook preConfigure

              chmod -R u+w .
              cp -a ${nodeModules}/node_modules ./node_modules
              cachedNodeModulesRoot="${nodeModules}"
              while IFS= read -r -d "" workspaceNodeModules; do
                relPath="''${workspaceNodeModules#"$cachedNodeModulesRoot"/}"
                target="./$relPath"
                mkdir -p "$(dirname "$target")"
                cp -a "$workspaceNodeModules" "$target"
              done < <(find ${nodeModules}/apps ${nodeModules}/packages ${nodeModules}/scripts -name node_modules -type d -print0 2>/dev/null)
              while IFS= read -r -d "" copiedNodeModules; do
                chmod -R u+w "$copiedNodeModules"
                patchShebangs "$copiedNodeModules"
              done < <(find . -name node_modules -type d -print0)

              export HOME="$TMPDIR"
              export PATH="$PWD/node_modules/.bin:$PATH"

              pushd apps/server/node_modules/node-pty
              node-gyp rebuild
              node scripts/post-install.js
              popd

              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild

              bun run build:desktop

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              appRoot="$out/lib/t3code"

              mkdir -p "$appRoot/apps/desktop" "$appRoot/apps/server"

              cp package.json "$appRoot/package.json"
              cp apps/desktop/package.json "$appRoot/apps/desktop/package.json"
              cp apps/server/package.json "$appRoot/apps/server/package.json"

              cp -R apps/desktop/dist-electron "$appRoot/apps/desktop/dist-electron"
              cp -a apps/desktop/node_modules "$appRoot/apps/desktop/node_modules"
              cp -R apps/desktop/resources "$appRoot/apps/desktop/resources"
              cp -R apps/server/dist "$appRoot/apps/server/dist"
              cp -a apps/server/node_modules "$appRoot/apps/server/node_modules"
              cp -R node_modules "$appRoot/node_modules"

              rm -f \
                "$appRoot/apps/desktop/node_modules/@t3tools/contracts" \
                "$appRoot/apps/desktop/node_modules/@t3tools/shared" \
                "$appRoot/apps/server/node_modules/@t3tools/contracts" \
                "$appRoot/apps/server/node_modules/@t3tools/shared" \
                "$appRoot/apps/server/node_modules/@t3tools/web"

              install -Dm644 \
                apps/desktop/resources/icon.png \
                "$out/share/icons/hicolor/512x512/apps/t3code.png"

              makeWrapper ${pkgs.lib.getExe pkgs.electron_40} "$out/bin/t3code" \
                --set-default ELECTRON_OZONE_PLATFORM_HINT auto \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git ]} \
                --add-flags "$appRoot/apps/desktop/dist-electron/main.js"

              runHook postInstall
            '';

            meta = {
              description = "Minimal web GUI for coding agents";
              homepage = "https://github.com/pingdotgg/t3code";
              license = pkgs.lib.licenses.mit;
              mainProgram = "t3code";
              platforms = [ system ];
            };
          };
        in
        {
          inherit pkgs t3code;
        }
      );
    in
    {
      packages = forAllSystems (system: {
        default = perSystem.${system}.t3code;
        t3code = perSystem.${system}.t3code;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${perSystem.${system}.t3code}/bin/t3code";
        };
        t3code = {
          type = "app";
          program = "${perSystem.${system}.t3code}/bin/t3code";
        };
      });

      devShells = forAllSystems (system: {
        default = perSystem.${system}.pkgs.mkShell {
          packages = [
            perSystem.${system}.pkgs.bun
            perSystem.${system}.pkgs.nodejs_24
            perSystem.${system}.pkgs."node-gyp"
            perSystem.${system}.pkgs.python3
            perSystem.${system}.pkgs.gnumake
            perSystem.${system}.pkgs.gcc
            perSystem.${system}.pkgs.electron_40
            perSystem.${system}.pkgs.git
            perSystem.${system}.pkgs.p7zip
            perSystem.${system}.pkgs.squashfsTools
            perSystem.${system}.pkgs.nixfmt
          ];
        };
      });

      formatter = forAllSystems (system: perSystem.${system}.pkgs.nixfmt);
    };
}
