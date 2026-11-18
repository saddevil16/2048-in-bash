# 2048-in-bash

![2048 in the terminal](demo.gif)

A terminal version of 2048 written as a single bash script. No dependencies.

The game doesn't end when you reach 2048. You can keep merging to 4096, 8192 and higher. It only ends when the board is full and no moves are left.

## Features

- Score and a high score that is saved between sessions
- Undo, up to 20 moves back
- Your game is saved after every move, so you can quit and pick up where you left off
- Statistics (games played, best tile, moves, time played and more)
- Sliding tile animation with adjustable speed

## Requirements

- bash 4 or newer
- A terminal with 256 colors, at least 80 columns by 25 rows

The bash that ships with macOS is version 3.2 and won't work. Install a newer one with `brew install bash` and run the game with that.

Bash 5 or newer is recommended. On bash 5 the slide animation always takes the same amount of time. On bash 4 it uses a fixed number of frames instead.

## Run it

```
git clone https://github.com/saddevil16/2048-in-bash.git
bash 2048.sh
```

Or make it executable and run it directly:

```
chmod +x 2048.sh
./2048.sh
```

If you have a saved game, you'll be asked whether to continue it, start a new one, or quit.

## Controls

| Key | Action |
|---|---|
| Arrow keys, WASD or hjkl | Move tiles |
| `u` | Undo the last move |
| `t` | Show statistics |
| `v` | Change animation speed |
| `n` | Start a new game |
| `q` | Save and quit |

`v` cycles through normal, fast, off and slow. The setting is saved.

On the statistics screen, press `r` to reset all statistics and the high score (it asks you to confirm first). Any other key goes back to the game.

## Saves and statistics

Files are stored in `~/.local/share/bash2048/`:

- `save.dat` holds the current game, including the undo history
- `stats.dat` holds the high score, statistics and settings

If `XDG_DATA_HOME` is set, that is used instead of `~/.local/share`. To store the files somewhere else, set `BASH2048_DIR`:

```
BASH2048_DIR=/tmp/2048-test bash 2048.sh
```

To start completely fresh, delete that directory.

A finished game is removed from the save file when you leave it. It counts as finished only when you start a new game or quit while the game is over. If you undo out of a game-over position, it doesn't count.

## Statistics

The statistics screen shows:

- High score and highest tile reached
- Games started and games finished, and the average final score
- Total moves and total undos
- Time played
- How many games reached each tile from 128 up
- Score, moves and highest tile for the current game

## Settings in the script

A few values at the top of `2048.sh` are easy to change:

| Variable | Default | What it does |
|---|---|---|
| `MAX_UNDO` | 20 | Most undo steps kept. Older steps are dropped. |
| `ANIM_STEPS` | 5 | Slide frames on bash 4 only. Bash 5 ignores it. |

To change how long the slide takes on bash 5, edit `SLIDE_US` (in microseconds) in the `set_anim_params` function. The defaults are 220000 for slow, 110000 for normal and 60000 for fast.

## Notes

- The game uses the terminal's alternate screen, so your shell history is intact when you quit.
- If another key is already waiting when a move finishes, the animation is skipped so fast key repeat doesn't lag.
- Terminals that support synchronized output (kitty, WezTerm, iTerm2, Windows Terminal and others) will show frames without tearing. Other terminals work fine, they just may tear a little during animation.
- If the board looks cut off, make the terminal window taller. The game needs 25 rows.
