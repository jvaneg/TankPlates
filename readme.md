# Tank Plates 1.4.1 \[Jonaldo Edition\]

* For 1.12 wow client
* Requires [SuperWoW](https://github.com/balakethelock/SuperWoW/)
* [ShaguPlates](https://github.com/shagu/ShaguPlates) is **optional** - TankPlates works standalone and enhances its UI when ShaguPlates is present
* Update SuperWoW and this addon together if you experience errors

## Features

* Colors enemy nameplates based on who they are attacking
* Text highlight on the enemy you are currently targeting
* CC detection - plates turn yellow when an enemy is sheeped, shackled, trapped, etc.
* Multi-tank support with a scrollable in-game tank list
* All plate colors are fully customizable in-game

<img width="1192" height="909" alt="image" src="https://github.com/user-attachments/assets/e25dfc89-beef-409d-9294-abbd63375d51" />

<img width="980" height="586" alt="image" src="https://github.com/user-attachments/assets/46636dbb-7e7c-4448-ab60-2b2ff1b60d55" />

### Color Guide (defaults)

| Color | Meaning |
|---|---|
| Bright green | The mob is attacking **you** |
| Dark green | The mob is attacking **another tank** |
| Red | The mob is attacking a **non-tank** (DPS/healer pulled!) |
| Yellow | The mob is **crowd controlled** |

Out-of-combat colors mirror normal nameplate conventions (red = enemy NPC, yellow = neutral, green = friendly, blue = friendly player).

## Commands

| Command | Description |
|---|---|
| `/tp` | Toggle the tank list window |
| `/tp tanklist` | Toggle the tank list window |
| `/tp add [name]` | Add a party/raid member to the tank list by name |
| `/tp clear` | Remove all tanks from the list |
| `/tp colors` | Open the color settings window |
| `/tp settings` | Open the color settings window |

The **tank list window** also has buttons to add your current target or yourself directly.  
Tanks can be removed individually with the **\[X\]** button next to each entry.

## Customizing Colors

Open `/tp colors` to customize every nameplate color category via an in-game color picker. Changes apply immediately and are saved between sessions. A **Reset Defaults** button restores all colors to their original values.

## Compatibility

* Works with **ShaguPlates** - nameplate colors are applied through ShaguPlates' overlay when present, so they respect its health bar layout. The UI also inherits the ShaguPlates visual theme automatically.
* Does **not** require ShaguPlates - all features work with vanilla Blizzard nameplates.
* May not be compatible with the ShaguPlates class-color option.

___
* Originally made by and for Weird Vibes of Turtle WoW
* daemonp - Added multi-tank support
* Jonaldo Edition: ShaguPlates integration, color customization UI
