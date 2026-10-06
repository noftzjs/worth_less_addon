# Worth Less

A small World of Warcraft addon for **WoW Forever** (client 1.60, Interface
16001) that scans your bags and marks the **lowest-value non-quest item**
with a purple glow and its vendor value, so you always know what to vendor
or drop first when space runs out.

You can flag the 1 to 5 cheapest items instead of just one. When more than
one item is flagged, the colour shifts along a gradient from purple
(cheapest) to pink.

## Installing (testers)

1. Download the zip and extract it. You should end up with a folder called
   `WorthLess` that contains `WorthLess.toc`.
2. Move that folder into your WoW Forever AddOns folder, normally
   `C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\`
   so the TOC ends up at `...\AddOns\WorthLess\WorthLess.toc`.
3. Start the game or type `/reload`. "Worth Less" appears in the AddOns list
   on the character screen.
4. Open your bags. The cheapest sellable non-quest item glows purple. Type
   `/wl` for commands or `/wl config` for the options panel.

Note: if the flagged item is in your reagent bag you will not see the glow
when opening the other bags, because the reagent bag opens separately.
Untick "Scan the reagent bag" in the options if that bothers you.

## How value is calculated

- Value = vendor sell price x stack size.
- Quest items (quest class, quest-bound, or quest-starting items) are never flagged.
- Items with no vendor value (Hearthstone, keystones, most toys, etc.) are
  skipped by default. Turn them on with `/wl novalue` if you want them ranked
  as the cheapest items in the bag.
- The reagent bag is scanned by default. Turn it off with `/wl reagent`.

## Options panel

Open it with `/wl config`, or from the game menu under Options → AddOns →
Worth Less. It has:

- Checkboxes for every display setting and for which bags are scanned.
- A slider for how many of the cheapest items to flag (1 to 5).
- Colour swatches for the rank 1 colour and the gradient end colour.
- A live list of the items currently flagged, with their values and an
  **Ignore** button on each row.
- The ignore list. Items on it are never flagged (a mining pick, a fishing
  pole, a favourite trinket). Add to it by typing a name or ID, shift-clicking
  an item into the box, or dragging an item onto the list. Each row has a
  **Remove** button.

## Slash commands

`/worthless` or `/wl`

| Command           | Effect                                                   |
| ----------------- | -------------------------------------------------------- |
| `/wl`             | Show help and current settings                           |
| `/wl toggle`      | Enable / disable the addon                               |
| `/wl count N`     | Flag the N cheapest items (1-5, default 1)               |
| `/wl novalue`     | Include items that cannot be sold to a vendor            |
| `/wl reagent`     | Toggle scanning the reagent bag                          |
| `/wl price`       | Toggle the value text drawn on the slot                  |
| `/wl rank`        | Toggle the rank number drawn on the slot (count > 1)     |
| `/wl glow`        | Toggle the soft glow around the slot                     |
| `/wl border`      | Toggle the crisp 2px border on the slot                  |
| `/wl pulse`       | Toggle the pulsing of the glow and border                |
| `/wl tooltip`     | Toggle the extra line on the item tooltip                |
| `/wl color <c>`   | Set the rank 1 colour: a name, hex (`9f40ff`) or `r g b` |
| `/wl color high <c>` | Set the colour of the last rank when count > 1        |
| `/wl colors`      | Show current colours and the list of colour names        |
| `/wl ignore <item>` | Never flag this item (link, ID or exact name; blank = current #1) |
| `/wl unignore <item>` | Remove an item from the ignore list                  |
| `/wl ignored`     | List the ignored items                                   |
| `/wl config`      | Open the options panel                                   |
| `/wl list [N]`    | Print the N cheapest items to chat (default 10)          |
| `/wl test`        | Force the indicator onto the first visible slot (toggle) |
| `/wl debug`       | Report which bag frames and slots were found (open bags) |
| `/wl reset`       | Restore default settings                                 |

Colour names: purple, violet, pink, magenta, red, orange, yellow, green,
cyan, blue, white, gold. Hex is `rrggbb`; `r g b` accepts 0-1 or 0-255.

Settings are saved per account in `WorthLessDB`.

## Troubleshooting

If `/wl list` ranks items but nothing is drawn on the bag:

1. `/wl test` forces the indicator onto the first visible slot. If that shows,
   drawing works and the problem is matching bag/slot to a button.
2. `/wl debug` with the bags open prints which frames and buttons were found
   and whether Blizzard's own bag/slot lookup returned a button.
3. Any error inside the refresh is printed to chat once as
   `Worth Less: error: ...`, even with "Display Lua Errors" turned off.

## Install for development

The folder name inside `Interface\AddOns` must match the TOC file name
(`WorthLess`). The easiest way to work on it in place is a directory junction
from the AddOns folder to this repo. In PowerShell:

```powershell
Remove-Item -Recurse "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\WorthLess"
New-Item -ItemType Junction `
  -Path "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\WorthLess" `
  -Target "C:\Users\noftz\Dev\worth_less"
```

Then `/reload` in game after each change. If the client's interface version
moves on, bump `## Interface:` in `WorthLess.toc` (you can list several,
comma separated) or tick "Load out of date AddOns".

## Supported bag frames

The default Blizzard bag frames, both the separate-bags view and the
combined-bags view. Bag replacement addons (Bagnon, ElvUI, Baganator, ...)
use their own item buttons and are not yet supported.
