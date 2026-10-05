# WASL — وصل | Secure E2EE Messenger

تطبيق مراسلة مشفّرة من الطرف إلى الطرف (Flutter + WebSocket relay).

## Build & Verify

```bash
flutter pub get
flutter analyze          # must report: No issues found!
flutter build apk --debug
flutter build apk --release
```

Outputs: `build/app/outputs/flutter-apk/app-debug.apk`, `app-release.apk`

## Architecture

| Layer | Files | Role |
|---|---|---|
| Startup | `lib/main.dart` | Hive + SQLite init, identity keys, ingestion, WS connect, `AppLockGate` |
| Theme | `lib/core/theme/wasl_theme.dart`, `wasl_widgets.dart` | Brand palette (#087E66), `WaslColors`, `WaslTheme`, `WaslMotion`, reusable widgets |
| Legacy theme | `lib/core/theme/app_theme.dart`, `app_widgets.dart`, `app_animations.dart` | Constants redirected to Wasl identity |
| Crypto | `lib/core/crypto/` | Ed25519 signing, X25519 key agreement, AES-256-GCM (`CryptoEngine`), `PairingService` |
| Storage | `lib/core/storage/storage_service.dart` | `flutter_secure_storage`: identity/session keys, PIN hash, relay & privacy config |
| DB | `lib/core/database/database_helper.dart` | SQLite v7: contacts, messages, outbox, groups, group_members. `timestamp` stored as TEXT — always parse via `int.tryParse(x.toString())`. v7 adds `reply_to_uuid`/`reply_to_text`/`reaction`/`is_edited`; `clearAllChatHistory()` wipes messages+media+outbox but keeps contacts/groups/pairings |
| Network | `lib/core/network/websocket_service.dart` | Relay frames routed by `recipient_id`; `emitLocal` feeds UI |
| Ingestion | `lib/core/network/message_ingestion_service.dart` | Global decrypt + persist + delivery/read acks + group frames |
| Files | `lib/core/network/file_transfer_service.dart` | AES-GCM whole-file encrypt → 64KB chunks; `file_offer`/`file_chunk`/`offline_file`; saves `<fileId>_<name>` + `.meta.json` (nonce/mac) locally for BOTH sender and receiver |
| Groups | `lib/core/network/group_service.dart` | Shared AES-256 group key distributed inside E2E `group_invite` frames; fan-out client-side; group media via `group_file_offer`/`group_file_chunk`/`offline_group_file` (encrypted once with group key, chunked per member) |
| Notifications | `lib/core/notifications/notification_service.dart` | `flutter_local_notifications`; generic "لديك رسالة جديدة مشفّرة" only — never content/sender; suppressed in foreground via `appInForeground` |
| Localization | `lib/core/l10n/s.dart` | Centralized bilingual `S` class (static getters + `S.locale`, synced by SettingsProvider). ALL UI strings go through `S.x` — never hardcode literals. Brand marks (`وَصْل`, `و`) and native language names stay literal |
| Media | `lib/core/media/media_kind.dart` | `WaslMedia.typeFromContent/typeFromName` classify `audio`/`image`/`file` |
| Audio | `lib/core/audio/audio_recorder_service.dart` | `record` plugin, AAC-LC .m4a |
| Settings | `lib/providers/settings_provider.dart` | Provider: theme, locale, relay, privacy, PIN, `autoLockSeconds` |
| Screens | `lib/screens/` | `chats_list_screen` (home), `chat_screen`, `group_chat_screen`, `create_group_screen`, `settings_screen`, `pin_lock_screen` (+`AppLockGate`), `qr_scanner_screen`, `name_setup_screen`, `login_screen` |

## Invariants (do not break)

- Session keys are always keyed `(myId, peerId)` — in a 1:1 chat the peer is `widget.recipientId` for BOTH sent and received media.
- `message_uuid` is the upsert key (`ConflictAlgorithm.replace`); file transfers reuse `fileId` as uuid (placeholder → received).
- Show the transfer progress bar only when `transfer_status ∈ {sending, receiving}` AND progress < 1.0 — text rows store `transfer_progress = 0.0`.
- `AppLockGate` must NEVER lock when `settings.pinLockEnabled == false` — a lock screen with no configured PIN traps the user.
- Media playback/open resolves `file_path` via `_resolveMediaPath` (full path OR bare fileId → scans app dir for `<fileId>_*`).
- Group media decrypts with `StorageService().getGroupKey(groupId)` — never the pairwise session key; meta.json carries `group_id`.
- `typing` frames are tiny unencrypted control messages throttled to ≥3s; receiver auto-hides after 6s.
- Relay registration is authenticated: server sends `{type:challenge,nonce}` on connect; client MUST reply `{type:register,user_id,public_key,nonce,signature}` where signature = Ed25519 over `wasl-register|<user_id>|<nonce>` (sent via raw `sink.add`, bypassing `sendData`'s `isConnected` gate). Server then sends `{type:registered}` — the client ONLY sets `connected` on that ack, so app/outbox frames can never be sent while unauthenticated (they'd be silently dropped). The relay binds user_id→pubkey (TOFU, RAM-only), gates all routing on auth, expires queued ciphertexts after 24h, normalizes ids with `.upper()`, and logs only `u#<sha256[:10]>` handles. Old unsigned clients are rejected — client and server MUST be deployed together.
- Delivery is at-least-once via the outbox: EVERY `chat_message` (send/edit/reaction/resend) is enqueued FIRST, then `processOutbox` relays it. A row stays until the peer's `delivery_ack` retires it by `message_uuid` (`deleteOutboxByMessageUuid`) — re-sent on every fresh `registered` (`resetOutboxRetry` + `processOutbox` via `statusStream` in ingestion `init`) and every 5 min (`_resendIntervalMs`), marked `failed` after 24h. Recipient acks immediately on `recipient_id == myId` (before decrypt — covers edit/react/drop paths). Dedup is safe: `message_uuid` UNIQUE + `ConflictAlgorithm.replace`, `isNewMessage` guards unread_count. Non-chat frames stay fire-and-forget. This survives Render free-tier sleep wiping the relay's RAM queue.
- Message actions use a v2 envelope INSIDE the ciphertext: `{'v':2,'t':…,'ru':…,'rt':…}` for replies, `{'v':2,'edit':uuid,'t':…}` for edits, `{'v':2,'react':uuid,'e':emoji|null}` for reactions — the relay never sees metadata. Ingestion emits `edit_local`/`reaction_local` UI events.
- The composer is multiline (`TextInputAction.newline`, maxLines 5) — Enter inserts a line break, sending is via the send button only. Long-press a bubble → reaction row + Reply/Edit/Copy/Info/Select/Delete; Select enters multi-select mode with its own AppBar.
- Settings has TWO destructive actions: "Clear chat content" (`clearAllChatHistory` — messages/media only) and "Wipe local data" (full zeroize). Never conflate them.
- `AppLockGate` must NEVER lock when `settings.pinLockEnabled == false`.
- `AppLifecycleState.hidden` fires on BOTH backgrounding and foregrounding paths — never record the background timestamp on `hidden`, or delayed auto-lock silently never triggers. Only `paused`/`detached` mark backgrounding.
- Text colors must be theme-aware: use `WaslColors.mutedFg(context)` / `WaslColors.fg(context)` — never raw `mutedForeground`/`foreground`/`AppTheme.textSecondary` in dark-capable screens (they render faded on dark surfaces).
- `S.*` getters are NOT const — a `const` widget cannot contain `S.x`; drop `const` (or move it to a child) when localizing.
- All user-facing strings are Arabic; keep English only in the language picker.
- Default relay: `wasl-rela.onrender.com:443` (WSS). The relay routes any `type` by `recipient_id` — no server change needed for new frame types.

## Plugin notes

- `mobile_scanner ^7`, `record ^7` — upgraded to remove the Kotlin-Gradle-Plugin build warning; APIs used are stable (`MobileScannerController`, `AudioRecorder`/`RecordConfig`).
- `flutter_local_notifications ^19` — requires `isCoreLibraryDesugaringEnabled = true` + `desugar_jdk_libs` in `android/app/build.gradle.kts` and `POST_NOTIFICATIONS` in the manifest (both configured).
