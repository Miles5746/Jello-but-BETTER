# Jello-but-BETTER

Wobbly, jelly windows for macOS, without disabling SIP.

Inspired by [Jello](https://github.com/iamDecode/Jello). Jello-but-BETTER remakes its effects in a more practical way.

## Install

### Download

Coming soon. For now, build it from source.

### Build from source

You'll need a Mac running macOS 27 or later, with Xcode installed.

1. Open Terminal.
2. Clone the repo and open the project:
   ```sh
   git clone https://github.com/Miles5746/Jello-but-BETTER.git
   cd Jello-but-BETTER
   open Jello-but-Better.xcodeproj
   ```
3. In Xcode, press **⌘R** to build and run.
4. When macOS asks, give the app **Screen Recording** permission. If you miss the prompt, the menu has a button that opens the right Settings page.

## Usage

Jello-but-BETTER runs in the menu bar (look for the magic wand icon). From its menu you can:

| Option | What it does |
| --- | --- |
| **Start / Stop Overlay** | Turns the effect on or off. You can also press **⌃⌥⌘E** from any app. |
| **Effect** | A color or filter over the whole screen: Invert, Grayscale, Sepia, Hue Cycle, Pixellate or CRT Scanlines. |
| **Jello** | How wobbly things get: Off, Subtle, Medium or Strong. |
| **Dragged Window Only** | Only the window you're dragging wobbles, instead of the whole screen. |

## How it works

The original Jello injects code (dylibs) into other apps. That means turning off System Integrity Protection, and it still can't touch Apple's own apps such as Safari or System Settings.

Jello-but-BETTER records your screen instead, and shows the recording in a window on top of everything else. That window has no title bar, traffic lights or anything else that gives it away, and clicks go straight through it to the apps underneath, so they never lose focus.

Think of it like looking at grass through your phone's camera instead of with your own eyes. Your desktop is the grass, and this app is the phone. Because the app is what's drawing the picture, it can add effects: change the colors, make a fisheye lens, and so on.

The jello effect works like the [time warp filter](https://www.youtube.com/shorts/ize8YS0kvwo). That filter shows each row of the picture a little later than the one above it, from top to bottom. Speed that way up and move a window, and it wobbles like jello. Jello-but-BETTER spreads the delay up and down from your cursor instead of top to bottom, so the part you're holding follows you exactly and everything further away lags behind.

## Performance

Delaying every row of the screen takes a lot of work, so the Jello setting lets you choose how much:

- **Subtle**: What I use on my M1 Mac mini with 8 GB of RAM, which is about the slowest Apple silicon there is, so it should run fine on yours.
- **Medium**: Laggy on my Mac, but I'd probably use it on an M3 or M4. It has more rebound in the ripples.
- **Strong**: Looks phenomenal, but my Mac can't keep up. Think of it as a toy, not a daily setting.

---

Made by [Miles5746](https://github.com/Miles5746)
