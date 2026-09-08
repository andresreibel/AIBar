# Troubleshooting

## `Bun was not found`

Install Bun and rerun the installer:

```sh
brew install bun
./install.sh
```

The macOS app checks `CLAUDEXBAR_BUN`, `~/.bun/bin/bun`, `/opt/homebrew/bin/bun`, and `/usr/local/bin/bun`.

## `rsvg-convert is required`

The icon build requires `librsvg`:

```sh
brew install librsvg
```

## `Login required`

Open **Notifications** from the slim control at the bottom of the dashboard and click **Login** for the provider. ClaudexBar runs `codex login` for OpenAI, `claude auth login` for Anthropic, or its explicit SpaceXAI PKCE flow. Complete the provider flow and refresh. Its macOS menu-bar and Omarchy counter stay hidden until usage returns. **Clear notifications** hides the complete current set until its content changes.

SpaceXAI credentials are stored at `~/.codex/claudexbar/grok-auth.json` with mode `0600`. The browser opens only after the explicit **Login** action. Missing or rejected credentials show **Login required**; network and malformed-response failures do not claim that you are logged out.

## `Subscription expired`

The provider does not occupy a full usage card and its compact counter is hidden. Open the dashboard's bottom notification center to see the status. ClaudexBar does not offer a false login action or infer expiry from a bare HTTP status or error sentence. This state is used only when a provider supplies a documented structured entitlement signal.

## `Usage unavailable`

Use the normal refresh action. The provider does not occupy a full usage card and its counter stays hidden until usage returns; its status remains available from the bottom notification center. Network failures, malformed responses, unsupported organization policy, and ambiguous HTTP errors remain unavailable rather than being mislabeled as login or subscription loss.

## Claude usage returns `403`

Anthropic does not document the internal OAuth usage endpoint or an individual subscription-entitlement API. ClaudexBar therefore treats its `401`, `402`, and `403` responses as **Usage unavailable** without affecting the other providers. The documented `claude auth status` exit code distinguishes CLI login present (`0`) from absent (`1`); its observed `subscriptionType` JSON field is not documented as a fresh entitlement signal and is not used. A bare usage status is never classified as logged out or subscription expiry.

## Cached Claude usage

During temporary Claude failures or `429` backoff, ClaudexBar reuses the last valid Claude payload and shows **Temporarily unavailable — showing cached usage**. Cache and backoff state live under `~/.codex/claudexbar/`.

## Reset credit expiry notices

An available OpenAI reset credit turns cosmic orange when it expires within 14 days and red when it expires within 7 days. The same expiry appears in the bottom notification center. If the count is available but no expiry details are returned by the local Codex app-server, ClaudexBar keeps the count neutral and does not invent a deadline.

## Omarchy Quattro bar is missing or stale

Ensure `~/.config/omarchy/shell.json` contains the documented `claudexbar` command widget with `"interval": 1`. The widget runs the installed engine every second, but the engine only fetches live usage about once per five minutes. Source updates take effect on the next run; restart the Omarchy shell only after changing the widget configuration.

## Linux dashboard does not open

Run the installed adapter from a terminal:

```sh
~/.local/bin/claudexbar-dashboard
```

Install Python 3, GTK 4, and PyGObject if it reports a missing GTK runtime. On Wayland, install `gtk4-layer-shell` for the anchored top-right popover; the dashboard still works as a normal GTK window without it. Confirm the Quattro click command is `~/.local/bin/claudexbar-dashboard`, then rerun `./install.sh` after source updates.

## Rebuild the installed macOS app

Do not test against a stale menu-bar process:

```sh
pkill -x ClaudexBar || true
make install
open /Applications/ClaudexBar.app
```

Confirm the running executable:

```sh
pgrep -fl /Applications/ClaudexBar.app/Contents/MacOS/ClaudexBar
```
