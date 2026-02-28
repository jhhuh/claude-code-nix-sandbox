# Standalone Chromium wrapper for sandboxed Claude Code sessions
#
# - Reads CHROMIUM_USER_DATA_DIR env var for per-project profile isolation
# - Exposes extensionPolicy via passthru for backends to mount at
#   /etc/chromium/policies/managed/default.json
{ chromium, writeShellScriptBin, writeText, symlinkJoin }:
let
  extensionPolicy = writeText "chromium-extension-policy.json" (builtins.toJSON {
    ExtensionInstallForcelist = [
      "fcoeoabgfenejglbffodgkkbkcdhcgfn"  # Claude in Chrome
    ];
  });

  wrapper = writeShellScriptBin "chromium" ''
    args=()
    if [ -n "''${CHROMIUM_USER_DATA_DIR:-}" ]; then
      args+=("--user-data-dir=$CHROMIUM_USER_DATA_DIR")
    fi
    exec ${chromium}/bin/chromium "''${args[@]}" "$@"
  '';

  wrapperBrowser = writeShellScriptBin "chromium-browser" ''
    exec ${wrapper}/bin/chromium "$@"
  '';
in
symlinkJoin {
  name = "chromium-sandbox";
  paths = [ wrapper wrapperBrowser ];
  passthru = { inherit extensionPolicy; };
}
