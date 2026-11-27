{ lib, stdenv, fetchurl, autoPatchelfHook, makeBinaryWrapper, cacert, bash }:

# Use the reviewed npm native package bytes. Calling ld-linux directly changes
# Copilot's self-executable identity; patch the ELF interpreter/rpath instead.
stdenv.mkDerivation {
  pname = "heimdall-copilot-acp";
  version = "1.0.114";
  src = fetchurl {
    url = "https://registry.npmjs.org/@github/copilot-linux-x64/-/copilot-linux-x64-1.0.114.tgz";
    hash = "sha512-gHnINm9ffFqz+G19cQUqRe3lsTAQO3Tbdj7r7Bx1ktZvC5X6iXd/nfo1DRTj9magb52aGRiuwB3yvD1lkW68xQ==";
  };
  sourceRoot = "package";
  nativeBuildInputs = [ autoPatchelfHook makeBinaryWrapper ];
  buildInputs = [ stdenv.cc.cc.lib ];
  # Node SEA stores the application in its executable. Preserve its payload.
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 copilot "$out/libexec/copilot"
    install -Dm644 package.json "$out/share/heimdall-copilot-acp/package.json"
    install -Dm644 LICENSE.md "$out/share/licenses/heimdall-copilot-acp/LICENSE.md"
    install -Dm644 QuickJS.LICENSE.txt "$out/share/licenses/heimdall-copilot-acp/QuickJS.LICENSE.txt"
    install -Dm644 rquickjs.LICENSE.txt "$out/share/licenses/heimdall-copilot-acp/rquickjs.LICENSE.txt"
    mkdir -p "$out/bin"
    makeWrapper "$out/libexec/copilot" "$out/bin/copilot" \
      --set COPILOT_AUTO_UPDATE false \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
      --set-default SSL_CERT_DIR ${cacert}/etc/ssl/certs \
      --prefix PATH : ${lib.makeBinPath [ bash ]}
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export COPILOT_HOME="$TMPDIR/copilot-home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$COPILOT_HOME" "$XDG_CACHE_HOME"
    "$out/bin/copilot" --version | grep -Fx 'GitHub Copilot CLI 1.0.114.'
    runHook postInstallCheck
  '';
  meta = {
    description = "GitHub Copilot CLI built for NixOS hosts; optional, user-built (Heimdall never installs it)";
    homepage = "https://github.com/github/copilot-cli";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "copilot";
    platforms = [ "x86_64-linux" ];
  };
}
