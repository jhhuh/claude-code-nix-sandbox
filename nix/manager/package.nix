# Nix package for the Claude Sandbox Manager daemon
{
  lib,
  rustPlatform,
  makeWrapper,
  imagemagick,
  socat,
  tmux,
  xorg,
  pkg-config,
  openssl,
}:

rustPlatform.buildRustPackage {
  pname = "claude-sandbox-manager";
  version = "0.1.0";

  src = ../../manager;
  cargoLock.lockFile = ../../manager/Cargo.lock;

  nativeBuildInputs = [ makeWrapper pkg-config ];
  buildInputs = [ openssl ];

  postInstall = ''
    # Copy static assets for the web UI
    mkdir -p $out/share/claude-sandbox-manager
    cp -r $src/static $out/share/claude-sandbox-manager/

    # Wrap binary with runtime dependencies on PATH and default static dir
    wrapProgram $out/bin/claude-sandbox-manager \
      --prefix PATH : ${lib.makeBinPath [ imagemagick socat tmux xorg.xorgserver ]} \
      --set-default MANAGER_STATIC_DIR $out/share/claude-sandbox-manager/static
  '';

  meta = {
    description = "Web dashboard and API for managing sandboxed Claude Code sessions";
    mainProgram = "claude-sandbox-manager";
  };
}
