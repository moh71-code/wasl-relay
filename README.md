# WASL — Secure and Private Messenger

WASL is a privacy-by-design Flutter messenger. It uses local user identities instead of phone numbers or email addresses, and it does not use the device contact list for discovery.

## Security model

- Ed25519 authenticates pairing payloads.
- X25519 derives a device-to-device session secret.
- AES-GCM encrypts text and selected media on the device.
- Private keys are stored through `FlutterSecureStorage`; they are never sent to the relay.
- Pairing payloads use one canonical signed representation, including the message type.
- Pairing messages include a short-lived request identifier, challenge, and expiry.

## Data minimization

The relay is only a transport. It must not persist message contents, contact lists, media, location, advertising identifiers, or permanent activity logs. The application requests camera, microphone, and file permissions only when the user invokes the corresponding feature. It does not request location, SMS, contacts, call history, or personal accounts.

## Offline-first behavior

Text and media are encrypted before transport. Unsent envelopes are queued locally and retried when the WebSocket is available. Text messages should be scheduled ahead of media transfers. Production work should add an idempotency key and server acknowledgements for exactly-once user-visible delivery.

## Validation

Run the following in a Flutter SDK environment:

```bash
flutter pub get
flutter analyze
flutter test
flutter test integration_test
```

The archive must exclude `.dart_tool`, `build`, `venv`, `ephemeral`, and browser-capture files.
