# iPhone/iPod browser feasibility probe

This intentionally small probe answers two questions on the actual iPhone and adapter:

1. Does iOS Files expose the connected iPod as external storage?
2. Can Safari download a backend file into that storage?

It also reports whether the browser exposes WebUSB or a writable directory picker. Neither is expected on iOS. A successful manual save does not give the page direct filesystem access and does not make safe, transactional `iTunesDB` updates possible.

## Run

Connect the iPhone and this machine to the same network, then run:

```sh
python3 tools/ipod-ios-poc/server.py
```

Find this machine's LAN address with `hostname -I`, then open `http://ADDRESS:8787` on the iPhone. Connect the iPod to the iPhone before running the read and write checks.

For an HTTPS test, pass a certificate trusted by the iPhone:

```sh
python3 tools/ipod-ios-poc/server.py --cert cert.pem --key key.pem
```

## Interpretation

- **iPod missing from Files:** the proposed physical topology is not usable from an iOS browser.
- **Read succeeds:** a user can manually upload selected iPod files to a web app.
- **Marker save succeeds:** backend-to-iPhone-to-iPod manual transfer is possible.
- **WebUSB unavailable:** expected on iOS.
- **Writable directory picker unavailable:** the web app cannot directly maintain the stock iPod library.

The smallest viable fallback is an iOS Files-assisted package workflow. Full stock-firmware library management requires a native component with filesystem access or moving the USB connection to the backend machine.
