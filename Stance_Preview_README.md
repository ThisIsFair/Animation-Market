# Stance Dev — Independent R15 Animation Preview

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
