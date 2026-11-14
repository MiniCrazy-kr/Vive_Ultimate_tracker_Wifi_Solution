# VIVE Ultimate Tracker Wi-Fi fixes

[한국어](README_FIX_ko.md) · [Project README](README.md)

## Device window and service settings

- **Devices** refreshes asynchronously so a slow device query does not block the window. Refreshes preserve sorting and selection. The list shows tracking state, pose age and status, battery and charging state, and map reports. After a reconnect, pose age uses the latest session that actually received a pose.
- **Identify Selected** sends an identify request to the selected tracker. SteamVR can also request identification through the driver. The service resolves a SteamVR pose port to a single recently active tracker before sending the command.
- **Factory Reset (USB)** asks for confirmation and uses the selected tracker serial to find the matching Windows HID device. This action resets the tracker and requires a USB connection.
- **Tracker Bindings** supports fixed SteamVR slots keyed by tracker serial and a legacy arrival-order mode. Fixed mode also lets you save a main tracker locally. Saved fixed assignments are retained when switching to legacy mode. The bundled SteamVR settings default to five tracker slots.
- **Power / Pose Rate** selects 50 or 60 Hz. It sets the tracker power-frequency command and the normal-mode pose forwarding rate. Debug mode forwards poses without pacing for capture. Restart the service to apply binding mode or rate changes.
- **Tracking lost delay (ms)** sets the SteamVR pose validity age limit. The default is now 200 ms instead of 100 ms, with a GUI range of 50–2,000 ms. Restart the service, then SteamVR, to apply it.
- **Save logs** controls service logging. With logs disabled, the service still writes a device status snapshot for the GUI. The standalone `app/clear_log.cmd` deletes matching NDJSON and app log files from the designated locations under `backups`.

## Wi-Fi reconnect and map sync

- The default initialization resolves the configured country code and sends a fresh Unix timestamp on reconnect. The Windows tracker TCP control socket uses a 4-second keepalive idle time and a 1-second probe interval. The normal profile disables periodic `ATM21` refreshes, which were associated with brief tracking loss.
- In fixed mode with the default ACK sequence, initialization reads the tracker serial and derives its protocol ID from its slot. The main tracker starts in `ATM21`. A secondary starts in `ATM11` if the main tracker has initialized, or `ATM21` while waiting for it. Standby settings are sent after the mode command.
- To request a manual sync, save the main tracker in **Tracker Bindings**, select a connected secondary in **Devices**, and use **Sync with main tracker** and **Sync Selected**. Both trackers need active control connections and fixed bindings. The secondary must be in slots 1–5, which map to query IDs 0–4. The service sends the secondary the mode and standby settings, the main tracker's IP, and the map-load request.
- With a saved main tracker and default fixed-mode initialization, the service also requests sync once per initialized main/secondary connection pair, including when the main tracker connects later. A `requested` result records command delivery to the control connection. Confirm map loading and coordinate alignment on the trackers and in SteamVR.

## SteamVR driver and review scope

The service forwards battery and charging data from tracker pose packets. The driver accepts the optional battery fields in binary UTKP and JSON poses, still reads earlier packets, and clears the SteamVR battery display when data is unavailable or pose reception becomes stale. The driver also forwards identify requests to the local service. The Git diff updates the bundled Windows driver package in `steamvr_driver/build_verify/utk_wifi_tracker` and removes generated CMake/MSBuild intermediates from `build_verify`.

The earlier verification included a Release build, targeted battery and identify checks, and a mocked sync routing test. These checks were not rerun for this documentation update. End-to-end multi-tracker map loading, coordinate alignment, standby behavior, and physical identify response still need hardware confirmation.
