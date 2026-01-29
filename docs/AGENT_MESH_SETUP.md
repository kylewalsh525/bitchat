# Agent Mesh Setup (Local Testing)

This doc is a repeatable checklist for local testing on macOS.

## Prereqs
- Two devices recommended for end-to-end tests (macOS/macOS or macOS/iOS).
- Bluetooth enabled on both devices.

## Build & Run (macOS)
1) Open the project:
   - open /Users/kylewalsh/github-local/bitchat/bitchat.xcodeproj
2) Select the macOS scheme:
   - "bitchat (macOS)" in the scheme selector.
3) Run (⌘R).

## Enable Local Agent (Device B)
In the chat input:
- /agentset general local 80
- /agenton
- /agentconfig

Expected: system message showing agent on, role/model/quality.

## Send a Request (Device A)
- /agent general hello

Expected: response appears as a system message in mesh timeline.

## Direct Targeting (Optional)
If you want to send to a specific peer by nickname:
- /agent @nickname hello

## Troubleshooting
- If no peers are visible: confirm Bluetooth is on and both apps are running.
- If agent not selected: ensure agent device ran /agenton and has role set.
- If no response: check mesh reachability (peer should appear connected/reachable).

## Reset / Disable
- /agentoff
- /agentconfig

## Notes
- Requests and responses are capped to 255 bytes in current TLV format.
- Responses only render in mesh timeline (not geohash channels).
