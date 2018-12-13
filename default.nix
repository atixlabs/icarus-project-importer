let
  localLib = import ./lib.nix;
in
{ system ? builtins.currentSystem
, config ? {}
, gitrev ? "beta"
, buildId ? null
, pkgs ? (import (localLib.fetchNixPkgs) { inherit system config; })
# should enable or disable all checkPhases for cardano libraries,
# but doesn’t right now.
, globalDoCheck ? false
# profiling slows down performance by 50% so we don't enable it by default
, enableProfiling ? false
, enableDebugging ? false
, allowCustomConfig ? true
}:

with pkgs.lib;
with pkgs.haskell.lib;

let
  # enable or disable checking for a Haskell package
  globalCheck = if globalDoCheck then doCheck else dontCheck;
  addGitRev = subject: subject.overrideAttrs (drv: { GITREV = gitrev; });
  addRealTimeTestLogs = drv: overrideCabal drv (attrs: {
    testTarget = "--log=test.log || (sleep 10 && kill $TAILPID && false)";
    preCheck = ''
      mkdir -p dist/test
      touch dist/test/test.log
      tail -F dist/test/test.log &
      export TAILPID=$!
    '';
    postCheck = ''
      sleep 10
      kill $TAILPID
    '';
  });
  cardanoPkgs = ((import ./pkgs { inherit pkgs; }).override {
    overrides = self: super: {
      cardano-sl-core = overrideCabal super.cardano-sl-core (drv: {
        configureFlags = (drv.configureFlags or []) ++ [
          "-f-asserts"
        ];
      });

      cardano-sl = overrideCabal super.cardano-sl (drv: {
        # production full nodes shouldn't use wallet as it means different constants
        configureFlags = (drv.configureFlags or []) ++ [
          "-f-asserts"
        ];
        # waiting on load-command size fix in dyld
        doCheck = globalDoCheck && !pkgs.stdenv.isDarwin;
        passthru = {
          inherit enableProfiling;
        };
      });

      cardano-sl-wallet-static = justStaticExecutables super.cardano-sl-wallet;
      cardano-sl-networking = dontCheck super.cardano-sl-networking;
      cardano-sl-client = globalCheck (addRealTimeTestLogs super.cardano-sl-client);
      cardano-sl-generator = globalCheck (addRealTimeTestLogs super.cardano-sl-generator);
      # cardano-sl-auxx = addGitRev (justStaticExecutables super.cardano-sl-auxx);
      cardano-sl-auxx = addGitRev (justStaticExecutables (overrideCabal super.cardano-sl-auxx (drv: {
        # waiting on load-command size fix in dyld
        executableHaskellDepends = drv.executableHaskellDepends ++ [self.cabal-install];
      })));
      cardano-sl-node = addGitRev super.cardano-sl-node;
      cardano-sl-wallet-new = addGitRev (justStaticExecutables super.cardano-sl-wallet-new);
      cardano-sl-tools = addGitRev (justStaticExecutables (overrideCabal super.cardano-sl-tools (drv: {
        # waiting on load-command size fix in dyld
        doCheck = globalDoCheck && ! pkgs.stdenv.isDarwin;
        executableHaskellDepends = drv.executableHaskellDepends ++ [self.cabal-install];
      })));

      cardano-sl-node-static = justStaticExecutables self.cardano-sl-node;
      cardano-sl-explorer-static = addGitRev (justStaticExecutables self.cardano-sl-explorer);
      cardano-sl-blockchain-importer-static = globalCheck (addGitRev (justStaticExecutables self.cardano-sl-blockchain-importer));
      cardano-report-server-static = justStaticExecutables self.cardano-report-server;

      # Undo configuration-nix.nix change to hardcode security binary on darwin
      # This is needed for macOS binary not to fail during update system (using http-client-tls)
      # Instead, now the binary is just looked up in $PATH as it should be installed on any macOS
      x509-system = overrideDerivation super.x509-system (drv: {
        postPatch = ":";
      });

      # TODO: get rid of pthreads option once cryptonite 0.25 is released
      # DEVOPS-393: https://github.com/haskell-crypto/cryptonite/issues/193
      cryptonite = appendPatch (appendConfigureFlag super.cryptonite "--ghc-option=-optl-pthread") ./pkgs/cryptonite-segfault-blake.patch;

      # Due to https://github.com/input-output-hk/stack2nix/issues/56
      hfsevents = self.callPackage ./pkgs/hfsevents.nix { inherit (pkgs.darwin.apple_sdk.frameworks) Cocoa CoreServices; };

      mkDerivation = args: super.mkDerivation (args // {
        enableLibraryProfiling = enableProfiling;
        enableExecutableProfiling = enableProfiling;
        # Static linking for everything to work around
        # https://ghc.haskell.org/trac/ghc/ticket/14444
        # This will be the default in nixpkgs since
        # https://github.com/NixOS/nixpkgs/issues/29011
        enableSharedExecutables = false;
      } // optionalAttrs enableDebugging {
        # TODO: DEVOPS-355
        dontStrip = true;
        configureFlags = (args.configureFlags or []) ++ [ "--ghc-options=-g --disable-executable-stripping --disable-library-stripping" "--profiling-detail=toplevel-functions"];
        doCheck = globalDoCheck;
      });
    };
  });
  connect = let
      walletConfigFile = ./custom-wallet-config.nix;
      walletConfig = if allowCustomConfig then (if builtins.pathExists walletConfigFile then import walletConfigFile else {}) else {};
    in
      args: pkgs.callPackage ./scripts/launch/connect-to-cluster (args // { inherit gitrev; } // walletConfig );

  other = rec {
    demoCluster = pkgs.callPackage ./scripts/launch/demo-cluster { inherit gitrev; };
    walletIntegrationTests = pkgs.callPackage ./scripts/test/wallet/integration { inherit gitrev; };
    buildWalletIntegrationTests = pkgs.callPackage ./scripts/test/wallet/integration/build-test.nix { inherit walletIntegrationTests pkgs; };
    cardano-sl-explorer-frontend = (import ./explorer/frontend {
      inherit system config gitrev pkgs;
      cardano-sl-explorer = cardanoPkgs.cardano-sl-explorer-static;
    });
    mkDocker = { environment, connectArgs ? {} }: import ./docker.nix { inherit environment connect gitrev pkgs connectArgs; };
    stack2nix = import (pkgs.fetchFromGitHub {
      owner = "input-output-hk";
      repo = "stack2nix";
      rev = "abd199510eb38c442e14fd82677f9cc1f7430cfb";
      sha256 = "0rrawm054n9r45jvxmdzwkfl1mvar2wag8nvhqzf3ggnbcds2aj2";
    }) { inherit pkgs; };
    inherit (pkgs) purescript;
    connectScripts = {
      mainnetWallet = connect {};
      mainnetExplorer = connect { executable = "explorer"; };
      mainnetBlockchainImporter = connect { executable = "blockchain-importer"; };
      stagingWallet = connect { environment = "mainnet-staging"; };
      demoWallet = connect { environment = "demo"; };
      stagingExplorer = connect { executable = "explorer"; environment = "mainnet-staging"; };
      stagingBlockchainImporter = connect { executable = "blockchain-importer"; environment = "mainnet-staging"; };
    };
    dockerImages = {
      mainnetWallet = mkDocker { environment = "mainnet"; };
      stagingWallet = mkDocker { environment = "mainnet-staging"; };
      testnetBlockchainImporter = mkDocker {
        environment = "testnet";
        connectArgs = {
          executable = "blockchain-importer";
          # additionalNodeArgs = ""; TODO?
        };
      };
      mainnetBlockchainImporter = mkDocker {
        environment = "mainnet";
        connectArgs = {
          executable = "blockchain-importer";
          # additionalNodeArgs = ""; TODO?
        };
      };
      stagingBlockchainImporter = mkDocker {
        environment = "mainnet-staging";
        connectArgs = {
          executable = "blockchain-importer";
          # additionalNodeArgs = ""; TODO?
        };
      };
    };

    daedalus-bridge = let
      inherit (cardanoPkgs.cardano-sl-node) version;
    in pkgs.runCommand "cardano-daedalus-bridge-${version}" {
      inherit version;
    } ''
      # Generate daedalus-bridge
      mkdir -p $out/bin $out/config
      cd $out
      ${optionalString (buildId != null) "echo ${buildId} > build-id"}
      echo ${gitrev} > commit-id
      echo ${version} > version

      cp ${./log-configs + "/daedalus.yaml"} config/log-config-prod.yaml
      cp ${./lib}/configuration.yaml config
      cp ${./lib}/*genesis*.json config
      cp ${cardanoPkgs.cardano-sl-tools}/bin/cardano-launcher bin
      cp ${cardanoPkgs.cardano-sl-wallet-new}/bin/cardano-node bin

      # test that binaries exit with 0
      ./bin/cardano-node --help > /dev/null
      HOME=$TMP ./bin/cardano-launcher --help > /dev/null
    '';
  };
in cardanoPkgs // other
