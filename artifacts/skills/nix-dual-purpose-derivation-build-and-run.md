# Nix dual-purpose derivation: nix build (static output) + nix run (executable)

## Problem

A `stdenv.mkDerivation` that produces static files (e.g. mdBook HTML) can't be used with `nix run` — Nix looks for `$out/bin/<name>` and fails with "unable to execute ... No such file or directory". But rewriting the package as `writeShellApplication` loses the static build output that `nix build` users expect.

## Solution: writeShellScript + symlink

Use a separate `writeShellScript` for the executable, then symlink it into `$out/bin/` alongside the static output:

```nix
docs = let
  docsSrc = ./docs;
  serveScript = pkgs.writeShellScript "claude-sandbox-docs" ''
    dest=$(mktemp -d)
    trap 'rm -rf "$dest"' EXIT
    exec ${pkgs.mdbook}/bin/mdbook serve ${docsSrc} --dest-dir "$dest"
  '';
in pkgs.stdenv.mkDerivation {
  name = "claude-sandbox-docs";
  src = docsSrc;
  nativeBuildInputs = [ pkgs.mdbook ];
  buildPhase = "mdbook build";
  installPhase = ''
    mkdir -p $out/bin
    cp -r book/* $out/
    ln -s ${serveScript} $out/bin/claude-sandbox-docs
  '';
};
```

Result:
- `nix build .#docs` → `result/index.html` (static files at root)
- `nix run .#docs` → runs the serve script

## Why writeShellScript instead of a heredoc

Writing a bash script via `cat > $out/bin/... <<EOF` inside `installPhase` creates an escaping nightmare: `$out` must be bash-interpolated by the build, `${pkgs.mdbook}` must be Nix-interpolated, and `$(mktemp)` must survive to runtime. These three interpolation layers (Nix `''` string → bash build → bash runtime heredoc) conflict.

`writeShellScript` is a separate Nix derivation where `''${...}` escaping works normally. The resulting store path is just symlinked in — no multi-layer escaping.

## Gotcha: read-only source in nix store

`${docsSrc}` resolves to a read-only nix store path. Tools that write output relative to their source directory (like `mdbook serve` defaulting to `./book/`) will fail. Use `--dest-dir` (or equivalent) to redirect output to a writable location like `$(mktemp -d)`.

## When to use

Any Nix package where `nix build` produces data files (HTML, docs, assets) but `nix run` should launch a server, viewer, or other tool that operates on that data.
