# TODO

Asked for and not yet built. Each one has a note on where it touches, because
the constraint is usually memory or the frame budget rather than the idea —
see [CLAUDE.md](CLAUDE.md) for both.

---

*(Nothing outstanding. The three items that were here — the off-screen
Mothership indicator, splitting the fleet into squadrons by class, and
resources in every mission and visible — are done; see the marker pass in
CLAUDE.md.)*
## 1. Show that the game is paused

`SPACE` freezes the battle (`order_paused`) and nothing on screen says so. §9
calls it "τακτική παύση" and it is a state the player chooses and then forgets
they are in — the fleet simply stops obeying and looks broken.

- The HUD strip is the place. It already redraws only when it changes, and
  `phase4_hud_changed` compares counts against a shadow copy — the pause flag
  wants adding to that comparison, or the word will only appear when something
  else happens to change.
- Ink 3: §2 reserves it for attention, and this is the one thing a stuck-looking
  fleet needs explaining. `JUMP` already uses it.
- Row A's right-hand end is spoken for (`RU nnn ?HELP` reaches byte 78 of 80).
  Row B has `M n JUMP` from byte 56 and the yard at 44, so the left of row B or
  a shortened label is where the space is. Check what fits before choosing the
  word — the strip is 80 bytes and `txt_draw` clips rather than wraps.
- **Memory: bank 4 has 9 bytes free.** Even a seven-character string needs
  finding somewhere. CLAUDE.md's "Where the bytes came from" notes how the last
  two features found theirs.

## 2. A context bar along the top

A strip at the **top** of the screen showing which keys do something *right
now*. Starts `ESC FOR MENU`, and while any mode is open it shows that mode's
keys instead.

This is the answer to a real failure: a player who had been told the build
panel is `B` then `,`/`.` then `ENTER` asked twice how to choose what to build.
The yard's entire readout is a three-letter tag in the corner of the bottom
strip — no cost, no class name, and nothing to say `,`/`.` are live. Worse,
those three keys mean one thing with the panel open and another with it shut,
and the player cannot see which.

The contexts, which are already flags the game keeps:

| when | what it should offer |
|---|---|
| playing | `ESC` menu, and the handful worth naming |
| `disc_active` | arrows move, `SHIFT` height, `ENTER` confirm, `ESC` cancel |
| `eco_build_open` | `,` `.` choose, `ENTER` order — **and the cost** |
| `menu_shown` | up/down, `ENTER`, `ESC` |
| `mis_briefing`, `help_shown`, `title_shown` | their own prompt, which they draw themselves today |

Things that decide the shape:

- **The tactical view has no top clip.** `spr_clip_bottom` keeps ships out of
  the bottom strip and is what lets the HUD redraw only when it changes; there
  is no `spr_clip_top`, so a top strip needs the same treatment in `spr_blit`
  and in the dirty-rectangle erase, or ships will draw over it.
- **Redraw only when the context changes**, the way `phase4_hud_changed`
  compares against a shadow copy. The bar is static for seconds at a time and
  redrawing 40 characters every frame is not affordable.
- Item 1 (paused) belongs **in this bar**, not in the bottom strip: it is the
  same idea — the game telling the player what state it is in.
- **Memory is the blocker, not the code.** Six contexts of text is a few
  hundred bytes and bank 4 has nine. This one needs the space found first, and
  §14's mitigation (6 yaw views instead of 8, ~25% of a sprite library) is the
  only large reserve left.
