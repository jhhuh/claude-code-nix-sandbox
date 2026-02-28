# Chromium extension bundling via managed policy

## Problem

The "Claude in Chrome" extension must be available inside every sandbox for browser automation. Without it, users must manually install it after every fresh sandbox launch.

## Decision: Managed policy force-install

Chromium on Linux reads managed policies from `/etc/chromium/policies/managed/*.json`. Setting `ExtensionInstallForcelist` auto-installs extensions from the Chrome Web Store on first launch.

```json
{"ExtensionInstallForcelist":["fcoeoabgfenejglbffodgkkbkcdhcgfn"]}
```

## Why this approach

### Alternatives considered

1. **Pre-populated profile with extension already installed** — fragile: profile format changes across Chromium versions, binary blobs in git, breaks on updates.

2. **`programs.chromium.extensions` NixOS option** — only works for NixOS (the VM), not bwrap or nspawn. Also sets user-level preferences, which are weaker than managed policies.

3. **`--load-extension` flag** — requires the unpacked extension directory. CRX from the Web Store can't be directly loaded this way. Would need to extract, version-pin, and maintain the extension source.

4. **Enterprise policy via `ExtensionInstallSources`** — more complex, requires hosting a CRX update manifest. Overkill when the extension is on the Chrome Web Store.

### Why managed policy wins

- **Works everywhere**: just needs a JSON file at the right path. bwrap bind-mounts it, nspawn copies it, VM uses `environment.etc`.
- **Declarative and version-independent**: no binary blobs, no profile format coupling.
- **Strongest enforcement**: managed policies can't be overridden by users or other extensions.
- **Requires network on first launch**: the extension installs from the Web Store. Acceptable since Claude Code already requires network for API calls.

## Implementation: `chromiumSandbox` package

Centralized in `nix/chromium.nix`:

- `writeShellScriptBin "chromium"` — wrapper that reads `CHROMIUM_USER_DATA_DIR` env var
- `writeShellScriptBin "chromium-browser"` — alias
- `passthru.extensionPolicy` — the policy JSON as a nix store path

Backends access the policy via `chromiumSandbox.extensionPolicy` and are responsible for placing it at `/etc/chromium/policies/managed/default.json`:

| Backend | Method |
|---------|--------|
| Bubblewrap | `--ro-bind ${chromiumSandbox.extensionPolicy} /etc/chromium/policies/managed/default.json` |
| Container | `cp ${chromiumSandbox.extensionPolicy}` into ephemeral container root |
| VM | `environment.etc."chromium/policies/managed/default.json".text` (NixOS declarative) |

## Verification

Inside a running sandbox: `cat /etc/chromium/policies/managed/default.json`
In Chromium: navigate to `chrome://policy` — should show `ExtensionInstallForcelist` as a managed policy.
