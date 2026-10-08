# Reliable Groups

A reliable group is a fixed list of up to 16 members on its own private channel. Every member's app confirms every message, and messages a member missed are resent automatically once radio contact returns. Everything runs over the mesh; no internet is needed.

## Requirements

- Companion firmware version code **11 or later** (v1.15.0), the same GRP_DATA support image messages use.
- Every member uses MeshCore Open. Other apps on the same channel see nothing, and their messages are not counted.
- One free channel slot on each member's radio.
- On Android the background service keeps the exchange running while the app is in the background. With the app closed, the radio buffers incoming packets in its limited offline queue; anything beyond it is repaired after the next connection.

## Create and join

1. Channels → **+** → **Create reliable group**.
2. Enter a name and select the members from your chat contacts. You are always a member.
3. Share the invite: members choose Channels → **+** → **Join reliable group (scan QR)** or **Join reliable group (paste invite)**. The invite is too long for a mesh message; show the QR code or send the text another way.

The invite contains the channel key. Share it only with the members. Joining adds the group's private channel to the radio. In the channel list it is marked with a shield icon and its completeness status, and tapping it opens the group chat with confirmations.

## Status

Every own message shows how many of the other members have received it, updating live:

| Display | Meaning |
|---|---|
| 🕓 `0/5` | Waiting for the radio, e.g. while disconnected. |
| ✓ `3/5` | Sent; three of five have confirmed receiving it. |
| ✓✓ `5/5` (green) | Received by everyone. |
| ⚠ `3/5` (red) | Lost: not confirmed by everyone within 12 hours. |

Tap or long-press an own message to see who received it and who did not. "Received" means stored by the member's app, not read by the person. The group header shows whether everyone has everything, who is not confirmed, or how many messages are being fetched.

## Timing and traffic

With everyone in range, all confirmations arrive within about a minute: each member confirms 5–40 seconds after receiving, batching bursts into one confirmation, and any message it sends in the meantime carries the confirmation. Unconfirmed members are asked again after 1 minute, then after 2, 4, 8 … minutes (at most 4 hours apart); 12 hours after the last news, asking stops and unconfirmed messages count as lost. Anything new restarts the cycle, and a group in which everyone has everything sends nothing.

In simulation, 30 messages over six members cost about 160 packets without loss and about 270 with 30 % packet loss; most extra packets are 21-byte status packets. Pick the [region](regions.md) of the group's channel so that floods reach all members and no further.

## Limits

- Text up to 135 bytes per message with six members (fewer bytes with more members).
- The member list is fixed. To change members, create a new group.
- Anyone holding the channel key could forge packets; there are no signatures.
- History is kept on the phone, per radio identity. Leaving a group deletes it from the phone.

## Implementation reference

[reliable_group_codec.dart](../lib/services/reliable_group_codec.dart) defines the wire format (GRP_DATA data type `0x52C7`), [reliable_group_engine.dart](../lib/services/reliable_group_engine.dart) the confirmation and repair protocol, and [reliable_group_service.dart](../lib/services/reliable_group_service.dart) the radio wiring.
