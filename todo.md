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
