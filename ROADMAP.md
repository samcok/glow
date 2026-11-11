# Roadmap

## Pairing animation

Replace the plain setup screen with an animated bridge:

1. **Entrance.** A drawing of a bridge (rounded square box with a round button on top, original artwork) flies in from large and off-axis: it zooms out and rotates on itself, with ease-in-out timing (slow start, fast middle, slow end), and settles in the middle of the screen.
2. **Waiting.** The ring around the button glows blue and pulses softly. The bridge floats slowly up and down above a soft shadow that shrinks when it rises and grows when it comes down.
3. **Detected.** As soon as the link button is pressed and the app gets its key, the bridge replays the entrance motion in reverse and much faster (about 0.4 s), and the room interface opens behind it.

Notes: respect "Reduce motion" (fade only), keep it under one second of waiting before the user can act, build it in SwiftUI (keyframe/phase animations), no video file.
