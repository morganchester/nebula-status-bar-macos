# NebulaStatus

NebulaStatus is a small macOS menu bar app for controlling Nebula tunnels.

It can:

- detect Nebula services installed through `launchd`
- detect Homebrew-based Nebula installs
- add manual configs for cases like `sudo nebula -config ~/.nebula/config.yml`
- start, stop and restart Nebula
- show the current state of each tunnel
- show the actual IP address of a running tunnel
- let you manually select a config if it was not detected automatically

The app lives in the menu bar and does not need a Dock icon or `Cmd + Tab` presence.

## Installation

1. Open `NebulaStatus-0.0.2-stable.dmg`.
2. Drag `NebulaStatus.app` to `Applications`.
3. Launch the app from `Applications`.

On first use, macOS may ask to approve the privileged helper.

If that happens:

1. Open `System Settings`.
2. Go to `General`.
3. Open `Login Items & Extensions`.
4. Allow `NebulaStatus` or its helper if macOS shows it there.

Without the helper, the app can still open and inspect configs, but privileged start and stop actions may not work correctly.

## How To Use

Each Nebula entry in the menu shows:

- a name
- current status: `RUNNING`, `STOPPED` or `UNKNOWN`
- detected or manually selected config path
- actual tunnel IP, if the tunnel is running and the interface is up

Main buttons:

- `Start` starts the tunnel
- `Stop` stops the tunnel
- the gear button lets you choose or replace the config path

If Nebula was not detected automatically:

1. Click `Add Config`.
2. Choose a config file or a config directory.
3. Start it from the menu bar.

## Supported Scenarios

NebulaStatus is designed for these common setups:

- system `launchd` services from `/Library/LaunchDaemons`
- user `launchd` services from `~/Library/LaunchAgents`
- Homebrew installs such as `homebrew.mxcl.nebula`
- direct manual configs without a plist

## Important Notes

- On macOS, Nebula usually needs elevated privileges to create and manage the tunnel interface.
- Because of that, Homebrew user agents are not always enough by themselves. NebulaStatus can use its privileged helper and direct root start path when needed.
- If auto-detection finds the service but not the correct config, use the gear button and point the app to the right file or directory.
- The shown IP is the real current address from the active tunnel interface, not just a value guessed from the config.

## Debug Mode

There is an optional `Debug On` switch in the menu.

When debug mode is enabled, the app exposes extra diagnostic actions such as:

- opening the log
- clearing the log
- opening config locations
- opening plist files
- showing extra service details

When debug mode is disabled, the interface stays minimal and focused on normal use.

## Contributing

This is a small project.

Contributions are welcome.

- For questions, bug reports, or feature requests, please open an issue.
- If you want to contribute code, feel free to submit a pull request.