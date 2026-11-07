# Retired experimental preview

The active **Dev/Stance_Mono_Experimental.lua** no longer loads the Studio-dependent preview or its localhost bridge. This experiment was retired from the running UI because Stance is intended to work using only Matcha and a single loadstring.

The helper files below are preserved for historical development reference only. They are not required for any current Dev feature.

---

# Stance Dev — Automatic 3D Animation Previews

The preferred workflow is automatic **on demand**: selecting a marketplace pack's animation ID makes Stance queue the clip for extraction by a Studio companion and display it on its independent R15 mannequin. No individual JSON exports or typing asset IDs into Studio are needed. Your actual in-game character is never used as the preview rig.

## One-time setup on Windows

1. Download the following three files from this Dev branch and place them in the same folder: `Stance_Preview_Bridge.py`, `Stance_Start_Preview_Bridge.bat`, and `Stance_Preview_Studio_Auto.lua`.
2. Install Python 3 if needed. Double-click `Stance_Start_Preview_Bridge.bat`. It starts a local-only HTTP service on `127.0.0.1:8765`.
3. Open **Roblox Studio**, enable HTTP Requests in Security settings if necessary, then paste `Stance_Preview_Studio_Auto.lua` into Studio's Command Bar and run it once. Leave Studio open to process newly requested animations.
4. Start Stance from `Dev/Stance_Mono_Experimental.lua` in Matcha. Click a marketplace pack to preview it, choose a movement state, or enter an ID. Stance requests the keyframes automatically, then plays and caches them.

The Python helper uses only the standard library and does not ask you for a Roblox cookie or API key. Studio operates under your existing Roblox asset permissions; inaccessible animations remain unavailable. Cache files live in `StancePreviewCache` beside the Python script, with a second local cache attempted in Matcha.

**Not fully validated in Roblox:** Matcha may block localhost HTTP, Studio may lack permission for particular assets, and R15 `CurveAnimation` is not supported. The viewer presently draws an approximate block mannequin and linearly interpolates `KeyframeSequence` poses. This Dev code passed Lua syntax checks, a mocked UI smoke test, and local bridge integration tests, not an end-to-end Matcha/Studio run.

To stop the Studio worker, execute `_G.StancePreviewWorkerVersion = (_G.StancePreviewWorkerVersion or 0) + 1` in Studio's Command Bar. Close the bridge window to stop the server. `main` is not modified.

---

## Legacy manual-export fallback (not required for automatic mode)


This is an experimental animation-preview viewer. It displays a blocky R15 mannequin rendered with Matcha's Drawing triangles, rather than a Roblox ViewportFrame. It does **not** load or animate your in-game character.

## Use in Stance

1. Run `Dev/Stance_Mono_Experimental.lua`.
2. Click a pack row in Browse, or press **3D Preview** in the header.
3. Choose the movement state. You can also type an animation asset ID and click **Preview ID**.
4. Use **Play/Pause**, **Restart**, **Speed**, **Loop**, **Zoom**, and mouse-drag to orbit.

The viewer first checks the local workspace cache at `SpooferConfig/StancePreviews/<animationId>.json`, then makes a read-only, best-effort attempt to use Roblox's `AnimationClipProvider` (which is not documented in Matcha), then checks the Dev-branch JSON path. The native provider may not be exposed by Matcha. No motion is fabricated if no clip is available.

## Export a clip in Roblox Studio

1. Download or open `Stance_Preview_Studio_Exporter.lua` from this Dev branch.
2. Replace its first line's `animationId` with the exact selected animation asset ID.
3. In **Roblox Studio**, paste the exporter into the **Command Bar** in edit mode and run it. It requires access to the animation asset.
4. In Explorer, open `ServerStorage/StancePreviewExports/StancePreview_<animationId>`. The script's source contains JSON text.
5. Copy that entire JSON into a plain UTF-8 text file named `<animationId>.json` and place it in the Matcha workspace folder `SpooferConfig/StancePreviews/`.
6. Back in Stance, choose the same animation again and press **Restart** to retry loading.

If Studio denies access to the animation, the exporter cannot bypass asset permissions. This exporter currently handles R15 `KeyframeSequence` animations, not `CurveAnimation`. Some clips may require additional processing. Pose interpolation is approximate; it does not yet reproduce all Roblox easing settings, root motion, or a fully textured avatar.

## Preview data format

```json
{
  "version": 1,
  "animationId": "123456789",
  "duration": 2.5,
  "loop": true,
  "tracks": {
    "UpperTorso": [
      [0, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]],
      [1, [0, 0, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0]]
    ]
  }
}
```

Each track contains time in seconds and 12 components from `Pose.CFrame:GetComponents()`. Stance interpolates between these pose CFrames and draws the mannequin entirely inside the UI.

The production `main` branch is not affected.
