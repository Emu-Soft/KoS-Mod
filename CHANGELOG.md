# Changelog

Newest first. Each version has up to three sections: New, Changed, Fixed. The release button builds each GitHub release's description from this file.

## 1.4.0

### New
- A guild Blacklist, for players on our own side you'd rather not group with: people who leave dungeons early, ninja loot and so on. It's a list of its own, so nobody on it is treated as an enemy and the kill list stays exactly as it was.
- To blacklist someone: right-click a group member's portrait or their name in chat and pick "Add to the guild Blacklist", target them and type `/kos black`, use the new **Blacklist** page in `/kos`, or type `/kos black Name a reason`.
- When someone leaves your dungeon group, a box comes up a few seconds later asking whether to blacklist them, with "Left (dungeon) early" filled in. The game doesn't say why someone left or whether they were removed, so it only ever asks: nobody is added unless you say yes. If two people leave close together, as at the end of a run, it doesn't ask.
- When someone on the Blacklist is in your group, joins it or invites you, you get an orange BLACKLISTED warning with their reason. The Blacklist plays no sounds. When they whisper you or talk in a channel such as LookingForGroup, you get a line in chat. Their tooltip shows it too.
- The Blacklist is shared with the guild like the kill list: an add, a new reason or a removal reaches everyone online straight away, and anyone offline catches up when they log in. Anyone can take someone off it for everyone.
- Enemies can't go on the Blacklist (use the kill list) and neither can guildmates. It works the same whichever side your guild is on.
- New options: the group and invite warnings, the chat lines, and the question when someone leaves your dungeon group can each be turned off.
- `/kos check` and `/kos status` include the Blacklist.
- Guildmates on 1.3.0 or older keep syncing the kill list and guilds with you as before; they just don't get the Blacklist until they update.

### Changed
- Players are shown by their full WoW: Forever name, with their realm ("Name Realm"), everywhere in the addon: the lists, Horde Scum Nearby, warnings, chat lines, tooltips and pop-ups, for players from your own realm too. "Added by" and "spotted by" show full names as well. Clicking a name to target them works as before.
- The Horde Scum Nearby window is a little wider to fit the longer names.

## 1.3.0

### New
- Whole guilds can go on the kill list. Every member of a listed guild you come across counts as kill on sight: the warning, the red row at the top of Horde Scum Nearby, and "Kill on sight" on their tooltip, with the guild's reason.
- To add a guild: right-click one of its members (their portrait, or their row in Horde Scum Nearby) and pick "Add the whole guild", target one and type `/kos guild`, click **Add guild** in `/kos`, or type `/kos guild add Guild Name: a reason`.
- Listed guilds show at the top of the kill list with their reason, who added them and how many of their members you've seen. Edit and Remove work like they do for players. `/kos guilds` lists them in chat.
- Guilds are shared with the guild like players are: an add, a new reason or a removal reaches everyone online straight away, and anyone offline catches up when they log in.
- When a group of the same guild shows up, you get the banner and the sound once a minute for that guild, and a line in chat for each member, so a raid of them doesn't drown you out.
- Members of a listed guild aren't announced to the guild when you spot them (only players on the list one by one are), so a whole guild passing by doesn't fill everyone's chat.
- The game doesn't let addons look up who is in an enemy guild, so a member is only recognised once you see them and the game shows their guild. A player who leaves the guild stops counting; anyone who joins counts from the moment you see them.
- Your own guild, and any guild seen on our side, can't be put on the list. Someone on our side whose guild has the same name as a listed one doesn't set it off.
- The kill list window shows the addon's version next to the player count, in Kain-UI Forever too, so it's easy to see who needs to update. `/kos status` shows it as well.
- Guildmates on 1.2.5 or older keep syncing players with you as before; they just don't get the guilds until they update.

## 1.2.5

### New
- The Horde Scum Nearby window puts itself away when you go into a dungeon or raid, and comes back when you leave. It stays up in battlegrounds, arenas and the open world. If you closed it yourself, leaving a dungeon doesn't bring it back. To keep it up in dungeons too, untick "Hide the nearby window in dungeons and raids" in `/kos options`.
- Guild sync keeps running while you're in a dungeon, so your list is up to date when you come out. `/kos status` says when the window is hidden for a dungeon.

## 1.2.4

### Changed
- A guildmate spotting someone on the kill list no longer plays a sound. You still get the line in chat saying who spotted them and where. The warning sound now only plays for listed players near you.

## 1.2.3

### Fixed
- Players on your own side can't be put on the kill list any more: not from your target, the right-click menu, the nearby window or `/kos add`. By name, the addon checks your guild, your group and anyone it has seen on your side this session.
- Someone on your side who is already on the list (added with an older version) no longer sets off a warning. You get one note in chat on how to take them off.
- Left-clicking a name in the Horde Scum Nearby window targets them. Players from elsewhere were targeted as "Xal-Thorn", which Forever doesn't recognise; it's now "Xal Thorn", the way the game shows them, and that's how they're shown in the addon too. You can also type a name that way.
- `/kos clicks` writes each click on the Horde Scum Nearby window to chat, for bug reports.
- The Horde Scum Nearby window keeps its top edge where you put it and only grows downwards.

## 1.2.2

### Fixed
- Guild sync wasn't sending on Forever: the game reports addon messages as "restricted" in the open world even though they go through, and the addon believed it. It now sends and goes by the game's answer, holding messages only when the game actually refuses them. `/kos status` shows the last answer.

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
