# Changelog

Newest first. Each version has up to three sections: New, Changed, Fixed. The release button builds each GitHub release's description from this file.

## 1.2.1

### Changed
- Enemies are spotted farther away: nameplates now appear as far away as the game allows (the addon asks for 100 yards and the game sets its own limit). Turn it off in the options and your own setting comes back. `/kos status` shows the range you have.
- A new enemy is picked up the moment their nameplate appears. If the game hasn't filled in their name yet, the addon looks again every frame instead of five times a second.

## 1.2.0

### New
- Kain-UI Forever now has the kill list built in (K-UI 1.0.347 and later). If you have both, K-UI's copy runs and this addon stays asleep, so you never get two warnings or two nearby windows. On its first login K-UI brings over your list, your wins and losses, your settings and where you put the windows.
- `/kos off` turns K-UI's kill list off and hands the job back to this addon after a reload; `/kos on` turns it back on.

### Fixed
- Logging in during combat no longer blocks the nearby window: its rows are made once combat ends.

## 1.1.0

### New
- **Recently Seen** page in `/kos` (or `/kos seen`): every enemy player you've come across, newest first, with where you last saw them, how often, and your wins and losses against them. It's kept between sessions and builds up over time.
- Your record against each enemy (wins and losses) shows when you hover them in the nearby window, on their tooltip, and next to their name. Hover the nearby window itself for your overall record.
- Wins: an enemy player you were fighting dies, or the game gives you an honourable kill for them. Losses: you die while an enemy player was attacking you.
- Spy's alert sounds: one for someone on the kill list, one when a guildmate spots someone on it, one for any new enemy nearby (can be turned off in the options), and sounds for adding and removing players.
- `/kos plates` and an options button to turn on enemy nameplates, which spot enemies as soon as they're in range. You get a reminder at login if they're off.

### Changed
- The nearby window is now called **Horde Scum Nearby**.
- Enemies are spotted faster: nameplates, your target, focus, mouseover and your target's target are checked five times a second, and your party's and raid's targets every second.

## 1.0.0

### New
- First release.
- A kill-on-sight list for Better Homes & Gardens, shared with every guild member who has the addon. Anything added or removed reaches everyone online straight away, and anyone who was offline catches up a few seconds after logging in.
- A warning (banner, sound and a line in chat) when someone on the list shows up near you, and the guild is told where you spotted them.
- A nearby window listing the enemy players around you, with listed ones on top in red. Left-click a name to target them, right-click to add or remove them.
- Add players from the right-click menu on their name or portrait, with `/kos add`, or from the list window. Each entry keeps a reason, who added it and when, and where they were last seen.
- Listed players show "Kill on sight" and the reason on their tooltip.
- `/kos` opens the list: search, edit reasons, remove players, and options.
