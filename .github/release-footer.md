## Install

**App** — download the `.dmg`, drag `asctl.app` to Applications.

**CLI** — download the tarball, put `asctl` on your `PATH`.

Both are universal (Apple silicon and Intel).

### First launch — macOS will block it once

These builds are **ad-hoc signed, not notarised**, so Gatekeeper
refuses them until you say otherwise. One command clears it:

```bash
xattr -dr com.apple.quarantine /Applications/asctl.app
```

Or double-click, let it be refused, then go to **System Settings ▸
Privacy & Security**, scroll to Security, and press **Open Anyway**.

Right-click ▸ Open used to be enough; on current macOS it is not.

For the CLI: `xattr -d com.apple.quarantine asctl`.

Notarising needs a paid Developer ID, which this project does not
have. The build is reproducible from source if you would rather not
trust the binary — see the workflow.

### Updating

The app can update itself — the menu bar item has a check, and it
verifies the download against `SHA256SUMS.txt` before installing.

Permissions carry across updates. Releases share a signing certificate,
so the identity macOS records stays the same from one version to the
next — confirmed on a real update between released versions, not just
expected.

A copy you built yourself is signed ad-hoc and identified by its
contents instead, so moving between your own build and a release will
ask for them once.

### Permissions

| Needed for | Grant |
|---|---|
| 2.4 GHz receiver or USB cable | Input Monitoring |
| Bluetooth configuration and battery | Bluetooth |
| Wheel-direction fix | Accessibility |

macOS attributes each to the process that asks, so grant them to
`asctl.app` rather than to your terminal.

### Uninstalling

`uninstall.sh` ships in both downloads. It asks whether to keep
`~/.config/asctl`, which holds your profiles — and since the mouse
cannot be read back, that folder is the only record of a
configuration that exists anywhere.

      - name: Remove the signing keychain
        if: always()
        run: |
          if [ -n "${SIGN_KEYCHAIN:-}" ] && [ -f "$SIGN_KEYCHAIN" ]; then
security list-keychains -d user -s \
  $(security list-keychains -d user | tr -d '"' | grep -v "$SIGN_KEYCHAIN") || true
security delete-keychain "$SIGN_KEYCHAIN" || true
          fi
