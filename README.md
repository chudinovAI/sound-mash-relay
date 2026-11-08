# Sound Mash Relay

An application for two Macs: the first captures system audio and plays it locally with a delay; the second receives the stream over TCP and plays it using synchronized clocks. AirPlay and SSH are not used.

## Requirements

- macOS 14.2 or newer on both Macs; building requires Xcode or Command Line Tools with Swift.
- A network connection that allows the second Mac to connect to TCP port 45987 on the first. Shared internet access alone is not enough: a VPN, firewall, or client isolation may block the connection.
- Permission to capture system audio on the first Mac. The microphone is not used.

## Security

The stream is **not encrypted or password-protected**. Anyone who can connect to port 45987 on the first Mac can receive the transmitted audio; the receiver does not authenticate the sender either. The listening port is accessible on network interfaces, not necessarily only on the home network. Use the application only on a trusted network and where this use is permitted by both devices' policies. Stop transmission when finished. The application does not change VPN or firewall settings.

## Building and Running

On the first Mac, run the following in the project folder:

```sh
./build-app.sh
```

The built application is at `dist/Sound Mash Relay.app`. Copy it to the second Mac using a convenient, permitted method. The build includes Apple Silicon and Intel versions. The application is signed with a local ad-hoc signature, not an Apple Developer certificate: macOS or organizational policy may prevent it from running.

1. Launch the application on both Macs.
2. On the first, click “Start Transmission” and grant permission to capture system audio if prompted. The first Mac displays the IP addresses of its network interfaces.
3. On the second, enter an address for the first Mac that is reachable from the second Mac's network, then click “Connect”. If several addresses are displayed, the home network address is usually needed, rather than the VPN interface address.
4. Play audio on the first Mac. If necessary, adjust the correction slider on the second by ear.
5. Click “Stop” on both Macs to stop transmission and restore normal playback.

Overall buffering adds about 600 ms of latency, so audio may lag behind video or game responses. The application smoothly corrects drift and changes to the delay setting by slightly adjusting the audio stream's sample rate; this may cause minor artifacts. Network latency and speaker characteristics mean perfect synchronization cannot be guaranteed.

The sender combines small audio blocks to reduce the number of network sends. Short capture gaps of up to 100 ms are filled with silence; a longer interruption or an insufficiently stable connection stops the session instead of allowing latency to build up.

Protected content may not be available for capture. If the connection cannot be established, check the selected address and whether TCP port 45987 is allowed between the devices; do not disable a corporate VPN or bypass organizational restrictions.
