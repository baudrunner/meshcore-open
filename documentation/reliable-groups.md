# Reliable Groups

A reliable group is a fixed list of up to 16 members on its own private channel. Every member's app confirms every message, and messages a member missed are resent automatically once radio contact returns. Everything runs over the mesh; no internet is needed.

## Requirements

- Companion firmware version code **11 or later** (v1.15.0), the same GRP_DATA support image messages use.
- Every member uses MeshCore Open. Other apps on the same channel see nothing, and their messages are not counted.
- One free channel slot on each member's radio.
- On Android the background service keeps the exchange running while the app is in the background. With the app closed, the radio buffers incoming packets in its limited offline queue; anything beyond it is repaired after the next connection.

## Create and join

1. Channels → menu → **Reliable groups** → **+** → **Create group**.
2. Enter a name and select the members from your chat contacts. You are always a member.
3. Share the invite: members scan the QR code or paste the copied text through **Scan invite QR code** or **Paste invite**.

The invite contains the channel key. Share it only with the members. Joining adds the group's private channel to the radio; the channel also appears in the channel list, but its chat stays empty because group messages are not channel text.

## Status

| Display | Meaning |
|---|---|
| Green: complete | You hold every message anyone has reported, and every member has confirmed holding all of them. |
| Yellow: waiting for … | These members have not confirmed the latest messages yet, e.g. because they are out of range. |
| Red: N missing | Messages exist that you do not have yet; they are requested automatically. |
| `3/5` on your message | Three of the five other members have stored it. Tap the message for names. |

"Stored" means saved by the member's app, not read by the person. The status reflects the last reports heard: a member out of range may have written something since.

## Traffic

Confirmations are batched: each member acknowledges after 20–60 seconds, and any message it sends in the meantime carries the acknowledgement. Missing members are asked with growing intervals, and asking stops after 8 rounds until something new happens. A group in which everyone has everything sends nothing. In simulation, 30 messages over six members cost about 130 packets without loss and about 225 with 30 % packet loss; most extra packets are 21-byte status packets. Pick the [region](regions.md) of the group's channel so that floods reach all members and no further.

## Limits

- Text up to 135 bytes per message with six members (fewer bytes with more members).
- The member list is fixed. To change members, create a new group.
- Anyone holding the channel key could forge packets; there are no signatures.
- History is kept on the phone, per radio identity. Leaving a group deletes it from the phone.

## Implementation reference

[reliable_group_codec.dart](../lib/services/reliable_group_codec.dart) defines the wire format (GRP_DATA data type `0x52C7`), [reliable_group_engine.dart](../lib/services/reliable_group_engine.dart) the confirmation and repair protocol, and [reliable_group_service.dart](../lib/services/reliable_group_service.dart) the radio wiring.
