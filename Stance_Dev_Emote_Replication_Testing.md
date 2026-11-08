# Stance Dev — Marketplace/UGC server-replication validation

Status: **V3 local playback and one-shot movement cancellation visually confirmed by user on 2026-11-07; replication NOT YET confirmed.**

## What this tests

Stance's `Stance_Dev_Emote_OneShot_v3.lua` temporarily substitutes a preexisting R15 idle `AnimationId` with an underlying Marketplace/UGC *animation clip* ID, triggers playback, restores the original references, and cancels on movement. This is NOT the Roblox Marketplace emote API, and it is not automatically proven to replicate to the server.

**Do not infer server replication from `ID slot readback=2/2`, `ONE-SHOT ARMED`, or an animation visible on the account running Matcha.**

## Test A — two separate Roblox clients/accounts, normal experience

1. Join the same live Roblox server with player A (emote player) and player B (witness). Keep player B looking directly at player A's avatar. This requires two separate sessions/accounts; a second camera of A's client is not independent evidence.
2. With player A **standing still**, run V3 in Matcha. No change to V3 is needed:

```lua
loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_OneShot_v3.lua"))()
_G.StanceOneShotEmote.Report()
```

3. On player B's separate client, optionally run the read-only remote-pose witness:

```lua
loadstring(httpget("https://raw.githubusercontent.com/ThisIsFair/Animation-Market/Dev/Stance_Dev_Emote_Peer_Witness.lua"))()
_G.StancePeerWitness.Watch("oxnardmatthew", 30)
```

Replace `oxnardmatthew` with **player A's exact Roblox username**. Keep player A stationary during the witness's first ~1.5 seconds (baseline period). The observer can log remote relative limb motion but **cannot identify the animation asset**; watching player B's screen is the definitive visible comparison.

4. Back on A's client, trigger the known working underlying clip ID:

```lua
_G.StanceOneShotEmote.Play("118644064755644")
```

5. Compare **both clients** during playback. Then move A briefly. Confirm B sees the emote stop and A does not automatically replay it when idle. Consider recording both screens concurrently.
6. After testing, inspect and clean up:

```lua
-- On A:
_G.StanceOneShotEmote.Check()
_G.StanceOneShotEmote.Unload()
-- On B:
_G.StancePeerWitness.Report()
_G.StancePeerWitness.Stop()
```

**Interpretation:** If B visually sees the correct UGC animation on A, then the emote *pose* propagated to another client in that server. If B sees only normal idle/walk, the current technique did not produce observable replication, even though A animated locally. A second-client result alone is not a direct log of the server's Animator state.

## Test B — independently log server animation tracks (only in a place you own)

1. Open your own Roblox experience in Roblox Studio. Insert a Script in `ServerScriptService` and paste the source from [`Stance_Dev_Emote_Server_Observer.server.lua`](./Stance_Dev_Emote_Server_Observer.server.lua). Do **not** run this as a Matcha script.
2. Publish the experience. Join as player A with a normal Roblox client and, ideally, player B as observer. If the game has custom avatar/animation logic, record the control behavior first.
3. Locate the server's logs as the experience creator (Studio Output for Studio tests, or the published game's server logging tools if available). The script prints `AnimationPlayed` events and `GetPlayingAnimationTracks` snapshots along with the reported `track.Animation.AnimationId`.
4. Have A stand idle for a baseline, then play the V3 Gangnam Style clip and cancel via movement. Compare the server's event timestamp/track ID against baseline logs and B's visual observation.
5. A server-observed track ID matching the requested animation during V3 playback is strong evidence the playback is known to the server. **However**, because this test changes a client's AnimationId in memory, the server may report a track ID that differs from the ID used to render locally. Therefore, absence of an exact ID match is not by itself proof that no motion replicated.

## Results checklist

| Observation | Status |
|---|---|
| V3 UGC animation visible to player A | Confirmed |
| V3 cancels on movement and does not replay on idle | Confirmed |
| Player B independently sees the correct UGC emote | Not yet tested |
| Player B sees stop on movement and no replay | Not yet tested |
| Server logs a corresponding Animator track | Not yet tested |
| Same behavior works for other UGC/official underlying clip IDs | Not yet tested |

## Limits

- Server replication is governed by Roblox's Animator, not by Matcha readback or a client-local write.
- Matcha's VM currently lacks exposed `Animator:GetPlayingAnimationTracks`, `AnimationPlayed`, and `Humanoid:PlayEmoteAsync`; consequently V3 cannot prove replication from its own console.
- The remote client watcher only reads body-part positions relative to HumanoidRootPart. Idle variation, avatar turning, character movement, streaming, or API limitations can cause misleading metrics. Visual identification of the correct emote is required.
- Do not use someone else's server for Test B unless you control its scripts. Test B is a standard Roblox Studio **server** Script.
- Do not reverse/deobfuscate the protected community emote script. This test is original and uses only visible public asset IDs.

Roblox official documentation: [Animator](https://create.roblox.com/docs/reference/engine/classes/Animator), [Client/server runtime](https://create.roblox.com/docs/projects/client-server), [AnimationTrack](https://create.roblox.com/docs/reference/engine/classes/AnimationTrack).
