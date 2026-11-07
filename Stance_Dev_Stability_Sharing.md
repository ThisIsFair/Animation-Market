# Stance Dev: Stability and sharing update

All features in this update run using **Matcha and the Dev loadstring only**. No Roblox Studio, Python, localhost bridge, or other installation is required.

## What's new

### R6 / R15 detection
Stance checks the character's R15 body parts before enabling marketplace animation writes. R6 rigs receive a clear incompatibility warning. Rig checks do not depend on Matcha exposing Humanoid.RigType.

### Smart respawn recovery
Stance waits for the new R15 character's Humanoid and Animate animation objects before queuing a reapply, rather than trying once as soon as Humanoid exists. The UI retries temporarily unready characters for up to 22 seconds. The engine also rechecks animation references, retries failed writes with backoff, and limits successful repeated writes to avoid rapid pulses. The Controls > Auto-reapply toggle now controls the engine's cross-character behavior.

### Mix sharing
In Mix & Match choose **Codes**. **Copy mix** copies a compact versioned `s1-...` code for your eight currently assigned movement states. **Load** validates the code checksum, bundle IDs, and state compatibility, then fills your Mix without equipping it automatically. Press **Apply mix** to equip. Exporting and importing requires no external service.

The **Paste** button uses `getclipboard()` only if a Matcha build exposes it. The documented Matcha API does not include clipboard reads, so manual code entry remains the supported fallback. This custom input supports codes of up to 240 characters.

### Pack blacklist
Each Browse and Favorites row has **Hide**. Hidden packs disappear from normal browsing, Favorites views, Mix selection and Smart Mix randomization. Browse > **Hidden** shows everything you've hidden, with **Show** to restore each pack. Existing saved favorites/mixes are kept, and hidden settings persist in `stance_mono.json`.

### Playback health
The small header label reports the detected rig, capability state, and count of requested animation references whose IDs are currently synchronized. **Synchronized references do not guarantee visual playback**, which cannot yet be verified through Matcha's documented APIs. Hover the header status for more detail.

## Existing behavior preserved

- State locks in Smart Mix remain available; no duplicate single-state reroll control was added.
- Favorites, presets, themes, and swap wheel retain their existing behavior.
- The experimental 3D preview requiring Studio has been retired from the active Dev UI. Pack row clicks equip packs again.
- This release does not modify the `main` branch.

## Testing and limits

Source updates were verified on GitHub and passed structural Lua checks for balanced delimiters and function/block endings. **A live Roblox/Matcha runtime test has not yet been performed.** Animation reload behavior can vary by game, and references that appear synchronized may still need playback validation.
