#!/usr/bin/env python3

import ctypes.util
import json
import math
import os
import shutil
import subprocess
import sys
import time
import threading
from datetime import datetime
from pathlib import Path

if os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("CLAUDEXBAR_LAYER_REEXEC"):
    layer_shell = ctypes.util.find_library("gtk4-layer-shell")
    if layer_shell:
        environment = os.environ.copy()
        preload = environment.get("LD_PRELOAD")
        environment["LD_PRELOAD"] = f"{layer_shell}:{preload}" if preload else layer_shell
        environment["CLAUDEXBAR_LAYER_REEXEC"] = "1"
        os.execvpe(sys.executable, [sys.executable, *sys.argv], environment)

try:
    import gi

    gi.require_version("Gtk", "4.0")
    from gi.repository import Gio, GLib, Gtk
except (ImportError, ValueError) as error:
    raise SystemExit(
        "ClaudexBar dashboard requires GTK 4 and PyGObject. "
        "Install python-gobject and gtk4 for your distribution."
    ) from error

try:
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell
except (ImportError, ValueError):
    Gtk4LayerShell = None

PROVIDERS = {
    "claude": ("A", "Anthropic"),
    "codex": ("O", "OpenAI"),
    "grok": ("S", "SpaceXAI"),
}

ACCESS_PRESENTATION = {
    "available": (None, False, False),
    "stale": ("Temporarily unavailable — showing cached usage", False, False),
    "unavailable": ("Usage unavailable", False, False),
    "login_required": ("Login required", True, True),
    "subscription_expired": ("Subscription expired", False, True),
}

NOTIFICATION_DISMISSAL_PATH = Path.home() / ".codex" / "claudexbar" / "dismissed-notifications"

CSS = """
window.claudexbar-window {
  background: rgba(22, 22, 25, 0.97);
  color: #f4f4f5;
}
.claudexbar-root {
  padding: 16px 16px 24px;
}
.app-title {
  font-size: 15px;
  font-weight: 700;
}
.icon-button,
menubutton.icon-button > button {
  min-width: 20px;
  min-height: 20px;
  padding: 2px;
  border: 0;
  border-radius: 7px;
  box-shadow: none;
  background: transparent;
  color: #777780;
}
.icon-button:hover,
menubutton.icon-button > button:hover {
  background: rgba(255, 255, 255, 0.045);
}
.warning-button,
menubutton.warning-button > button {
  color: #666670;
}
.provider-card {
  min-width: 164px;
  padding: 12px;
  border: 1px solid rgba(255, 255, 255, 0.10);
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.055);
}
.provider-badge {
  min-width: 30px;
  min-height: 30px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.09);
  font-size: 12px;
  font-weight: 800;
}
.provider-name {
  font-size: 15px;
  font-weight: 700;
}
.credits-label.credits-warning, .credits-value.credits-warning { color: #ff9e64; }
.credits-label.credits-critical, .credits-value.credits-critical { color: #f7768e; }
.usage-label, .usage-value, .delta-value, .credits-label, .credits-value {
  color: #c5c5cb;
  font-size: 12px;
  font-weight: 650;
}
.usage-value, .delta-value, .credits-value {
  font-family: monospace;
}
.delta-value {
  margin-right: 6px;
  font-size: 10px;
}
.delta-positive { color: #3ddc84; }
.delta-warning { color: #ff9e64; }
.delta-critical { color: #f7768e; }
.expected-label, .expected-value, .reset-label, .updated-label, .detail-label {
  color: #777780;
  font-size: 11px;
}
.expected-value, .reset-label, .updated-label, .detail-label {
  font-family: monospace;
}
.detail-error { color: #f7768e; }
.access-status {
  color: #ff9e64;
  font-size: 11px;
  font-weight: 650;
}
.access-status-critical { color: #f7768e; }
progressbar {
  min-height: 6px;
}
progressbar > trough {
  min-height: 6px;
  border: 0;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
}
progressbar > trough > progress {
  min-width: 0;
  min-height: 6px;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: 999px;
  background: #7aa2f7;
}
progressbar.severity-warning > trough > progress { background: #ff9e64; }
progressbar.severity-critical > trough > progress,
progressbar.severity-error > trough > progress { background: #f7768e; }
progressbar.comparison-green > trough > progress { background: #3ddc84; }
progressbar.comparison-warning > trough > progress { background: #ff9e64; }
progressbar.comparison-critical > trough > progress { background: #f7768e; }
progressbar.comparison-neutral > trough {
  background: transparent;
}
progressbar.comparison-neutral > trough > progress { background: #8b8b94; }
.notification-button,
menubutton.notification-button > button {
  min-height: 20px;
  padding: 0 3px;
  border: 0;
  border-radius: 5px;
  box-shadow: none;
  background: transparent;
  color: #666670;
}
.notification-button:hover,
menubutton.notification-button > button:hover {
  background: rgba(255, 255, 255, 0.025);
}
.notification-summary {
  color: #666670;
  font-size: 10px;
}
.notice-neutral { color: #777780; }
.notice-warning { color: #ff9e64; }
.notice-critical { color: #f7768e; }
popover.notification-popover > contents,
popover.notification-popover > arrow {
  background: rgba(22, 22, 25, 0.99);
  border-color: rgba(255, 255, 255, 0.10);
}
popover.notification-popover > contents {
  border-radius: 12px;
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.36);
}
.notification-heading {
  font-size: 12px;
  font-weight: 700;
}
.notification-row {
  padding: 1px 0;
}
.notification-title {
  color: #d4d4d8;
  font-size: 11px;
  font-weight: 650;
}
.notification-copy {
  color: #777780;
  font-size: 10px;
}
.notification-dismiss {
  min-height: 18px;
  margin-top: 2px;
  padding: 0 2px;
  border: 0;
  box-shadow: none;
  background: transparent;
  color: #777780;
  font-size: 10px;
}
.notification-dismiss:hover {
  background: transparent;
  color: #a1a1aa;
}
.notification-action {
  min-height: 22px;
  padding: 2px 7px;
  border-radius: 6px;
}
.popover-title {
  font-size: 13px;
  font-weight: 700;
}
.popover-copy {
  color: #a1a1aa;
  font-size: 11px;
}
.reconnect-button {
  margin-top: 4px;
  padding: 5px 10px;
  border-radius: 7px;
}
.loading-label {
  color: #a1a1aa;
  font-size: 12px;
}
.error-banner {
  color: #f7768e;
  font-size: 11px;
}
"""


