# vitalog-notify-ntfy

A small bash notifier that watches [vitalog](https://github.com/adrianschmidt/vitalog) reminders and pushes one [ntfy.sh](https://ntfy.sh) notification per reminder when one flips from `due: false` to `due: true`. Runs every 15 minutes on macOS via launchd.

- Edge-triggered: one ping per `false → true` transition, no spam.
- Daily reset: a perpetually-overdue reminder pings exactly once per vitalog effective day until you log it.
- Phone-side quiet hours: the notifier fires whenever a reminder flips; your phone's bedtime / DND mode decides whether to wake you.
- No external service beyond the public `ntfy.sh` server and your phone's ntfy app.

## Notification content

Each notification's **title** is the reminder's name. Its **body** reflects the
`streak` and `days_past_due` that `vitalog status` reports for that reminder:

- On the day a reminder becomes due — its streak's at-risk day — the body reads
  `🔥 6 day streak! Don't break it now.`
- On later days it's still not done, the body counts up:
  `⏰ 1 day overdue — jump back in!`, `⏰ 2 days overdue — jump back in!`, …
- If a reminder has neither enabled (or you're on an older vitalog), the body is
  empty and you get the title-only notification as before.

This layer is a **pure renderer** — whether a reminder shows a streak or a
days-past-due count is controlled entirely by that reminder's `show_streak` /
`show_days_past_due` in your **vitalog** config, surfaced as `null` in the JSON
when off. There is no configuration in this repo for it.

## Requirements

- macOS with `launchd` (works on any modern macOS).
- `vitalog` on `$PATH`. Reminders need ≥ 1.2 (`[reminders]` + time gates); the
  streak / days-past-due notification bodies need the release that adds `streak`
  and `days_past_due` to `vitalog status` (≥ 1.5). Older versions still work —
  the body is simply empty (title-only pings).
- `jq` — `brew install jq` if you don't have it.
- An Android phone with the [ntfy app](https://docs.ntfy.sh/subscribe/phone/) installed (Play Store or F-Droid). Also works on iOS via [ntfy on the App Store](https://apps.apple.com/us/app/ntfy/id1625396347).

## Setup

1. **Pick a topic on ntfy.sh.** Any long random string — treat it as a shared secret. Anyone with the URL can read your reminders or write to your topic.

   ```
   https://ntfy.sh/<long-random-string-here>
   ```

2. **Subscribe to the topic on your phone.** Open the ntfy app, tap "Subscribe to topic", paste your topic name (just the slug, not the full URL). The phone is now ready to receive.

3. **Clone this repo next to your vitalog clone.**

   ```bash
   cd ~/src/adrianschmidt/vitalog-workspace
   git clone https://github.com/adrianschmidt/vitalog-notify-ntfy.git
   cd vitalog-notify-ntfy
   ```

4. **Install.**

   ```bash
   ./install.sh
   ```

   This creates `~/.config/vitalog-notify/`, seeds a config template, renders the launchd plist into `~/Library/LaunchAgents/com.vitalog-notify.plist`, and bootstraps the launchd job.

5. **Edit the config.** The installer wrote a placeholder topic URL:

   ```bash
   vi ~/.config/vitalog-notify/config
   ```

   Set `NTFY_TOPIC_URL` to your real topic. The next launchd tick (≤ 15 minutes later) picks up the change.
   The installer sets `~/.config/vitalog-notify/config` to mode `0600` (your eyes only); keep it that way after editing.

## Testing it works

1. **Send a test push directly.** From the host running the notifier:

   ```bash
   source ~/.config/vitalog-notify/config
   curl -fsS -H "Title: hello" -d "" "$NTFY_TOPIC_URL"
   ```

   Your phone should buzz with a "hello" notification. If it doesn't, the problem is between the host and ntfy.sh (or between ntfy.sh and your phone — open the ntfy app and check the topic is subscribed).

2. **Dry-run the notifier.**

   ```bash
   ./notify.sh --dry-run
   ```

   Prints `would ping (N):` followed by `  - <id>: <display> | <body>` lines for
   each reminder currently due (the `| <body>` suffix is omitted when the
   reminder has no streak/overdue text). No POST, no state write. Use this to
   verify your `[reminders]` config and the rendered message text.

3. **Watch the logs.**

   ```bash
   tail -f ~/Library/Logs/vitalog-notify.log
   ```

   Every 15 minutes you should see a line per ping (or silence if nothing's due). Errors land here too.

## How the daily reset interacts with `day_start_hour`

If you've set `day_start_hour` in your vitalog config (e.g. `4`), the notifier respects it because it reads `effective_date` from `vitalog status`. With `day_start_hour = 4`, the daily reset fires at 04:00 wall-clock (which is when the effective date rolls). A perpetually-overdue reminder gets its first re-ping of the day at the next launchd tick after 04:00.

If your phone's bedtime mode covers 04:00 (likely!) the notification is held silently until morning, exactly as you'd want.

## Uninstall

```bash
./install.sh --uninstall
```

Boots the job out of launchd and removes the plist. Your `~/.config/vitalog-notify/config` and `~/.config/vitalog-notify/state.json` are left in place — re-installing later picks up where you left off.

To fully wipe:

```bash
rm -rf ~/.config/vitalog-notify
rm -f ~/Library/Logs/vitalog-notify.log
```

## Migrating to a self-hosted ntfy server

The notifier doesn't care about the server. Run [ntfy](https://docs.ntfy.sh/install/) anywhere reachable from your phone, edit `NTFY_TOPIC_URL` in `~/.config/vitalog-notify/config` to point at the new URL, and point the ntfy phone app at the new server. No script changes.

## Running the tests

```bash
bash tests/run_tests.sh
```

The tests cover the pure `diff_state` function across 8 cases. The outer flow (config sourcing, vitalog invocation, curl, state I/O, error handling) is exercised via `--dry-run` and the manual setup steps above.
