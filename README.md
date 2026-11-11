<h1 align="center">BH&G Kill List</h1>

<p align="center">
  <i>Better Homes & Gardens' kill-on-sight list, for WoW: Forever.</i><br>
</p>

<p align="center">
  <a href="../../releases/latest"><b>Download the latest release</b></a> &nbsp;·&nbsp; <a href="#with-wowup-recommended"><b>Install with WowUp</b></a>
</p>

---

## What it does

One kill-on-sight list for the whole guild. Add someone and every guild member running the addon gets them too.

- **A warning when they show up.** When a player on the list appears near you (on a nameplate, as your target or under your mouse), you get a banner, a warning sound and a line in chat with why they're on the list and who added them.
- **The guild hears about it.** Your guildmates see "*Name* spotted by *you* in *Goldshire, Elwynn Forest*" in their chat.
- **Horde Scum Nearby.** A small window lists the enemy players around you, the ones on the list on top in red, with your wins and losses against each. Left-click a name to target them; right-click to add or remove them.
- **Always in sync.** Anything added, changed or removed reaches every guild member online straight away. Anyone who was offline catches up a few seconds after logging in, removals included.
- **Tooltips.** Listed players show "Kill on sight" and the reason on their tooltip.
- **Your record, kept forever.** Every enemy player you come across is remembered: when and where you last saw them, how often, and your wins and losses against them. Hover a name in the nearby window for your record against them, or open the **Recently Seen** page in `/kos` to see everyone.
- **Spy's alert sounds** for listed players, guild sightings and new enemies nearby.

Inspired by the addon Spy.

## Installing

### With WowUp (recommended)

[WowUp](https://wowup.io) installs the addon for you and keeps it up to date.

1. Open WowUp and pick **WoW Forever** in the game dropdown at the top left.
2. Click **Get Addons** on the left, then **Install from URL** at the top right.
3. Paste `https://github.com/Kain-Mercer/KoS-Mod` into the box and click **Import**.
4. Restart the game (a `/reload` isn't enough the first time).

From then on, WowUp shows an update whenever a new version is released.

### Manually

1. Download the **BHG-Kill-List** zip from the [latest release](../../releases/latest).
2. Unzip it. You'll get a folder called `BHG-Kill-List`.
3. Put that folder in your WoW: Forever `Interface\AddOns` folder. The folder name must stay exactly `BHG-Kill-List`.
4. Restart the game (a `/reload` isn't enough the first time).

To update, replace the `BHG-Kill-List` folder with the one from the newest release. Your list and settings are kept.

## Adding players

- **Right-click** a player's name in chat, their portrait or their nameplate menu and pick **Add to BH&G Kill List**.
- **Target them** and type `/kos add`, or click **Add target** in the list window.
- **By name:** `/kos add Name a reason`, or **Add by name** in the list window. Players from another realm are `Name-Realm`.

You'll be asked for a reason. It's optional, but it's what the whole guild sees when that player shows up.

## Commands

| Command | What it does |
|---|---|
| `/kos` | Open the list: search, edit reasons, remove players, options. |
| `/kos add [name] [reason]` | Add your target, or someone by name. |
| `/kos remove <name>` | Take someone off the list (for everyone). |
| `/kos reason <name> <reason>` | Change someone's reason. |
| `/kos check <name>` | Is this player on the list? |
| `/kos seen` | Everyone you've come across, with your wins and losses against them. |
| `/kos nearby` | Show or hide the Horde Scum Nearby window. |
| `/kos plates` | Turn on enemy nameplates, so enemies are spotted as soon as they're in range. |
| `/kos options` | Open the options. |
| `/kos sync` | Compare lists with the guild now. You shouldn't need this: it happens on its own at login. |
| `/kos test` | Show a test warning. |
| `/kos move` | Move the warning banner. |
| `/kos status` | What the addon can see. Handy for bug reports. |
| `/kos off` / `on` | Turn Kain-UI Forever's kill list off or on (see below). |

## Options (`/kos options`)

Turn each part of the warning on or off (banner, sounds, chat), the sound for every new enemy nearby, whether you tell the guild when you spot someone, whether you see the guild's sightings, and whether the nearby window shows every enemy player or only listed ones.

## Good to know

- **Everyone shares one list.** Anyone with the addon can add or remove players, and it changes for the whole guild.
- **Only enemies go on the list.** Players on your side can't be added: the addon checks the player itself, or by name your guild, your group and anyone it has seen on your side this session.
- **Sharing only works within the guild**, through the game's hidden addon messages. Nothing is sent anywhere else.
- **In combat** the nearby window can't take new rows (the game doesn't allow it), so newcomers are counted at the bottom and get their row when combat ends. The warning works in combat either way.
- **In instances** the game hides player names from addons, so listed players aren't spotted there.
- **Turn on enemy nameplates** (`/kos plates`). That's how enemies get spotted the moment they come into range; without them, only when you target or mouse over someone.
- **How far away enemies are spotted** depends on the game's nameplate range. The addon raises it as far as the game allows (option "Show nameplates as far away as the game allows"). Beyond that range the game gives addons no way to see a player until you mouse over or target them, so those are still caught the moment you hover them.
- **Wins and losses** are worked out from what the game lets addons see (Forever doesn't let addons read the combat log, which Spy uses). A win is an enemy you were fighting dying, or an honourable kill; a loss is dying while an enemy player was attacking you. Your record stays on your PC and isn't shared.
- `/kos status` shows a *list fingerprint*. Once everyone is in sync, it's the same for every guild member.

## With Kain-UI Forever

Kain-UI Forever (1.0.347 and later) has this kill list built in. You don't need both, but having both is fine:

- K-UI's copy runs and this addon stays asleep, so nothing shows twice.
- On its first login K-UI brings over this addon's list, your wins and losses, your settings and window positions.
- To use this addon instead, type `/kos off` and `/reload`. `/kos on` and `/reload` switches back.
- Both copies sync with the same guildmates, so it doesn't matter which one each person runs.

## Credits

Inspired by Spy. The alert sounds come from Spy.

## For developers

`tests/sync_sim.lua` runs many copies of the addon against a simulated guild channel and checks that their lists always end up the same, that a big guild doesn't flood the channel, and that spotting works. Run it with `lua5.1 tests/sync_sim.lua BHG-Kill-List`. The Check workflow runs it and luacheck on every push. Releases are made with the **Publish release** workflow (Actions tab), which reads the version from the `.toc` and the notes from `CHANGELOG.md`.