def find_bun():
    override = os.environ.get("CLAUDEXBAR_BUN")
    candidates = [override, str(Path.home() / ".bun/bin/bun"), shutil.which("bun")]
    return next((candidate for candidate in candidates if candidate and os.access(candidate, os.X_OK)), None)


def find_engine():
    override = os.environ.get("CLAUDEXBAR_ENGINE")
    candidates = [override, str(Path(__file__).with_name("claudexbar.ts"))]
    return next((candidate for candidate in candidates if candidate and Path(candidate).is_file()), None)


def compact_label(label):
    return {
        "Cursor Models (Monthly)": "Cursor monthly",
        "Other Models (Monthly)": "Other monthly",
        "GrokBot (Weekly)": "GrokBot weekly",
    }.get(label, label)


def format_number(value):
    number = float(value)
    return str(int(number)) if number.is_integer() else f"{number:.1f}"


def updated_text(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
        return parsed.strftime("%I:%M %p").lstrip("0")
    except (TypeError, ValueError):
        return None


def provider_details(payload):
    rows = payload.get("usageRows") or []
    labels = {row.get("label") for row in rows}
    details = []
    unavailable_quotas = []
    for line in str(payload.get("tooltip") or "").splitlines():
        trimmed = line.strip()
        if trimmed == "Session unavailable":
            unavailable_quotas.append("Session")
            continue
        if trimmed in ("Week unavailable", "Weekly unavailable"):
            unavailable_quotas.append("Weekly")
            continue
        if trimmed == "Cursor monthly unavailable":
            unavailable_quotas.append("Cursor monthly")
            continue
        if trimmed == "Other monthly unavailable":
            unavailable_quotas.append("Other monthly")
            continue
        if line.startswith("Updated:") or line.startswith("Credits "):
            continue
        if line.startswith("Session ") and "Session" in labels:
            continue
        if line.startswith("Week ") and any("Weekly" in str(label) for label in labels):
            continue
        if trimmed:
            details.append(trimmed)
    return "\n".join(details[:3]), unavailable_quotas

def expiry_urgency(expires_at, now=None):
    if not isinstance(expires_at, (int, float)) or not math.isfinite(expires_at):
        return None
    remaining = float(expires_at) - (time.time() if now is None else now)
    if remaining <= 7 * 24 * 60 * 60:
        return "critical"
    if remaining <= 14 * 24 * 60 * 60:
        return "warning"
    return None


def reset_credit_urgency(details, now=None):
    urgencies = [
        expiry_urgency(detail.get("expiresAt"), now)
        for detail in (details or [])
        if isinstance(detail, dict)
    ]
    if "critical" in urgencies:
        return "critical"
    if "warning" in urgencies:
        return "warning"
    return None


def expiry_text(expires_at):
    if not isinstance(expires_at, (int, float)) or not math.isfinite(expires_at):
        return "Expiry unavailable"
    return datetime.fromtimestamp(expires_at).strftime("Expires %b %d at %I:%M %p").replace(" 0", " ")


def info_menu(title, lines, tooltip):
    button = Gtk.MenuButton()
    button.set_icon_name("dialog-information-symbolic")
    button.set_tooltip_text(tooltip)
    button.add_css_class("icon-button")

    popover = Gtk.Popover()
    content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    content.set_margin_top(12)
    content.set_margin_bottom(12)
    content.set_margin_start(12)
    content.set_margin_end(12)

    title_label = Gtk.Label(label=title, xalign=0)
    title_label.add_css_class("popover-title")
    content.append(title_label)
    for line in lines:
        label = Gtk.Label(label=line, xalign=0, wrap=True)
        label.set_max_width_chars(38)
        label.add_css_class("popover-copy")
        content.append(label)

    popover.set_child(content)
    button.set_popover(popover)
    return button


class ProviderCard(Gtk.Box):
    def __init__(self, provider, reconnect):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.provider = provider
        self.reconnect = reconnect
        self.compact = False
        self.add_css_class("provider-card")
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.render(None)

    def clear(self):
        child = self.get_first_child()
        while child is not None:
            next_child = child.get_next_sibling()
            self.remove(child)
            child = next_child

    def render(self, entry):
        self.clear()
        self.compact = False
        self.remove_css_class("access-card")
        self.add_css_class("provider-card")
        self.set_vexpand(True)
        badge, name = PROVIDERS[self.provider]

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        badge_label = Gtk.Label(label=badge)
        badge_label.add_css_class("provider-badge")
        header.append(badge_label)
        name_label = Gtk.Label(label=name, xalign=0)
        name_label.add_css_class("provider-name")
        header.append(name_label)
        self.append(header)

        if entry is None:
            loading = Gtk.Label(label="Loading usage…", xalign=0)
            loading.add_css_class("detail-label")
            self.append(loading)
            self.append(Gtk.Box(vexpand=True))
            return

        payload = entry.get("payload") or {}
        rows = payload.get("usageRows") or []
        access_state = payload.get("accessState")
        access_label, shows_login, critical_access = ACCESS_PRESENTATION.get(
            access_state,
            ACCESS_PRESENTATION["unavailable"],
        )
        if access_label:
            status = Gtk.Label(label=access_label, xalign=0, wrap=True)
            status.add_css_class("access-status")
            if critical_access:
                status.add_css_class("access-status-critical")
            self.append(status)
        if access_state not in ("available", "stale"):
            self.compact = True
            self.remove_css_class("provider-card")
            self.add_css_class("access-card")
            self.set_vexpand(False)
            if shows_login:
                button = Gtk.Button(label="Login")
                button.add_css_class("reconnect-button")
                button.connect("clicked", lambda _button: self.reconnect(self.provider))
                self.append(button)
            return


        if rows:
            for row in rows:
                self.append(self.usage_row(row))
        elif payload.get("percentage") is not None:
            self.append(self.usage_row({
                "label": payload.get("percentageLabel") or "Usage",
                "percentage": payload["percentage"],
                "severity": self.payload_severity(payload),
            }))

        if payload.get("resetCredits") is not None:
            credits = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            credits_label = Gtk.Label(label="Reset credits", xalign=0, hexpand=True)
            credits_label.add_css_class("credits-label")
            credit_urgency = reset_credit_urgency(payload.get("resetCreditDetails"))
            if credit_urgency:
                credits_label.add_css_class(f"credits-{credit_urgency}")
            credits.append(credits_label)
            credits_value = Gtk.Label(label=format_number(payload["resetCredits"]), xalign=1)
            credits_value.add_css_class("credits-value")
            if credit_urgency:
                credits_value.add_css_class(f"credits-{credit_urgency}")
            credits.append(credits_value)
            self.append(credits)

        detail, _unavailable_quotas = provider_details(payload)
        if detail and access_state not in ("login_required", "subscription_expired"):
            detail_label = Gtk.Label(label=detail, xalign=0, wrap=True)
            detail_label.set_lines(3)
            detail_label.add_css_class("detail-label")
            if self.payload_severity(payload) == "error":
                detail_label.add_css_class("detail-error")
            self.append(detail_label)


        self.append(Gtk.Box(vexpand=True))
        timestamp = updated_text(payload.get("updatedAt"))
        if timestamp:
            updated = Gtk.Label(label=f"Updated {timestamp}", xalign=0)
            updated.add_css_class("updated-label")
            self.append(updated)

    @staticmethod
    def payload_severity(payload):
        classes = payload.get("class")
        if isinstance(classes, str):
            classes = [classes]
        classes = classes or []
        return next((value for value in ("error", "critical", "warning", "stale") if value in classes), "normal")

    def usage_row(self, row):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        actual = float(row.get("percentage", 0))
        pacing = row.get("pacing")
        expected = (
            float(pacing["expectedPercentage"])
            if isinstance(pacing, dict) and pacing.get("expectedPercentage") is not None
            else None
        )

        if expected is not None:
            expected_heading = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            expected_label = Gtk.Label(label="Expected", xalign=0, hexpand=True)
            expected_label.add_css_class("expected-label")
            expected_heading.append(expected_label)
            expected_value = Gtk.Label(label=f"{format_number(expected)}%", xalign=1)
            expected_value.add_css_class("expected-value")
            expected_heading.append(expected_value)
            box.append(expected_heading)
            box.append(self.comparison_meter(actual, expected, "expected"))

        heading = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        label = Gtk.Label(label=compact_label(str(row.get("label") or "Usage")), xalign=0, hexpand=True)
        label.set_ellipsize(3)
        label.add_css_class("usage-label")
        heading.append(label)
        if expected is not None and actual != expected:
            delta = expected - actual
            delta_value = Gtk.Label(
                label=f"{'+' if delta > 0 else '−'}{format_number(abs(delta))}%",
                xalign=1,
            )
            delta_value.add_css_class("delta-value")
            delta_value.add_css_class(
                "delta-positive"
                if delta > 0
                else "delta-critical"
                if actual - expected >= 10
                else "delta-warning"
            )
            heading.append(delta_value)
        value = Gtk.Label(label=f"{format_number(actual)}%", xalign=1)
        value.add_css_class("usage-value")
        heading.append(value)
        box.append(heading)
        if expected is None:
            box.append(self.progress(actual, row.get("severity") or "normal"))
        else:
            box.append(self.comparison_meter(actual, expected, "actual"))

        if row.get("resetText"):
            reset = Gtk.Label(label=f"Resets {row['resetText']}", xalign=0)
            reset.add_css_class("reset-label")
            box.append(reset)
        return box

    @staticmethod
    def progress(value, style):
        bar = Gtk.ProgressBar()
        bar.set_fraction(max(0, min(100, float(value))) / 100)
        bar.add_css_class(f"severity-{style}")
        return bar

    @staticmethod
    def comparison_meter(actual, expected, target):
        actual = max(0, min(100, float(actual)))
        expected = max(0, min(100, float(expected)))
        common = min(actual, expected)
        highlighted = expected if target == "expected" else actual
        style = (
            "green"
            if target == "expected"
            else "critical"
            if actual - expected >= 10
            else "warning"
        )

        meter = Gtk.Overlay()
        highlight = Gtk.ProgressBar()
        highlight.set_fraction(highlighted / 100)
        highlight.add_css_class(f"comparison-{style}")
        meter.set_child(highlight)

        neutral = Gtk.ProgressBar()
        neutral.set_fraction(common / 100)
        neutral.add_css_class("comparison-neutral")
        meter.add_overlay(neutral)
        return meter


class DashboardWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="ClaudexBar")
        self.app = app
        self.cards = {}
        self.refreshing = False
        self.has_payload = False
        try:
            self.dismissed_notification_signature = NOTIFICATION_DISMISSAL_PATH.read_text().strip()
        except OSError:
            self.dismissed_notification_signature = ""
        self.current_notification_signature = ""
        self.latest_entries = {}
        self.set_default_size(620, 450)
        self.set_resizable(False)
        self.add_css_class("claudexbar-window")

        if Gtk4LayerShell is not None:
            self.set_decorated(False)
            Gtk4LayerShell.init_for_window(self)
            Gtk4LayerShell.set_namespace(self, "claudexbar-dashboard")
            Gtk4LayerShell.set_layer(self, Gtk4LayerShell.Layer.OVERLAY)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.TOP, True)
            Gtk4LayerShell.set_anchor(self, Gtk4LayerShell.Edge.RIGHT, True)
            Gtk4LayerShell.set_margin(self, Gtk4LayerShell.Edge.TOP, 10)
            Gtk4LayerShell.set_margin(self, Gtk4LayerShell.Edge.RIGHT, 10)
            Gtk4LayerShell.set_keyboard_mode(self, Gtk4LayerShell.KeyboardMode.ON_DEMAND)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        root.add_css_class("claudexbar-root")
        self.set_child(root)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        title = Gtk.Label(label="ClaudexBar", xalign=0)
        title.add_css_class("app-title")
        header.append(title)
        header.append(info_menu(
            "Usage pacing",
            [
                "Expected shows where usage would be at an even pace through the current quota window.",
                "Green is capacity remaining before expected.",
                "Orange is slightly above expected.",
                "Red is 10 points or more above expected.",
                "+  Below expected",
                "−  Above expected",
            ],
            "How usage pacing works",
        ))
        header.append(Gtk.Box(hexpand=True))
        self.refresh_button = Gtk.Button(icon_name="view-refresh-symbolic")
        self.refresh_button.set_tooltip_text("Refresh all providers")
        self.refresh_button.add_css_class("icon-button")
        self.refresh_button.connect("clicked", lambda _button: self.refresh())
        header.append(self.refresh_button)
        root.append(header)

        self.content_stack = Gtk.Stack()
        self.content_stack.set_vexpand(True)

        loading = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        loading.set_halign(Gtk.Align.CENTER)
        loading.set_valign(Gtk.Align.CENTER)
        self.loading_spinner = Gtk.Spinner(spinning=True)
        loading.append(self.loading_spinner)
        self.loading_label = Gtk.Label(label="Loading usage…")
        self.loading_label.add_css_class("loading-label")
        loading.append(self.loading_label)
        self.content_stack.add_named(loading, "loading")

        cards = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        cards.set_vexpand(True)
        self.usage_cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, homogeneous=True)
        self.usage_cards.set_vexpand(True)
        cards.append(self.usage_cards)
        for provider in PROVIDERS:
            card = ProviderCard(provider, self.launch_reconnect)
            self.cards[provider] = card
            self.usage_cards.append(card)
        self.content_stack.add_named(cards, "cards")
        self.content_stack.set_visible_child_name("loading")
        root.append(self.content_stack)

        self.error_label = Gtk.Label(xalign=0, wrap=True)
        self.error_label.add_css_class("error-banner")
        self.error_label.set_visible(False)
        root.append(self.error_label)

        self.notification_button = Gtk.MenuButton()
        self.notification_button.set_hexpand(True)
        self.notification_button.add_css_class("notification-button")
        self.notification_button.set_tooltip_text("Open notifications")
        self.notification_button.set_visible(False)
        notification_summary = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        self.notification_count_label = Gtk.Label(xalign=0)
        self.notification_count_label.add_css_class("notification-summary")
        notification_summary.append(self.notification_count_label)
        notification_summary.append(Gtk.Box(hexpand=True))
        notification_open = Gtk.Label(label="Open")
        notification_open.add_css_class("notification-summary")
        notification_summary.append(notification_open)
        notification_summary.append(Gtk.Image.new_from_icon_name("pan-up-symbolic"))
        self.notification_button.set_child(notification_summary)
        root.append(self.notification_button)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.on_key_pressed)
        self.add_controller(keys)
        GLib.timeout_add_seconds(300, self.periodic_refresh)
        self.refresh()

    def on_key_pressed(self, _controller, keyval, _keycode, state):
        if keyval == 65307:
            self.close()
            return True
        if keyval in (ord("r"), ord("R")) and state & 4:
            self.refresh()
            return True
        return False

    def periodic_refresh(self):
        self.refresh()
        return GLib.SOURCE_CONTINUE

    def refresh(self):
        if self.refreshing:
            return
        self.refreshing = True
        self.refresh_button.set_sensitive(False)
        self.error_label.set_visible(False)
        self.loading_label.set_label("Loading usage…")
        self.loading_spinner.start()
        self.content_stack.set_visible_child_name("loading")
        started_at = time.monotonic()
        threading.Thread(target=self.load_payload, args=(started_at,), daemon=True).start()

    def load_payload(self, started_at):
        bun = find_bun()
        engine = find_engine()
        if bun is None:
            self.finish_after_minimum_delay(
                started_at,
                self.finish_error,
                "Bun was not found. Set CLAUDEXBAR_BUN or install Bun.",
            )
            return
        if engine is None:
            self.finish_after_minimum_delay(
                started_at,
                self.finish_error,
                "claudexbar.ts was not found beside the dashboard.",
            )
            return
        try:
            result = subprocess.run(
                [bun, engine, "--all"],
                check=True,
                capture_output=True,
                text=True,
                timeout=45,
            )
            aggregate = json.loads(result.stdout)
            providers = aggregate.get("providers")
            if not isinstance(providers, list):
                raise ValueError("aggregate payload has no providers list")
            self.finish_after_minimum_delay(started_at, self.finish_refresh, providers)
        except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as error:
            self.finish_after_minimum_delay(started_at, self.finish_error, f"Refresh failed: {error}")

    @staticmethod
    def finish_after_minimum_delay(started_at, callback, value):
        remaining = 1 - (time.monotonic() - started_at)
        if remaining > 0:
            time.sleep(remaining)
        GLib.idle_add(callback, value)

    def update_notification_center(self, entries):
        notices = []
        for provider in PROVIDERS:
            entry = entries.get(provider) or {}
            payload = entry.get("payload") or {}
            state = payload.get("accessState")
            if state not in ACCESS_PRESENTATION:
                state = "unavailable"
            if state not in ("available", "stale"):
                _badge, name = PROVIDERS[provider]
                notices.append({
                    "tone": "critical" if ACCESS_PRESENTATION[state][2] else "neutral",
                    "title": name,
                    "message": ACCESS_PRESENTATION[state][0],
                    "login_provider": provider if ACCESS_PRESENTATION[state][1] else None,
                })

        for provider in PROVIDERS:
            entry = entries.get(provider) or {}
            payload = entry.get("payload") or {}
            if payload.get("accessState") not in ("available", "stale"):
                continue
            _detail, unavailable_quotas = provider_details(payload)
            _badge, name = PROVIDERS[provider]
            for quota in unavailable_quotas:
                notices.append({
                    "tone": "neutral",
                    "title": f"{name} {quota.lower()} usage",
                    "message": "Unavailable from the provider response.",
                    "login_provider": None,
                })
            for detail in payload.get("resetCreditDetails") or []:
                if not isinstance(detail, dict):
                    continue
                urgency = expiry_urgency(detail.get("expiresAt"))
                if urgency is None:
                    continue
                notices.append({
                    "tone": urgency,
                    "title": f"{name} reset credit",
                    "message": expiry_text(detail.get("expiresAt")),
                    "login_provider": None,
                })

        signature = json.dumps(notices, sort_keys=True, separators=(",", ":"))
        self.current_notification_signature = signature
        if not notices:
            self.dismissed_notification_signature = ""
            try:
                NOTIFICATION_DISMISSAL_PATH.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass
            self.notification_button.set_visible(False)
            return
        if (
            self.dismissed_notification_signature
            and signature != self.dismissed_notification_signature
        ):
            self.dismissed_notification_signature = ""
            try:
                NOTIFICATION_DISMISSAL_PATH.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass


        if signature == self.dismissed_notification_signature:
            self.notification_button.set_visible(False)
            return

        popover = Gtk.Popover()
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        content.set_margin_top(14)
        content.set_margin_bottom(14)
        popover.add_css_class("notification-popover")
        content.set_margin_start(14)
        content.set_margin_end(14)

        title = Gtk.Label(label="Notifications", xalign=0)
        title.add_css_class("notification-heading")
        content.append(title)

        for notice in notices:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.add_css_class("notification-row")
            marker = Gtk.Label(label="•")
            marker.set_valign(Gtk.Align.START)
            marker.add_css_class(f"notice-{notice['tone']}")
            row.append(marker)

            copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, hexpand=True)
            name_label = Gtk.Label(label=notice["title"], xalign=0)
            name_label.add_css_class("notification-title")
            copy.append(name_label)
            message = Gtk.Label(label=notice["message"], xalign=0, wrap=True)
            message.set_max_width_chars(38)
            message.add_css_class("notification-copy")
            copy.append(message)
            row.append(copy)

            if notice["login_provider"]:
                login = Gtk.Button(label="Login")
                login.add_css_class("notification-action")
                login.connect(
                    "clicked",
                    lambda _button, selected=notice["login_provider"]: self.launch_reconnect(selected),
                )
                row.append(login)
            content.append(row)

        dismiss = Gtk.Button(label="Clear notifications")
        dismiss.set_halign(Gtk.Align.END)
        dismiss.add_css_class("notification-dismiss")
        dismiss.connect("clicked", lambda _button: self.dismiss_notifications(popover))
        content.append(dismiss)

        popover.set_child(content)
        self.notification_button.set_popover(popover)
        count = len(notices)
        self.notification_count_label.set_label(
            f"{count} {'notice' if count == 1 else 'notices'}"
        )
        self.notification_button.set_visible(True)

    def dismiss_notifications(self, popover):
        self.dismissed_notification_signature = self.current_notification_signature
        try:
            NOTIFICATION_DISMISSAL_PATH.parent.mkdir(parents=True, exist_ok=True)
            NOTIFICATION_DISMISSAL_PATH.write_text(self.dismissed_notification_signature + "\n")
        except OSError:
            pass
        popover.popdown()
        self.update_notification_center(self.latest_entries)

    def finish_refresh(self, providers):
        entries = {entry.get("provider"): entry for entry in providers if isinstance(entry, dict)}
        self.latest_entries = entries
        self.update_notification_center(entries)
        usage_count = 0
        for provider, card in self.cards.items():
            parent = card.get_parent()
            if parent is not None:
                parent.remove(card)
            card.render(entries.get(provider))
            if not card.compact:
                self.usage_cards.append(card)
                usage_count += 1
        self.usage_cards.set_visible(usage_count > 0)
        self.has_payload = True
        self.loading_spinner.stop()
        self.content_stack.set_visible_child_name("cards")
        self.refreshing = False
        self.refresh_button.set_sensitive(True)
        return GLib.SOURCE_REMOVE

    def finish_error(self, message):
        self.error_label.set_label(message)
        self.error_label.set_visible(True)
        self.loading_spinner.stop()
        if self.has_payload:
            self.content_stack.set_visible_child_name("cards")
        else:
            self.loading_label.set_label("Usage unavailable")
        self.refreshing = False
        self.refresh_button.set_sensitive(True)
        return GLib.SOURCE_REMOVE

    def launch_reconnect(self, provider):
        bun = find_bun()
        engine = find_engine()
        commands = {
            "claude": ["claude", "auth", "login"],
            "codex": ["codex", "login"],
            "grok": [bun, engine, "--login", "grok"] if bun and engine else None,
        }
        command = commands.get(provider)
        terminal = shutil.which("xdg-terminal-exec")
        if command is None or terminal is None:
            self.finish_error("Login requires xdg-terminal-exec and the provider CLI.")
            return
        try:
            process = subprocess.Popen([terminal, *command], start_new_session=True)
            threading.Thread(target=self.refresh_after_process, args=(process,), daemon=True).start()
        except OSError as error:
            self.finish_error(f"Could not start login: {error}")

    def refresh_after_process(self, process):
        process.wait()
        GLib.idle_add(self.refresh)


class DashboardApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.github.andresreibel.ClaudexBar.Linux")
        self.window = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(
            self.get_default_display(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )
        self.set_accels_for_action("app.quit", ["Escape"])
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda _action, _value: self.quit())
        self.add_action(quit_action)

    @staticmethod
    def get_default_display():
        from gi.repository import Gdk

        return Gdk.Display.get_default()

    def do_activate(self):
        if self.window is not None:
            self.window.close()
            self.quit()
            return
        self.window = DashboardWindow(self)
        self.window.connect("destroy", lambda _window: self.quit())
        self.window.present()


if __name__ == "__main__":
    raise SystemExit(DashboardApp().run(sys.argv))
