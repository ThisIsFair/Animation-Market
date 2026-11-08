# Stance Dev — Experimental Emotes

Stance Dev now includes a separate **Emotes** workspace. This is an **experimental compatibility prototype**, not yet a marketplace-emote animation-ID player.

## How to try it

Use the regular `StanceDev.lua` loadstring. Open **Emotes** in the compact Mono sidebar (or choose Emotes from Home).

The initial library contains Roblox's seven standard commands: Wave, Point, Cheer, Laugh, Dance, Dance 2 and Dance 3. You can search, save favorites, or click **/e** to copy the official command for pasting into Roblox chat.

**Play** first attempts Roblox's real `Humanoid:PlayEmoteAsync` API, then the older `Humanoid:PlayEmote` API. Neither is listed as a supported Matcha LuaVM method in the available Matcha documentation, so these calls can fail.

An explicitly opt-in **Chat fallback: ON** switches to Matcha's documented keyboard-input APIs when both native calls fail. It tries to focus Roblox chat, replace its contents with the corresponding `/e` command, and submit it. This may fail if the experience disables chat, changes chat shortcuts, or redirects keyboard focus. The fallback can put text into chat, so it is **OFF by default** and should be tried first in a safe test experience. The fallback is only for the seven standard emotes, not arbitrary text or emote IDs.

Standard Roblox emotes normally cancel when the character starts moving. Stance does not inject movement or forcibly interrupt animation tracks and does not claim to verify visual playback or replication. The UI hides after a request to let you see your character; F4 reopens it.

## Safety and isolation

- The emote code is isolated in `Stance_Emote_Engine.lua`, separate from movement animation spoofing.
- The Emotes page uses the current R15 rig check. An R6 rig is rejected by the playback adapter.
- Emote favorites and the fallback toggle are saved in `stance_mono.json`; older saved settings are retained.
- Existing movement packs, favorites, mix locks and replay behavior are unchanged.
- This change is **Dev-only**, and `main` is untouched.
- If the new adapter fails to load, Stance's other pages still function.

## Cute Wave asset-ID test (2026-11-07)

The Dev **Emotes** workspace now opens on a **Test ID** tab containing the user-supplied Cute Wave asset `85402831040149` (editable). Press **Play test** in an R15 experience and then use F4 to reopen the overlay; use **Stop** to halt Stance's custom track. The original **Standard** tab remains available.

The `Stance_Emote_Engine.lua` adapter attempts `Animator:GetTrackByAnimationId("rbxassetid://85402831040149")` first. If not already loaded, it finds a preexisting `Animation` instance inside the character, tries to `Clone()` it (no `Instance.new`), changes the clone's `AnimationId` and attempts `Animator:LoadAnimation(clone)`, then `AnimationTrack:Play()`. Where available it sets Action priority, watches R15 movement/jumping/respawn to stop the track, and provides a manual Stop button.

Each unsupported or rejected stage returns a visible diagnostic. A successful method call **does not guarantee visible playback**; the asset might be a marketplace Emote item containing a different animation clip ID, or Roblox may reject it on permissions. The asset's underlying content type was not independently verified because the Creator Store page could not be retrieved.

The ID test does not use keyboard emote commands, manipulate Roblox memory, or alter the avatar description. The separate existing movement-pack spoofing code is left unchanged. `Emotes.Stop` stops only tracks started by Stance's test, not normal Roblox emotes.

Live Matcha execution, successful player-visible playback, stop-on-movement behavior and replication **still require testing**. This is not production-ready.

## What is **not** implemented yet

An actual catalog of arbitrary Roblox Marketplace emotes and unrestricted playback by animation asset ID are **not** part of this prototype. Roblox's usual way to register additional emote IDs involves `HumanoidDescription:SetEmotes` and `SetEquippedEmotes`, while another path is `Animator:LoadAnimation`. Those capabilities are not documented for Matcha, and Roblox may enforce ownership and permission rules. We will need live tests or documented Matcha support before an asset-ID emote marketplace can be advertised as functional.

## Verification

The changed Lua source passed static delimiter/block checks. It has **not** been run inside a live Roblox/Matcha session.

Reference: Roblox support's `/e` commands and Roblox Creator Hub's character emote API documentation.
