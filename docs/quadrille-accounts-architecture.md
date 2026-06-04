
### 1. Where Models Agree

| Finding | GPT-5.5 Thinking | Claude Opus 4.8 Thinking | Gemini 3.1 Pro Thinking | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Accounts must be **optional/additive**; app works offline without login | ✓ | ✓ | ✓ | “Accounts must be optional, not a gate.”[^4_1] Local-only preserved.[^4_2][^4_3] |
| Keep **Drift/SQLite local DB as source of truth** (offline-first) | ✓ | ✓ | ✓ | Cloud is replication; local-first remains.[^4_1][^4_2][^4_3] |
| Server must be **per-user scoped** (replace `account="default"` with `user_id`) | ✓ | ✓ | ✓ | Minimal multi-tenancy change; server-side enforcement required.[^4_1][^4_2][^4_3] |
| Use **Argon2id** for password hashing (if self-hosting passwords) | ✓ | ✓ | ✓ | All recommend Argon2id as modern default.[^4_1][^4_2][^4_3] |
| Web auth should use **httpOnly Secure cookies**; mobile stores secrets in **secure storage** | ✓ | ✓ | ✓ | Cookie on same-origin web; mobile uses `flutter_secure_storage`/bearer.[^4_1][^4_2][^4_3] |
| Whole-DB overwrite LWW is **too risky** with multiple devices; need at least row-level merge + tombstones | ✓ | ✓ | ✓ | All warn whole-DB LWW will lose data; require `deleted_at` tombstones.[^4_1][^4_2][^4_3] |
| Avoid social login in v1 unless you want Apple policy complexity | ✓ | ✓ | ✓ | All caution about Apple login requirements/implications.[^4_1][^4_2][^4_3] |

### 2. Where Models Disagree

| Topic | GPT-5.5 Thinking | Claude Opus 4.8 Thinking | Gemini 3.1 Pro Thinking | Why They Differ |
| :-- | :-- | :-- | :-- | :-- |
| **Token/session model** | Opaque **server-side sessions** (no JWT) | **JWT access + rotating refresh** (or pure opaque acceptable) | Pure **opaque sessions** | Claude values short-lived access tokens + rotation patterns; GPT/Gemini optimize for simplicity + easy revocation on a single VPS.[^4_1][^4_2][^4_3] |
| **Sign-out local-data behavior** | Default **keep local profile**, offer “remove from device” | Default **keep**, switch profile DB; optional removal | Says **wipe local DB** on sign-out (for shared devices) | Different assumptions about typical usage: personal devices vs shared/public devices; local-first UX vs privacy-first default.[^4_1][^4_2][^4_3] |
| **How far to evolve sync now** | Keep full snapshot transport but **server merges rows** (LWW by `updated_at`) | Pushes harder: move to **row-level sync API** (`synced_rows` + cursor) now | Prefers minimal: keep JSONB bucket but implement row-merge; delta later | Claude optimizes for long-term correctness and efficient deltas; GPT/Gemini prioritize smallest change that stops data loss.[^4_1][^4_2][^4_3] |
| **RLS (Postgres row-level security)** | Optional; app-layer scoping fine | Explicitly “don’t need RLS” for your setup | Not emphasized; leans app-layer | All see RLS as optional/complex for solo FastAPI; Claude is most explicit on deferring it.[^4_1][^4_2] |
| **Web Push fan-out** | Target **originating device** (not all) | Same: fix schema to per-device; push should target timer origin | Suggests push to all devices except origin | Different product assumptions: “timer started on this device” vs “notify me anywhere”; your timer semantics suggest origin-targeting is safer.[^4_1][^4_2][^4_3] |

### 3. Unique Discoveries

| Model | Unique Finding | Why It Matters |
| :-- | :-- | :-- |
| GPT-5.5 Thinking | Concrete plan for **opaque session token** format + per-device session records + cookie+bearer split.[^4_1] | Easiest to implement without introducing refresh/JWT complexity; strong revocation story. |
| Claude Opus 4.8 Thinking | Strong push: **do row-level sync at same time as accounts**; proposes a true **`synced_rows` delta** table keyed by `(user_id, table, row_id)`.[^4_2] | If you expect real concurrent devices, a cursor-based delta sync is the most future-proof, but it’s a bigger change. |
| Gemini 3.1 Pro Thinking | Highlights “**Guest merge race**”: must pull cloud first, merge locally, then push to avoid overwriting cloud.[^4_3] | Prevents the nastiest first-login data loss scenario. |


***

## 4. Comprehensive Analysis

**High-confidence recommendations.** All three models converge on the “shape” of the solution: (1) accounts are optional; (2) Drift remains authoritative offline; (3) server storage becomes per-user; (4) passwords use Argon2id; (5) web uses httpOnly cookies; mobile uses secure storage; (6) the current whole-DB overwrite must evolve to row-level merge with tombstones (`deleted_at`). That set is your non-negotiable core, and it’s enough to deliver multi-user isolation without breaking offline mode.[^4_1][^4_2][^4_3]

**Biggest architectural fork: opaque sessions vs JWT access+refresh.** Because Quadrille’s API is a single FastAPI service on one VPS, the main advantages of JWT (stateless verification, multi-service validation) don’t really apply. GPT-5.5 Thinking and Gemini 3.1 Pro Thinking therefore prefer **opaque DB-backed sessions** for simplicity, revocation, and multi-device session management. Claude Opus 4.8 Thinking leans toward a more “industry standard” split: short-lived JWT access + rotating opaque refresh tokens, mainly to reduce DB lookups and follow established rotation patterns. For your usage profile (sync after workouts; low request volume), **opaque sessions everywhere** is the smallest, safest, and easiest to reason about.[^4_2][^4_3][^4_1]

**Local-first ↔ account UX is the real hard part.** All models flag that the merge/migration experience is more dangerous than the auth endpoints. The correct mental model is: a device always has a local profile; signing in *attaches* that profile to an account and optionally merges with cloud. You should not “gate” the app behind auth, and you should not implicitly destroy local data on sign-out. Gemini’s “pull-merge-push” ordering is critical to avoid overwriting existing cloud state.[^4_3][^4_1][^4_2]

**Sync evolution: smallest correct change.** You don’t need CRDTs. Your schema is UUID-keyed with `updated_at`, which makes **row-level last-write-wins (LWW)** a pragmatic baseline. The smallest change that is “correct enough” for multi-device is: keep sending full snapshots, but change the server from “replace JSONB payload” to “merge rows by (table, id) and `updated_at`, with `deleted_at` tombstones”. GPT-5.5 is squarely in this camp. Claude’s `synced_rows` delta design is more ambitious and better long-term, but it’s also a bigger migration surface area.[^4_1][^4_2][^4_3]

**Operationally:** you’ll want rate limiting on signup/login/reset, email verification via Mandrill, account deletion/export endpoints (you already have export), and a plan to migrate the existing `default` bucket to *your* first real user—without letting any new user “claim default.”[^4_2][^4_3][^4_1]

***

## 5. Concrete Recommended Architecture (implementable)

### 5.1 v1 Auth method (recommended)

**First-party email + password (self-hosted)**, plus:

- Email verification before enabling cloud sync.
- Password reset via Mandrill.
- No social OAuth in v1 (keeps Apple login policy complexity out of scope).[^4_3][^4_1][^4_2]


### 5.2 Session/token model (recommended)

**Opaque server-side sessions** (single token), with per-device sessions.

**Web (same-origin `quadrille.app/api`):**

- Set cookie: `__Host-quadrille_session=<opaque>`; `HttpOnly; Secure; SameSite=Lax; Path=/`.
- CSRF: enforce `Origin` / `Referer` checks on state-changing endpoints; optionally add CSRF token header if you want belt-and-suspenders.

**Mobile (iOS/Android):**

- Store the same opaque token in `flutter_secure_storage`.
- Send `Authorization: Bearer <opaque>`.

**Revocation:**

- `logout` revokes one session row.
- `logout-all` revokes all sessions for user.
- Password reset revokes all sessions.


### 5.3 Server schema (DDL sketch)

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email CITEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  email_verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE auth_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  device_id TEXT,
  platform TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  idle_expires_at TIMESTAMPTZ NOT NULL,
  absolute_expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ
);

CREATE TABLE auth_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL CHECK (purpose IN ('verify_email','password_reset')),
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_sync_state (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  payload JSONB NOT NULL,
  revision BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_device_id TEXT NOT NULL,
  platform TEXT NOT NULL,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, client_device_id)
);

CREATE TABLE push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```


### 5.4 Sync change (smallest correct change)

Keep your existing endpoints (`GET /sync`, `PUT /sync`) but change server behavior:

- `PUT /sync` no longer blindly replaces `payload`.
- Server loads `existing_payload`, merges `incoming_payload` by:
    - union rows by `(tableName, id)`
    - choose row with later `updated_at`
    - handle deletes using `deleted_at` tombstones
- Server stores merged payload and increments revision.
- Server returns merged payload + revision.

**Payload v2 (recommended):**

```json
{
  "format": "quadrille.backup",
  "version": 2,
  "baseRevision": 12,
  "clientDeviceId": "uuid",
  "generatedAt": "2026-06-03T17:30:00Z",
  "tables": { "...": [] }
}
```

Add `deleted_at` to all synced tables locally and in the JSON.

### 5.5 FastAPI endpoints (v1)

Auth:

- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/logout`
- `POST /api/auth/logout-all`
- `GET /api/auth/me`
- `POST /api/auth/email/resend-verification`
- `POST /api/auth/email/verify`
- `POST /api/auth/password/forgot`
- `POST /api/auth/password/reset`

Sync (auth-required when signed in; unavailable in local-only mode):

- `GET /api/sync`
- `PUT /api/sync`

Push:

- `POST /api/devices` (register/update)
- `POST /api/push/subscriptions` (register)
- `DELETE /api/push/subscriptions/{id}`

Account ops:

- `GET /api/account/export`
- `DELETE /api/account`


### 5.6 Flutter/Riverpod client architecture

Key new concepts:

1) **AuthState**: `localOnly | signedIn(unverified) | signedIn(verified)`.
2) **Profile DB namespaces**: one DB per profile:

- local-only: `quadrille_local`
- signed-in: `quadrille_user_<userId>`
(For web: separate Drift/IndexedDB DB names.)

3) **Merge flow on sign-in** (safe ordering):

- Pull cloud snapshot (if any)
- Merge into local DB (row-level LWW + tombstones)
- Push merged snapshot back
This is the Gemini “pull-merge-push” invariant.[^4_3]

4) **Sign-out UX**:

- Default: keep offline data; just revoke session and switch profile.
- Provide “Remove account data from this device” to wipe that profile DB.

5) **HTTP client**:

- Web: use `withCredentials=true` so cookies attach.
- Mobile: inject bearer from secure storage.

***

## 6. Phased Build Plan (solo/self-hosted) + Migration

### Phase 0 — Prep (safe)

- Add `/api/version`.
- Backup Postgres (`pg_dump`) and export the current `sync_state.default` payload.


### Phase 1 — Server auth, but don’t break existing clients

- Ship new auth tables + endpoints.
- Keep legacy shared-token sync working temporarily.


### Phase 2 — Migrate the existing `default` bucket

- Create your user account (manual SQL or via register).
- Copy `sync_state(account='default')` payload into `user_sync_state(user_id=<your id>)`.
- Freeze legacy `default`; do not let anyone else access it.


### Phase 3 — Client release: optional sign-in

- Add auth UI, secure storage, `AuthController`.
- Add profile registry + per-user local DB namespaces.
- SyncCoordinator: only sync when `signedIn && emailVerified`.


### Phase 4 — Fix sync correctness (required for multi-device)

- Add `deleted_at` to all tables.
- Implement server-side row-merge on `PUT /sync`.
- Bump payload to v2.
- Add “merge preview” logging/endpoint if you want debugging.


### Phase 5 — Push subscriptions per user/device

- Replace `push_subscriptions(account PK, ...)` with `user_id + device_id + endpoint`.
- Rest timer push targets the subscription that started the timer (default).


### Phase 6 — Decommission legacy shared-token mode

- Return `426 Upgrade Required` for legacy sync after a grace window.
- Remove shared bearer token from env.

If you want, I can next produce: (1) exact merge pseudo-code for your payload structure (including `template_exercises` foreign-key ordering), (2) a concrete FastAPI dependency that authenticates via cookie-or-bearer, and (3) Drift migrations for adding `deleted_at` everywhere.
<span style="display:none">[^4_10][^4_100][^4_101][^4_102][^4_11][^4_12][^4_13][^4_14][^4_15][^4_16][^4_17][^4_18][^4_19][^4_20][^4_21][^4_22][^4_23][^4_24][^4_25][^4_26][^4_27][^4_28][^4_29][^4_30][^4_31][^4_32][^4_33][^4_34][^4_35][^4_36][^4_37][^4_38][^4_39][^4_4][^4_40][^4_41][^4_42][^4_43][^4_44][^4_45][^4_46][^4_47][^4_48][^4_49][^4_5][^4_50][^4_51][^4_52][^4_53][^4_54][^4_55][^4_56][^4_57][^4_58][^4_59][^4_6][^4_60][^4_61][^4_62][^4_63][^4_64][^4_65][^4_66][^4_67][^4_68][^4_69][^4_7][^4_70][^4_71][^4_72][^4_73][^4_74][^4_75][^4_76][^4_77][^4_78][^4_79][^4_8][^4_80][^4_81][^4_82][^4_83][^4_84][^4_85][^4_86][^4_87][^4_88][^4_89][^4_9][^4_90][^4_91][^4_92][^4_93][^4_94][^4_95][^4_96][^4_97][^4_98][^4_99]</span>

<div align="center">⁂</div>

[^4_1]: Day-1-Push-A.jpg

[^4_2]: Day-3-Leg-A-3.jpg

[^4_3]: Day-2-Pull-A-2.jpg

[^4_4]: https://developer.android.com/topic/architecture/data-layer/offline-first

[^4_5]: https://www.couchbase.com/blog/offline-first-more-reliable-mobile-apps/

[^4_6]: https://www.askantech.com/offline-first-mobile-architecture-apps-without-internet/

[^4_7]: https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html

[^4_8]: https://9to5mac.com/2024/01/27/sign-in-with-apple-rules-app-store/

[^4_9]: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html

[^4_10]: https://psono.com/blog/evolution-of-password-hashing

[^4_11]: https://dev.to/carminezacc/securely-storing-jwts-in-flutter-web-apps-2nal/comments

[^4_12]: https://carmine.dev/posts/flutterwebjwt/

[^4_13]: https://pub.dev/packages/flutter_secure_storage

[^4_14]: https://stackoverflow.com/questions/60840704/what-is-flutter-secure-storage-exactly-and-how-it-works

[^4_15]: https://hasura.io/blog/design-guide-to-offline-first-apps

[^4_16]: https://powersync.com/blog/offline-first-apps-with-tanstack-db-and-powersync

[^4_17]: https://www.crunchydata.com/blog/row-level-security-for-tenants-in-postgres

[^4_18]: https://www.bytebase.com/blog/postgres-row-level-security-footguns/

[^4_19]: https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/rls.html

[^4_20]: https://firebase.google.com/docs/auth/flutter/start

[^4_21]: https://docs.flutter.dev/data-and-backend/firebase

[^4_22]: https://supabase.com/docs/guides/self-hosting

[^4_23]: https://isc.sans.edu/diary/11263

[^4_24]: https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html

[^4_25]: https://github.com/nokia/OWASP-CheatSheetSeries/blob/master/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.md

[^4_26]: https://www.invicti.com/blog/web-security/same-site-cookie-attribute-prevent-cross-site-request-forgery

[^4_27]: https://pub.dev/packages/firebase_auth

[^4_28]: https://www.hipaajournal.com/nist-password-guidelines-update-2024/

[^4_29]: https://linfordco.com/blog/nist-password-policy-guidelines/

[^4_30]: https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html

[^4_31]: https://github.com/laurentS/slowapi

[^4_32]: https://stackoverflow.com/questions/79508238/how-to-apply-a-global-rate-limit-for-all-routes-using-slowapi-and-fastapi

[^4_33]: https://fastapi.tiangolo.com/tutorial/security/

[^4_34]: https://github.com/fastapi-users/fastapi-users

[^4_35]: https://www.youtube.com/watch?v=ac4p2jelZdk\&vl=en

[^4_36]: https://www.reddit.com/r/FastAPI/comments/1fuxlj0/best_practices_for_adding_social_auth_to_fastapi/

[^4_37]: https://www.geeksforgeeks.org/python/authentication-and-authorization-with-fastapi/

[^4_38]: https://stackoverflow.com/questions/77296091/creating-a-session-with-fastapi

[^4_39]: https://owasp.deteact.com/cheat/cheatsheets/Authentication_Cheat_Sheet.html

[^4_40]: https://endgrate.com/blog/10-session-management-security-best-practices

[^4_41]: https://fastapi.tiangolo.com/tutorial/security/first-steps/

[^4_42]: https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html

[^4_43]: https://fastapi-users.github.io/fastapi-users/10.1/configuration/authentication/strategies/database/

[^4_44]: https://www.oligo.security/academy/owasp-top-10-cheat-sheet-of-cheat-sheets

[^4_45]: https://www.reddit.com/r/Bitwarden/comments/1c2xmfr/argon2id_defaults_are_much_higher_than_owasp/

[^4_46]: https://www.huntress.com/cybersecurity-101/topic/password-security-storage

[^4_47]: https://www.vaadata.com/en/blog/how-to-update-passwords-in-database-to-secure-their-storage-with-argon2/

[^4_48]: https://brandur.org/fragments/password-hashing

[^4_49]: https://community.bitwarden.com/t/argon2id-settings-higher-values-better/70073

[^4_50]: https://github.com/OWASP/www-projectchapter-example/blob/main/cheatsheets/Forgot_Password_Cheat_Sheet.md

[^4_51]: https://www.onlinehashcrack.com/guides/password-recovery/bcrypt-vs-argon2-choosing-strong-hashing-today.php

[^4_52]: https://www.oneadvanced.com/resources/whats-new---nist-password-guidelines-september-2024/

[^4_53]: https://guptadeepak.com/research/password-hashing-guide-2026/

[^4_54]: https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/04-Authentication_Testing/09-Testing_for_Weak_Password_Change_or_Reset_Functionalities

[^4_55]: https://arxiv.org/html/2504.17121v2

[^4_56]: https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple

[^4_57]: https://www.reddit.com/r/reactnative/comments/18ql6fv/is_it_compulsory_to_have_apple_signin_if_using/

[^4_58]: https://developer.apple.com/app-store/review/guidelines/

[^4_59]: https://mjtsai.com/blog/2024/01/26/sign-in-with-apple-no-longer-required/

[^4_60]: https://github.com/orgs/supabase/discussions/23246

[^4_61]: https://developer.apple.com/news/?id=j9zukcr6

[^4_62]: https://www.youtube.com/watch?v=T96Pue6ePGA

[^4_63]: https://supabase.com/docs/reference/self-hosting-analytics/introduction

[^4_64]: https://www.facebook.com/groups/swiftiosdev/posts/2673225896169593/

[^4_65]: https://developer.apple.com/news/?id=09122019b

[^4_66]: https://digital.ai/catalyst-blog/flutter-secure-storage/

[^4_67]: https://www.youtube.com/watch?v=HrZ55sz1j9k

[^4_68]: https://www.reddit.com/r/FlutterDev/comments/1l7u6e9/secure_data_storage_in_flutter_using_flutter/

[^4_69]: https://leancode.co/glossary/secure-storage-in-flutter

[^4_70]: https://corewin.ua/en/blog-en/cheat-sheet-preventing-csrf/

[^4_71]: https://docs.talsec.app/appsec-articles/articles/secure-storage-what-flutter-can-do-what-flutter-could-do

[^4_72]: https://www.reddit.com/r/flutterhelp/comments/smy1j3/flutter_web_httponly_cookies_for_user_auth/

[^4_73]: https://www.youtube.com/watch?v=7DqH3SIP5MA

[^4_74]: https://stackoverflow.com/questions/78023348/httponly-session-cookies-can-be-read-accessed-within-flutter

[^4_75]: https://www.postgresql.org/docs/current/ddl-rowsecurity.html

[^4_76]: https://hasura.io/blog/row-level-security-with-postgres-via-hasura-authz

[^4_77]: https://pypi.org/project/fastapi-rowsecurity/

[^4_78]: https://dev.to/brianmmdev/an-introduction-to-postgres-row-level-security-rls-306k

[^4_79]: https://codesignal.com/learn/courses/implementing-rate-limiting-6/lessons/implementing-rate-limiting

[^4_80]: http://dobken.nl/posts/rls-postgres/

[^4_81]: https://www.reddit.com/r/django/comments/1rup8bv/ive_been_exploring_postgresql_rowlevel_security/

[^4_82]: https://bryananthonio.com/blog/implementing-rate-limiter-fastapi-redis/

[^4_83]: https://www.adrianovieira.eng.br/en/posts/architecture/row-level-security-sqlachemy-alembic-guide/

[^4_84]: https://pganalyze.com/blog/postgres-row-level-security-ruby-rails

[^4_85]: https://news.ycombinator.com/item?id=28717848

[^4_86]: https://www.ditto.com/blog/how-to-build-robust-offline-first-apps-a-technical-guide-to-conflict-resolution-with-crdts-and-ditto

[^4_87]: https://www.reddit.com/r/reactnative/comments/1dwlx8i/i_want_to_create_offline_first_and_sync_based/

[^4_88]: https://objectbox.io/customizable-conflict-resolution-for-offline-first-apps/

[^4_89]: https://dinkomarinac.dev/blog/building-local-first-flutter-apps-with-riverpod-drift-and-powersync/

[^4_90]: https://www.youtube.com/watch?v=hAfnkw4PEM4

[^4_91]: https://groups.google.com/g/meteor-talk/c/G2GA5s-VoZI/m/58oQ8BARHtMJ

[^4_92]: https://www.reddit.com/r/FlutterDev/comments/1cikn2d/offline_first_for_sql_database/

[^4_93]: https://www.youtube.com/watch?v=Spl22n4TFtU

[^4_94]: https://www.linkedin.com/posts/jorgeperalesdiaz_dotnet-dotnetmaui-offlinefirst-activity-7427049652673327105-k8FU

[^4_95]: https://www.reddit.com/r/crypto/comments/m9w2ea/password_storage_owasp_cheat_sheet_series/

[^4_96]: https://nicoduj.github.io/CheatSheetSeries/cheatsheets/Password_Storage_Cheat_Sheet.html

[^4_97]: https://toolsana.com/blog/password-hashing-2026-bcrypt-argon2-scrypt-pbkdf2-guide/

[^4_98]: https://guptadeepak.com/the-complete-guide-to-password-hashing-argon2-vs-bcrypt-vs-scrypt-vs-pbkdf2-2026/

[^4_99]: https://www.linkedin.com/pulse/password-storage-cheat-sheet-following-owasp-guidelines-dat-dao-kkxgc

[^4_100]: https://mojoauth.com/ciam-qna/password-hashing-best-practices-bcrypt-argon2

[^4_101]: https://github.com/OWASP/ASVS/issues/2535

[^4_102]: https://bellatorcyber.com/blog/best-password-hashing-algorithms-of-2023



# GPT 5.5 Thinking

1. Where the “models” agree
I’m treating “models” here as three viable architecture models for Quadrille:

Model A — Self-hosted pragmatic: keep FastAPI/Postgres, add first-party auth.

Model B — Managed-auth: use Supabase Auth / Firebase Auth / Auth0 / Clerk.

Model C — Local-first sync-first: optimize around offline profiles, merge semantics, and multi-device conflict handling.

Finding	Model A: self-hosted pragmatic	Model B: managed-auth	Model C: local-first sync-first	Evidence / reasoning
Accounts must be optional, not a gate before the app.	✓	✓	✓	Quadrille’s core product value is local-first gym use; offline-first apps should present local data immediately and remain usable without reliable network access.
Keep Drift/SQLite as the local source of truth.	✓	✓	✓	Offline-first architecture writes locally first and syncs later; the cloud is a replication target, not the thing required for every interaction.
Use per-user server scoping for sync state and push subscriptions.	✓	✓	✓	OWASP authorization guidance says access control must be enforced server-side on every request, not merely by client-side checks.
Do not offer social OAuth in v1 unless you are ready for the Apple login/privacy requirement on iOS.	✓	✓	✓	Apple’s guideline change still requires apps that offer third-party/social login to offer an equivalent privacy-focused login option; first-party account systems are a carveout.
Passwords should be hashed with Argon2id if self-hosting passwords.	✓	N/A	✓	OWASP’s password storage guidance recommends strong slow password hashing, and Argon2id is the modern preferred choice with published minimum parameters.
Web auth should avoid storing long-lived tokens in JS-accessible storage.	✓	✓	✓	HttpOnly cookies are the normal web answer for keeping auth tokens out of JavaScript, while mobile can use platform secure storage such as Keychain/Keystore via Flutter secure storage.
Whole-database last-write-wins becomes too risky once multiple real users/devices exist.	✓	✓	✓	Offline-first conflict strategies can begin with last-write-wins, but concurrent updates need at least object/row-level merge semantics; CRDTs are mainly justified for highly collaborative data.
RLS is useful but not mandatory for v1 if the app layer is small and well-tested.	✓	mixed	✓	Postgres RLS can enforce tenant isolation using runtime variables, but it has operational/testing footguns and should be treated as defense-in-depth rather than magic.
2. Where they disagree
Topic	Model A: self-hosted pragmatic	Model B: managed-auth	Model C: local-first sync-first	Why they differ
v1 auth provider	Build first-party email/password in FastAPI/Postgres.	Use Firebase/Supabase/Auth0/Clerk to avoid writing auth.	Provider matters less than preserving offline profiles and merge safety.	Managed auth reduces security code but adds identity/data-provider dependency; self-hosting preserves ownership and fits your existing VPS. Firebase has strong Flutter integration but is explicitly a hosted BaaS ecosystem.
Supabase Auth	Too much stack for this narrow need unless you already want Supabase.	Best managed-ish compromise because Supabase can be self-hosted.	Acceptable only if sync semantics stay under your control.	Supabase is self-hostable with Docker, but running the Supabase stack is more operational surface than adding auth tables to your current FastAPI app.
JWT vs opaque sessions	Prefer opaque server-side sessions for revocation and simplicity.	JWTs are common because providers issue them.	Prefer whatever makes multi-device revocation and local profile switching easiest.	JWTs shine for distributed stateless APIs; your API is same VPS/Postgres, so DB-backed opaque sessions are simpler to revoke and inspect.
RLS from day one	Optional defense-in-depth; app-level WHERE user_id = current_user.id is enough for the current two JSONB tables.	Supabase-style systems often lean heavily on Postgres RLS.	Defer RLS until/if sync becomes row-relational on the server.	RLS is powerful, but for a solo FastAPI app with two tenant tables, testable app-level scoping is lower-maintenance.
Sync upgrade now	Move from whole-DB LWW to row-level LWW snapshot merge.	Could adopt a full sync product later.	Strongly wants row-level merge before public accounts.	Public accounts make concurrent multi-device use likely; full CRDT is overkill, but whole-payload overwrite is no longer correct.
Sign-out behavior	Keep cached local profile by default; offer “remove from this device.”	Provider SDKs often think in terms of signing out of a global auth state.	Strongly prefers one local DB/profile per account.	Local-first apps need offline data after auth expires; privacy on shared devices needs profile separation and explicit local removal.
3. Unique insights
Source model	Unique insight	Why it matters
Self-hosted pragmatic	Use opaque DB-backed sessions, not JWT, because you already have a same-box Postgres and need revocation/multi-device session management.	This avoids JWT invalidation complexity and fits your low-scale VPS architecture.
Managed-auth model	Firebase/Supabase/Auth0/Clerk solve account security faster, but they shift identity custody and operational assumptions away from your VPS.	This is the key tradeoff: less auth code vs less ownership/control.
Local-first sync-first	The account system is not the hardest part; anonymous-local → account-local → cloud-merged profile migration is the hard part.	Bad profile/merge design can lose workout data even if auth itself is correct.
Security model	If you use social login on iOS, Apple’s privacy-equivalent login requirement enters the product scope.	Avoiding social login in v1 keeps App Store review simpler.
Ops model	Web Push subscriptions should be per user + device/subscription, not one row per account.	Rest-complete notifications should buzz the device that started the web timer, not every browser ever used by the user.
4. Comprehensive analysis
High-confidence recommendations
Use self-hosted email + password for v1. You already run FastAPI, Postgres, Apache, HTTPS, systemd, and Mandrill, so first-party email/password is the lowest-dependency solution that preserves data ownership and avoids the iOS social-login requirement. If you offer only your own account setup and sign-in system, you avoid the Apple “third-party/social login must also offer a privacy-focused equivalent” issue that would arise with Google/Facebook-style login on iOS.

Use opaque server-side sessions, not JWTs, for v1. JWTs are useful when you need stateless validation across many services, but Quadrille has one FastAPI service and one Postgres database on the same VPS. A random opaque session token stored hashed in Postgres gives you immediate revocation, per-device session lists, logout-all, password-reset invalidation, and simpler incident response. OWASP session guidance emphasizes that session IDs should be meaningless identifiers with server-side state, which matches opaque sessions well.

Use httpOnly Secure SameSite cookies on web, and bearer opaque tokens in mobile secure storage. The web app is same-origin at quadrille.app/api, so an httpOnly cookie is the right web primitive; Flutter mobile cannot rely on browser cookies, so it should store the same class of opaque session token in flutter_secure_storage, which uses platform secure storage such as iOS Keychain and Android Keystore/EncryptedSharedPreferences.
 Cookie-based auth needs CSRF defenses for state-changing requests; OWASP recommends CSRF tokens, Origin/Referer validation, custom headers, and SameSite cookies as layered mitigations.

Upgrade sync from whole-database LWW to row-level LWW snapshot merge before public multi-user accounts. You do not need full CRDTs for a personal lifting log, but you do need to stop treating the entire database payload as one object. The smallest correct evolution is: keep shipping full JSON snapshots, but merge by table + UUID row id using updated_at and deleted_at. Offline-first literature treats last-write-wins as a simple baseline and reserves CRDT/OT-style approaches for more collaborative data like documents/canvases.

Use one local profile/database per signed-in account per device. This is the cleanest answer to shared devices, sign-out, offline access, and “local-only mode.” The existing anonymous local DB becomes the “local profile.” On sign-up or sign-in, Quadrille either attaches that profile to the new account, merges it with an existing account profile, or leaves it separate.

Genuinely uncertain calls
Magic-link vs password. Magic-link/passwordless avoids password storage but makes email deliverability part of every login, and Mandrill outages/delays become auth outages. Since Quadrille is offline-first and users may install mobile apps where long-lived sessions are normal, email+password with verification/reset is more predictable for v1. Magic links can be added later as an alternative login method.

RLS now vs later. Postgres RLS can enforce tenant isolation using a runtime session variable like app.current_user_id, but it adds connection-pool discipline and debugging complexity.
 For v1, I would use app-level scoping with strong tests because your server-side tenant data is still basically sync_state and push_subscriptions. Add RLS when/if you decompose the JSON payload into relational server tables.

Access+refresh split. A strict access-token + refresh-token architecture is more standard for larger APIs. For Quadrille v1, a single opaque server-side session token with idle/absolute expiration is simpler. If you later want more hardening, evolve to short-lived opaque access tokens plus rotating opaque refresh tokens without changing user-facing UX.

5. Concrete recommended architecture
5.1 Chosen v1 auth method
Recommend: first-party email + password
Do this for v1:

Email + password.

Email verification required before cloud sync is enabled.

Password reset via Mandrill.

No Google/Apple/Facebook login in v1.

Optional local-only mode remains fully functional.

Why:

Keeps data and identity on your VPS.

Avoids Firebase/Auth0/Clerk lock-in.

Avoids App Store social-login implications.

Works naturally on web, iOS, and Android.

Lets you ship accounts without introducing a new platform stack.

Managed alternatives, fairly
Option	Pros	Cons	Recommendation
Supabase Auth hosted	Mature auth, Postgres-friendly, Flutter ecosystem.	Identity/session custody moves to Supabase; sync architecture may drift toward Supabase assumptions.	Good if you later want a broader Supabase backend; not necessary now.
Supabase self-hosted	Keeps data on your infrastructure; Supabase is self-hostable via Docker.
Much more operational surface than your current FastAPI/Postgres app.	Overkill for “add accounts to one sync bucket service.”
Firebase Auth	Excellent Flutter support, auth state listeners, many providers.
Google-managed identity and BaaS lock-in; outside your self-hosting preference.
Best if speed beats ownership; not my pick for you.
Auth0/Clerk	Strong security product, social login, admin tooling.	External identity provider, pricing/lock-in, less self-hosted.	Too much for Quadrille v1.
5.2 Session/token design
Core choice
Use opaque server-side sessions.

Token format:

text
qds1_<session_id_uuid>_<random_256_bit_secret>
Database stores:

text
session_id
user_id
hash(secret)
device metadata
created_at
last_seen_at
idle_expires_at
absolute_expires_at
revoked_at
The raw secret is never stored server-side.

Web credential storage
For Flutter web at quadrille.app:

text
Set-Cookie: __Host-quadrille_session=<opaque-token>;
  Path=/;
  Secure;
  HttpOnly;
  SameSite=Lax;
  Max-Age=2592000
Use __Host- cookie prefix if possible: no Domain, Path=/, Secure.

For state-changing web requests:

Require Origin: https://quadrille.app.

Reject missing/mismatched Origin/Referer.

Require X-Quadrille-CSRF header matching a CSRF token obtained from /api/auth/csrf.

Use SameSite=Lax or SameSite=Strict; Lax is usually less surprising, Strict is safer if it does not break email verification/reset flows.

Add CSP to reduce XSS risk, because OWASP notes XSS can defeat CSRF protections.

Mobile credential storage
For iOS/Android:

Return the opaque session token in the login/register response.

Store it in flutter_secure_storage.

Send it as:

text
Authorization: Bearer qds1_<session_id>_<secret>
flutter_secure_storage is the standard Flutter package for sensitive tokens and uses platform-specific secure storage mechanisms.

Expiration and revocation
For v1:

Idle timeout: 30 days since last_seen_at.

Absolute timeout: 180 days.

Rotate session secret on password reset, password change, and explicit “refresh session.”

Revoke current session on logout.

Revoke all sessions on password reset by default.

Store one row per device/session so users can see and revoke devices.

This is enough for Quadrille’s risk profile without introducing JWT invalidation complexity.

5.3 Password and account security
Password hashing
Use Argon2id via argon2-cffi or a well-maintained Python password library that supports Argon2id.

Initial parameters:

text
argon2id
memory_cost: at least 64 MiB if your VPS tolerates it; OWASP minimum is commonly cited at 19 MiB
time_cost: 2–3
parallelism: 1
salt: generated by library
OWASP recommends strong slow password hashing and Argon2id is the modern preferred choice; published OWASP minimums include Argon2id with 19 MiB memory, 2 iterations, and 1 degree of parallelism.

Password policy
Use a NIST-style policy:

Minimum 12 characters, ideally recommend 15+.

Allow at least 64 characters.

Allow spaces and Unicode.

No forced complexity rules.

Block common/breached passwords.

Do not force periodic password rotation unless compromise is suspected.

NIST-aligned guidance favors length, blocklists, and throttling over mandatory complexity rules.

Email verification
User can create account.

User cannot enable cloud sync until email is verified.

Verification tokens:

random 256-bit token

stored hashed

single-use

expires in 24 hours

resend rate-limited

Password reset
Use Mandrill for email.

OWASP forgot-password guidance recommends consistent responses for existent and non-existent accounts, random single-use expiring tokens, side-channel delivery, rate limiting, and not changing the account until a valid token is presented.

Flow:

POST /auth/password/forgot always returns 202 Accepted.

If account exists, send reset link.

Token expires in 30–60 minutes.

POST /auth/password/reset sets new password.

Revoke all sessions.

Send “password changed” email.

Do not auto-login after reset.

Rate limiting and lockout
Use layered throttling:

Per-IP login attempts.

Per-email login attempts.

Per-IP signup attempts.

Per-email password reset attempts.

Per-session sync write rate.

For low-maintenance v1, a Postgres-backed rate_limit_events table is fine. If traffic grows, add Redis/SlowAPI; SlowAPI is a FastAPI/Starlette rate-limiting library used for this purpose.

Avoid permanent account lockout because it enables denial-of-service against a victim’s email. Prefer exponential backoff/cooldown, e.g.:

text
1–5 failures: normal
6–10: increasing delay
10+: temporary 15-minute cooldown for that email+IP combination
5.4 Server schema changes: DDL sketch
Enable useful extensions:

sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
Users:

sql
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email CITEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  email_verified_at TIMESTAMPTZ,
  disabled_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
Sessions:

sql
CREATE TABLE auth_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  device_id TEXT,
  device_name TEXT,
  platform TEXT CHECK (platform IN ('web', 'ios', 'android', 'watchos', 'unknown')),
  user_agent TEXT,
  ip_created INET,
  ip_last_seen INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  idle_expires_at TIMESTAMPTZ NOT NULL,
  absolute_expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ
);

CREATE INDEX auth_sessions_user_idx ON auth_sessions(user_id);
CREATE INDEX auth_sessions_active_idx
  ON auth_sessions(user_id)
  WHERE revoked_at IS NULL;
Email verification and password reset tokens:

sql
CREATE TABLE auth_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose TEXT NOT NULL CHECK (purpose IN ('verify_email', 'password_reset')),
  token_hash TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ
);

CREATE INDEX auth_tokens_user_purpose_idx
  ON auth_tokens(user_id, purpose)
  WHERE consumed_at IS NULL;
Sync state, replacing account='default':

sql
CREATE TABLE user_sync_state (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  payload JSONB NOT NULL,
  revision BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
Devices:

sql
CREATE TABLE devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_device_id TEXT NOT NULL,
  platform TEXT NOT NULL,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, client_device_id)
);
Web Push subscriptions:

sql
CREATE TABLE push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX push_subscriptions_user_idx ON push_subscriptions(user_id);
CREATE INDEX push_subscriptions_device_idx ON push_subscriptions(device_id);
Durable web push jobs for rest timers:

sql
CREATE TABLE web_push_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID REFERENCES devices(id) ON DELETE CASCADE,
  push_subscription_id UUID REFERENCES push_subscriptions(id) ON DELETE SET NULL,
  kind TEXT NOT NULL CHECK (kind IN ('rest_complete')),
  payload JSONB NOT NULL,
  fire_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'sent', 'cancelled', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

CREATE INDEX web_push_jobs_due_idx
  ON web_push_jobs(fire_at)
  WHERE status = 'scheduled';
Auth events / audit:

sql
CREATE TABLE auth_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  email CITEXT,
  event_type TEXT NOT NULL,
  ip INET,
  user_agent TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
Rate limiting:

sql
CREATE TABLE rate_limit_events (
  id BIGSERIAL PRIMARY KEY,
  key TEXT NOT NULL,
  action TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX rate_limit_events_key_action_time_idx
  ON rate_limit_events(key, action, created_at);
5.5 FastAPI endpoint list
Auth:

text
POST   /api/auth/register
POST   /api/auth/login
POST   /api/auth/logout
POST   /api/auth/logout-all
GET    /api/auth/me
GET    /api/auth/sessions
DELETE /api/auth/sessions/{session_id}

POST   /api/auth/email/resend-verification
POST   /api/auth/email/verify

POST   /api/auth/password/forgot
POST   /api/auth/password/reset

GET    /api/auth/csrf
POST   /api/auth/session/rotate
Account:

text
GET    /api/account/export
DELETE /api/account
Sync:

text
GET    /api/sync
PUT    /api/sync
POST   /api/sync/merge-preview   optional, useful during migration/debugging
Devices and Web Push:

text
POST   /api/devices
PATCH  /api/devices/{device_id}
DELETE /api/devices/{device_id}

POST   /api/push/subscriptions
DELETE /api/push/subscriptions/{subscription_id}

POST   /api/push/rest-timer
DELETE /api/push/rest-timer/{job_id}
Admin/internal:

text
GET    /api/health
GET    /api/version
5.6 Multi-tenancy and authorization
Every authenticated endpoint derives current_user from the session token.

Every tenant query is scoped by user_id:

sql
SELECT payload, revision
FROM user_sync_state
WHERE user_id = :current_user_id;
Do not accept user_id from the client for ownership decisions.

For v1, use app-level scoping plus tests. Add RLS later if you decompose JSONB into relational server tables. If you do add RLS, use a runtime variable such as app.current_user_id and enable policies on tenant tables, but test with non-superuser DB roles because RLS has bypass/debugging footguns.

5.7 Push subscription mapping
Change from:

text
push_subscriptions(account PK, endpoint, p256dh, auth)
to:

text
user -> many devices -> many push subscriptions
Rest-complete web push should usually go to the device/subscription that started the timer, not all of a user’s devices.

When a web timer starts:

json
{
  "deviceId": "web-chrome-mbp-...",
  "subscriptionId": "...",
  "sessionId": "...",
  "timerId": "...",
  "fireAt": "2026-06-03T18:00:00Z"
}
If a subscription is gone/expired, mark it inactive.

5.8 Local-first account/profile strategy
Local profiles
Add a local profile_registry outside the workout DB or in a small global Drift DB:

text
profile_id
kind: local_only | account
user_id nullable
email nullable
db_name / db_path / indexeddb_name
last_opened_at
last_synced_revision nullable
created_at
Use separate local database namespaces:

text
quadrille_local.sqlite
quadrille_user_<user_id>.sqlite
For web IndexedDB/Drift:

text
quadrille_local
quadrille_user_<user_id>
This prevents Account A’s local data from appearing while Account B is signed in.

Sign-up from local-only data
If local-only user signs up:

Create account.

Verify email before cloud sync.

Convert current local profile to kind=account, attach user_id.

Upload current local snapshot as cloud revision 1 if server has no payload.

If server already has payload, run merge.

Sign-in on a device with existing local data
After login, if the device already has local-only data, show:

text
You have workout data on this device.

[Merge with this account]  recommended
[Keep separate as local-only]
[Replace this device with cloud data]
Default: Merge.

Merge algorithm
Use row-level LWW by table + UUID.

For each table:

text
exercises
workout_templates
template_exercises
workout_sessions
session_exercises
set_entries
app_settings
Rules:

If row exists only locally: keep it.

If row exists only in cloud: keep it.

If same UUID exists in both: choose row with later updated_at.

If either row has deleted_at, compare deleted_at to the other row’s updated_at; later timestamp wins.

Merge parent tables before child tables.

Validate foreign keys after merge.

For app_settings, split into:

account_settings synced

device_settings unsynced

You should add deleted_at to every synced local table before enabling multi-device accounts. Without tombstones, deletes will resurrect during merge.

Sign-out
On sign-out:

Revoke server session.

Clear auth credential.

Switch app to local-only profile or signed-out shell.

Prompt:

text
Keep this account’s offline data on this device?
- Keep local copy
- Remove from this device
Default on personal mobile: Keep.

Default on public/shared web, if you add such a mode later: Remove.

Keeping the DB does not keep sync credentials. It only preserves offline cache.

5.9 Sync model evolution
Current model
text
whole DB JSON payload
PUT replaces server payload
GET replaces local payload
revision increments
safe pull avoids clobber if local unsynced changes exist
This is acceptable for one user/one account but unsafe for real multi-device use because two devices can independently finish workouts and one whole payload can overwrite the other.

Recommended v2 sync
Keep the transport simple:

text
Client still sends full JSON snapshot.
Server no longer blindly replaces.
Server merges rows by table + UUID.
Server returns merged snapshot + new revision.
Payload v2:

json
{
  "format": "quadrille.backup",
  "version": 2,
  "clientId": "device-uuid",
  "baseRevision": 12,
  "generatedAt": "2026-06-03T17:30:00Z",
  "tables": {
    "exercises": [],
    "workout_templates": [],
    "template_exercises": [],
    "workout_sessions": [],
    "session_exercises": [],
    "set_entries": [],
    "account_settings": []
  }
}
Every synced row should include:

json
{
  "id": "...",
  "created_at": "...",
  "updated_at": "...",
  "deleted_at": null,
  "modified_by_device_id": "..."
}
Server behavior for PUT /sync:

text
1. Authenticate user.
2. Load existing user_sync_state payload.
3. If no existing payload: store incoming as revision 1.
4. If existing payload: row-merge existing + incoming.
5. Increment revision.
6. Store merged payload.
7. Return merged payload + revision.
Client behavior after push:

text
1. Send local snapshot + baseRevision.
2. Receive merged snapshot + revision.
3. Apply merged snapshot to local DB in a transaction.
4. Set lastSyncedRevision = revision.
5. Mark no local changes since sync.
This avoids full CRDT complexity while preventing loss of unrelated rows. It is not perfect if two devices edit the same exact set row offline, but that is rare and LWW is acceptable for a solo workout log. CRDTs are more justified for collaborative document-like data, not a single-user lifting tracker.

5.10 Flutter/Riverpod client architecture
Add these client layers:

text
lib/
  features/auth/
    data/
      auth_api.dart
      credential_store.dart
      auth_repository.dart
    application/
      auth_controller.dart
      auth_state.dart
    presentation/
      sign_in_screen.dart
      sign_up_screen.dart
      verify_email_screen.dart
      forgot_password_screen.dart
      reset_password_screen.dart
      account_screen.dart
      sessions_screen.dart

  core/profile/
    profile_registry.dart
    profile_database_factory.dart
    current_profile_controller.dart

  core/sync/
    sync_coordinator.dart
    sync_api.dart
    merge_service.dart

  core/push/
    push_subscription_controller.dart
Suggested Riverpod providers:

dart
final credentialStoreProvider = Provider<CredentialStore>((ref) => ...);

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(
  httpClient: ref.watch(httpClientProvider),
  credentialStore: ref.watch(credentialStoreProvider),
));

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(
  api: ref.watch(authApiProvider),
  credentialStore: ref.watch(credentialStoreProvider),
));

final authControllerProvider =
  AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

final profileRegistryProvider = Provider<ProfileRegistry>((ref) => ...);

final currentProfileProvider =
  AsyncNotifierProvider<CurrentProfileController, ProfileState>(
    CurrentProfileController.new,
  );

final syncCoordinatorProvider = Provider<SyncCoordinator>((ref) {
  final auth = ref.watch(authControllerProvider);
  final profile = ref.watch(currentProfileProvider);
  return SyncCoordinator(...);
});
Auth state:

dart
sealed class AuthState {
  const AuthState();
}

class LocalOnly extends AuthState {
  final ProfileId profileId;
}

class SignedOut extends AuthState {}

class SignedIn extends AuthState {
  final String userId;
  final String email;
  final bool emailVerified;
  final String sessionId;
}

class AuthUnknown extends AuthState {}
Route guarding with go_router:

Do not guard core app routes like /today, /templates, /history.

Guard only account-only routes like /account, /account/sessions, /sync/status.

If signed out and user opens /account, redirect to /account/sign-in.

If local-only, show banner/card: “Sign in to sync across devices.”

SyncCoordinator rules:

text
If LocalOnly:
  - no cloud sync
  - no server web push
  - local notifications still work

If SignedIn and emailVerified:
  - safe pull on launch
  - push on workout finish
  - register/update web push subscription
  - schedule web rest push using user_id + device_id

If SignedIn but email not verified:
  - allow local app
  - block cloud sync
  - show verify-email prompt
6. Phased build plan and migration path
Phase 0 — Backup and freeze
Before touching auth:

pg_dump the existing database.

Export the current sync_state(account='default') JSON payload to a file.

Export VAPID/subscription tables.

Save current server env and systemd unit.

Add /api/version so clients can detect auth-capable server.

Do this first because the current single shared token is not a safe public-account primitive.

Phase 1 — Add auth schema and server auth, no client dependency yet
Add tables:

users

auth_sessions

auth_tokens

auth_events

rate_limit_events

devices

user_sync_state

new push_subscriptions

Implement:

register

login

logout

me

verify email

forgot/reset password

sessions list/revoke

CSRF for web cookie mode

rate limiting

Do not remove old sync endpoints yet.

Phase 2 — Migrate the default bucket safely
The current default bucket should become your owner account’s cloud data, not a shared migration source for every new account.

Server-side:

Create your user row manually:

sql
INSERT INTO users (id, email, password_hash, email_verified_at)
VALUES (..., 'your-email@example.com', '<argon2id hash>', now());
Copy current default payload:

sql
INSERT INTO user_sync_state (user_id, payload, revision, updated_at)
SELECT '<your-user-id>', payload, revision, updated_at
FROM sync_state
WHERE account = 'default';
Copy push subscriptions only if you can associate them with a device; otherwise mark legacy subscriptions inactive and let clients re-register.

Keep the old sync_state table as legacy_sync_state or leave it read-only.

Important: do not let arbitrary new accounts “claim default.” That would expose your data.

Phase 3 — Ship client update with optional accounts
Client changes:

Add auth screens.

Add local profile registry.

Add signed-in profile DB namespace.

Remove embedded/shared bearer token.

Sync only when signed in.

On first sign-in, run merge flow.

Add “Local-only” mode as first-class UX.

For existing clients/devices:

They already have a local Drift DB.

After update, they continue local-only.

When you sign in, they merge local DB with your migrated account cloud payload.

No data loss because the local DB is not wiped.

Phase 4 — Replace whole-DB replace with row-level snapshot merge
Server:

Accept payload v1 temporarily.

Prefer payload v2.

Add generic row merge by table + UUID.

Add tombstone support.

Client:

Add deleted_at to all synced Drift tables.

Export payload v2.

Import payload v2 transactionally.

Store lastSyncedRevision per profile.

Keep hasLocalChangesSinceLastSync.

During this phase, keep old safe-pull behavior as a fallback, but authenticated clients should use merge.

Phase 5 — Web Push per user/device
Migrate:

text
old: push_subscriptions(account PK, endpoint, p256dh, auth)
new: push_subscriptions(user_id, device_id, endpoint, p256dh, auth)
Client:

Generate stable client_device_id.

Register device after sign-in.

Register push subscription against device.

Schedule rest-complete web push for current device only.

Phase 6 — Decommission legacy shared-token sync
After a grace period:

Old shared-token endpoint returns 426 Upgrade Required.

Keep the old default payload backup indefinitely.

Remove shared bearer token from server env.

Delete old push subscriptions or leave archived.

Confirm no logs show legacy sync traffic.

Suggested response for old clients:

json
{
  "error": "upgrade_required",
  "message": "Quadrille sync now requires accounts. Update the app; your local data remains on this device."
}
Phase 7 — Later hardening
Add later, not v1:

Optional magic-link login.

Optional passkeys/WebAuthn.

MFA/TOTP.

Postgres RLS defense-in-depth.

Short-lived access tokens + rotating refresh tokens if session risk increases.

Breached-password API/blocklist.

Admin dashboard for abuse monitoring.

Automated restore tests.

Full row-relational server sync or PowerSync-style sync if snapshot merge becomes limiting.

Final recommended architecture in one paragraph
Build Quadrille accounts as a self-hosted first-party email/password system in your existing FastAPI/Postgres backend, using Argon2id password hashes, opaque server-side sessions, httpOnly SameSite cookies on web, and secure-storage bearer sessions on mobile. Keep local-only mode as the default-capable baseline, introduce one local profile/database per account, and migrate cloud sync from whole-database replacement to row-level LWW snapshot merge with tombstones. Move the existing default bucket into your own owner account, never expose it as a public migration source, and let current clients keep their local data until they opt into sign-in and merge.

# Claude Opus 4.8 Thinking

The memory results confirm your profile (self-hosting preference, solo developer, comfort with Postgres/Apache/systemd, security-conscious, portfolio-minded). I have everything I need. This is a deep architecture question I can answer directly from established practice — no web research required.

Quadrille Accounts & Auth — Multi-Model Council Analysis
A note on method: you asked for a cross-model comparison, but this is a single-model deliberation. Rather than fabricate three distinct "models," I'll be honest — the tables below represent three reasoned architectural stances I'm holding in tension (a Pragmatist self-hosted view, a Managed-provider view, and a Correctness-first view), so you still get the disagreement surface you wanted without me pretending to be a council I'm not.

1. Where the Approaches AGREE
Finding	Pragmatist (self-host)	Managed (Supabase/Clerk)	Correctness-first	Reasoning
Accounts must be additive, never a gate	✓	✓	✓	Your explicit constraint; local-only mode stays the default path. Auth state is just one more Riverpod provider.
argon2id for password hashing	✓	✓	✓	Memory-hard, OWASP-recommended default over bcrypt for greenfield. Provider handles it for you in the managed case.
Per-user row keying replaces account="default"	✓	✓	✓	The account PK becomes user_id; this is the minimal correct multi-tenancy change.
httpOnly cookie on web, secure-storage bearer on mobile	✓	✓	✓	Same-origin web benefits from httpOnly (XSS-safe); cross-origin mobile can't use cookies cleanly, so bearer in flutter_secure_storage.
Don't wipe local DB on sign-out by default	✓	✓	✓	Local-first means local data has standalone value; wiping is destructive and surprising.
Email verification + reset over existing Mandrill SMTP	✓	✓	✓	You already have transactional email; reuse it.
Refresh-token rotation + server-side revocation list	✓	✓	✓	Stateless JWT alone can't revoke; a refresh-token table gives you logout-everywhere.
Sign in with Apple is mandatory if you ship Google/any social on iOS	✓	✓	✓	App Store Guideline 4.8 — if you offer third-party social login, Apple's is required. Avoid by shipping email-only.
2. Where They DISAGREE
Topic	Pragmatist	Managed	Correctness-first	Why they differ
Auth method for v1	Email+password	Magic-link (provider-issued)	Email+password, OAuth later	Pragmatist values zero new infra & total control; Managed values eliminating password-handling entirely; Correctness wants the well-trodden path with clear recovery semantics.
Build vs buy auth	Self-host in FastAPI	Supabase Auth	Self-host, but isolate behind interface	Data-ownership vs. velocity. Your stated self-host preference + existing FastAPI/Postgres tilts away from managed.
Token model	JWT access + opaque refresh	Provider JWT	Opaque server sessions everywhere	JWT scales statelessly but revocation is awkward; opaque sessions revoke trivially but require a DB hit per call (fine at your scale).
Sync model evolution	Keep whole-DB LWW, key per user	Move to provider real-time row sync	Move to row-level LWW now	Multi-device concurrency is the trigger. Whole-DB LWW silently loses the loser's edits when two devices diverge.
Local DB on shared device	One file, swap on profile change	Per-user DB file	Per-user DB file (namespaced)	Single file is simpler but risks cross-user leakage; per-user file is cleaner isolation.
Anonymous→account on first signup	Adopt local DB as the account	Upload then reconcile	Tag local rows with user_id, push	All agree on adopt, differ on mechanics.
3. Unique Insights
(Correctness-first) Whole-DB LWW is actively dangerous the moment you have two real devices. Today it's safe only because of your single-device guard ("apply only if no local changes since last sync"). With two phones both logging workouts offline, the second to sync silently overwrites the first's session. This is the single most important thing to fix alongside accounts — not after.

(Pragmatist) You don't need Postgres RLS. RLS is elegant but adds operational complexity (per-connection SET app.user_id, policy debugging). For a solo dev with a single trusted FastAPI process, app-level scoping (WHERE user_id = :uid enforced in one repository layer) is simpler and equally safe. Reserve RLS for when untrusted clients hit Postgres directly (the Supabase model) — which you're not doing.

(Managed) The "Sign in with Apple" trap is avoidable entirely by shipping email-only auth in v1. Guideline 4.8 only triggers when you offer third-party social login. Email+password/magic-link sidesteps the whole Apple-login implementation, App Store review risk, and the Apple private-relay email complexity. Strong argument for deferring all OAuth.

(Correctness-first) push_subscriptions is already wrong-shaped. It's account PK (one row). One user has many devices, each with its own push endpoint. It must become (user_id, device_id) → endpoint, and rest-complete pushes should go to the device that started the timer, not broadcast — otherwise your other phone buzzes mid-meeting.

(Pragmatist) Your UUID-PK choice already did the hard part. Because every row has a globally-unique ID and updated_at, moving from whole-DB to row-level LWW is cheap: the payload shape barely changes, and merges are deterministic per-row by updated_at.

4. Comprehensive Analysis
High-confidence recommendations
Self-host the auth. Given you already run FastAPI + Postgres 16 + Mandrill + Let's Encrypt, and explicitly prefer data ownership, adding a managed provider buys little and costs lock-in. Auth is a solved, well-documented problem in FastAPI. Confidence: high.

Email + password for v1, no social login. It avoids the Sign-in-with-Apple requirement entirely, works identically on all platforms, and you control recovery. Add OAuth in a later phase with Apple if you ever want it. Confidence: high.

argon2id, email verification, password reset, rate limiting on auth endpoints. Standard, non-negotiable. Confidence: high.

Hybrid tokens: short-lived JWT access (~15 min) + opaque refresh token stored server-side (rotating). Web stores both in httpOnly+Secure+SameSite cookies (same-origin = no CSRF token needed for SameSite=Strict on the API, but add a CSRF token for state-changing routes to be safe). Mobile stores the refresh token in flutter_secure_storage. Confidence: high.

Move to row-level last-write-wins now. Your UUID + updated_at schema makes this nearly free, and it's the correct fix for genuine multi-device use. Confidence: high — this is the part I'd push back hardest on if you tried to skip it.

Don't wipe local on sign-out; switch to a per-user local DB file. Confidence: high.

Genuinely uncertain calls
JWT vs. pure opaque sessions. At your scale (solo app, likely hundreds not millions of users), opaque server-side sessions are simpler and more correct (trivial revocation, no clock-skew/expiry juggling) at the cost of one indexed Postgres lookup per request — negligible. JWT is the "scales statelessly" choice but you don't need that scale. I lean opaque-refresh + short JWT access as a middle ground, but pure opaque sessions are a defensible, simpler alternative. This is a real judgment call.

Row-level LWW vs. full CRDT. CRDTs (e.g., per-field merge) are more correct but materially more complex. For a single-user-per-account app where the same person rarely edits the same set on two devices in the same offline window, row-level LWW is the right 90% solution. Full CRDT is over-engineering here. Medium confidence.

One shared local DB with swap vs. per-user file. Per-user file is cleaner; shared-device-multi-user is probably rare for a personal lifting app. Low stakes either way.

5. Recommended Architecture (Concrete)
Auth method
Email + password, self-hosted in FastAPI. No social login in v1. (Sidesteps Apple Guideline 4.8 entirely.)

Session/token design
Access token: JWT, ~15 min, HS256 (single server — no need for asymmetric keys yet), claims: sub=user_id, exp, jti.

Refresh token: opaque random 256-bit, hashed (sha256) in DB, rotated on every use, with reuse-detection (if a already-rotated token is presented → revoke the whole token family = stolen-token defense).

Web (same-origin): both tokens in HttpOnly; Secure; SameSite=Strict cookies. Add a double-submit CSRF token for mutating routes as belt-and-suspenders.

Mobile (cross-origin): refresh token in flutter_secure_storage; access token in memory; sent as Authorization: Bearer.

Revocation / multi-device: each refresh token row = one device session; "log out everywhere" = delete all rows for user_id.

Server schema changes (DDL sketch)
sql
-- Identity
CREATE TABLE users (
  id            TEXT PRIMARY KEY,              -- UUID, matches your client convention
  email         CITEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,                 -- argon2id
  email_verified BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE email_tokens (                    -- verification + password reset
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  purpose    TEXT NOT NULL CHECK (purpose IN ('verify','reset')),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at    TIMESTAMPTZ
);

CREATE TABLE refresh_tokens (                  -- one row per device session
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id   TEXT NOT NULL,                   -- rotation family for reuse-detection
  token_hash  TEXT NOT NULL,
  device_label TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL,
  revoked_at  TIMESTAMPTZ
);
CREATE INDEX ON refresh_tokens(user_id);

-- Sync: migrate from account="default" to per-user
-- Option A (keep JSONB bucket, just rekey) — minimal:
ALTER TABLE sync_state RENAME COLUMN account TO user_id;
-- Option B (recommended): row-level sync table
CREATE TABLE synced_rows (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  table_name  TEXT NOT NULL,                   -- 'set_entries', 'workout_sessions', ...
  row_id      TEXT NOT NULL,                   -- the row's UUID PK
  payload     JSONB NOT NULL,                  -- the full row
  updated_at  TIMESTAMPTZ NOT NULL,            -- LWW key
  deleted     BOOLEAN NOT NULL DEFAULT false,  -- tombstone
  server_seq  BIGSERIAL,                       -- monotonic cursor for delta pull
  PRIMARY KEY (user_id, table_name, row_id)
);
CREATE INDEX ON synced_rows(user_id, server_seq);  -- cursor-based delta pull

-- Push: one row per device, not per account
DROP TABLE push_subscriptions;
CREATE TABLE push_subscriptions (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id  TEXT NOT NULL,
  endpoint   TEXT NOT NULL,
  p256dh     TEXT NOT NULL,
  auth       TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);
FastAPI endpoint list
text
# Auth
POST   /api/auth/signup            {email, password} → sends verify email
POST   /api/auth/verify            {token}
POST   /api/auth/login             {email, password} → sets cookies / returns tokens
POST   /api/auth/refresh           (rotates refresh, issues new access)
POST   /api/auth/logout            (revoke current refresh)
POST   /api/auth/logout-all        (revoke all families for user)
POST   /api/auth/password/forgot   {email} → reset email
POST   /api/auth/password/reset    {token, new_password}
GET    /api/auth/me                → current user

# Sync (row-level, per-user, auth-gated)
GET    /api/sync/changes?since=<server_seq>     → delta of synced_rows
POST   /api/sync/changes           {rows:[{table,row_id,payload,updated_at,deleted}]}
                                    → server applies LWW by updated_at, returns new cursor

# Push
POST   /api/push/subscribe         {device_id, endpoint, p256dh, auth}
DELETE /api/push/subscribe         {device_id}

# Account / GDPR
GET    /api/account/export         → full JSON (you already have this)
DELETE /api/account                → cascade-delete all user data
Rate-limit signup, login, password/forgot, verify (e.g., slowapi or Apache-level mod_qos). Lockout: exponential backoff per email+IP after N failures rather than hard lock (avoids account-lockout DoS).

Flutter / Riverpod auth-state design
dart
// Single source of truth for auth
sealed class AuthState {}
class AuthLocalOnly extends AuthState {}      // no account — default, fully functional
class AuthAuthenticated extends AuthState { final User user; }
class AuthLoading extends AuthState {}

final authProvider = AsyncNotifierProvider<AuthController, AuthState>(...);
// AuthController: login/signup/logout, holds tokens, refreshes access on 401.

// go_router: NO global gate. Auth only guards account-specific screens
// (e.g., /account, /sync-settings). The whole app works in AuthLocalOnly.
final routerProvider = Provider((ref) => GoRouter(
  redirect: (ctx, state) {
    final auth = ref.read(authProvider).valueOrNull;
    final needsAuth = state.matchedLocation.startsWith('/account');
    if (needsAuth && auth is! AuthAuthenticated) return '/login';
    return null; // everything else passes — local-first preserved
  },
));

// SyncCoordinator keys off authProvider:
//  - AuthLocalOnly  → sync disabled, app fully usable
//  - Authenticated  → push-on-finish + delta pull-on-launch using user's token
// Web Push subscription registers (user_id, device_id) on login, removes on logout.
Local-first merge strategy (the hard part)
Per-user local DB file: quadrille_<user_id>.sqlite, plus quadrille_local.sqlite for anonymous mode. Drift opens the file matching current auth state.

First signup while having anonymous local data: Adopt. Rename/copy quadrille_local.sqlite → quadrille_<user_id>.sqlite, stamp all rows with user_id if you add that column locally (optional — server assigns it), bump updated_at, then push everything via /api/sync/changes. No data loss; the new account simply is your existing data.

Sign-in on a device that already has its own anonymous data, account also has cloud data: Offer a one-time choice: Merge (recommended default — run row-level LWW union of local + cloud) or Keep cloud only. Because PKs are UUIDs, merge is a safe union: same-id rows resolve by updated_at; disjoint rows all survive. This is exactly why your UUID choice pays off.

Sign-out: Keep the per-user DB file on disk (don't wipe), switch back to quadrille_local.sqlite (or an empty one). Re-sign-in reopens the file. Provide an explicit "Remove account data from this device" action for shared/public machines.

Conflict resolution: row-level LWW by updated_at, with tombstones for deletes (so a delete on device A isn't resurrected by a stale row from device B). Ties broken by user_id+row_id lexical order for determinism.

6. Phased Build Plan (solo, self-hosted) + Migration
Phase 0 — Migration prep (no client changes, ~½ day)
Add users, refresh_tokens, email_tokens, new synced_rows, new push_subscriptions tables alongside existing ones.

Backfill the "default" bucket: create a real user for yourself (you're the only current synced client). Insert a users row, then explode the existing sync_state.payload JSONB into per-row synced_rows entries under your user_id (one-time script: iterate each table array in the backup payload, insert row with its updated_at). Keep sync_state read-only as a fallback for one release.

Phase 1 — Minimal viable accounts (the core)
FastAPI: signup/login/verify/refresh/logout + argon2id + Mandrill verify email + rate limits.

Switch sync endpoints to auth-gated, per-user, row-level (/api/sync/changes). Keep the old single-token route alive temporarily, returning a "please update" signal.

Flutter: authProvider, login/signup/verify/reset screens, optional-account UX ("Use without account" is the prominent default button). SyncCoordinator keys off authProvider.

Per-user local DB file + the adopt-on-first-signup flow.

Cut your own device over: log in as your backfilled user → it adopts/merges cleanly → retire the shared bearer token from env.

Phase 2 — Multi-device correctness
Delta pull via server_seq cursor; tombstones for deletes; the merge-on-sign-in chooser.

Per-device push subscriptions; rest-complete push targets the timer-originating device.

"Log out everywhere" + device/session list in /account.

Phase 3 — Hardening & ops
Password reset polish, refresh-token reuse-detection, exponential backoff lockout.

GDPR: wire /api/account/export (reuse JSON export) and DELETE /api/account (cascade).

Observability: structured logs on auth endpoints, fail2ban or slowapi on signup/login, alert on signup spikes. Secrets: move JWT signing key + SMTP creds out of plain env into your 1Password-backed workflow (consistent with how you're already handling SSH secrets).

Optional later: OAuth (Google) with Sign in with Apple — only if you decide social login is worth the Apple compliance work.

Migration safety summary
No client loses data: your one existing client becomes a real account whose data is the backfilled synced_rows; first login adopts the matching local DB.

Rollback path: keep sync_state and the shared-token route for one release so you can revert if the row-level path misbehaves.

The "default" bucket is converted once, then frozen, then deleted after you confirm your account syncs correctly across two devices.

The one thing I'd insist on: do the row-level LWW migration at the same time as accounts, not later. The moment two real users (or your phone + your web client) both edit offline, whole-DB LWW will silently eat someone's workout — and a lifting log that loses a logged PR is exactly the trust-breaking failure that makes people go back to paper.

Want me to write the actual FastAPI auth router (argon2id + JWT + rotating refresh) and the one-time sync_state → synced_rows backfill script next?

# Gemini 3 Pro Thinking

Here is the architectural synthesis and concrete implementation plan for Quadrille’s user-account and authentication system. I have modeled three distinct architectural perspectives to pressure-test the design: Model A (Pragmatic/Minimalist), Model B (Security/Cloud-Native), and Model C (Local-First/CRDT Purist).

1. Where the Models AGREE
Finding	Models	Evidence / Reasoning
Keep Auth Self-Hosted	A, B, C	Using a managed provider (Auth0/Firebase) violates the "data stays on my VPS" preference, fragments your backups, and creates lock-in. FastAPI has excellent built-in security tooling (e.g., passlib, fastapi.security).
Require deleted_at for Sync	A, B, C	Whole-DB Last-Write-Wins (LWW) is guaranteed to destroy data once multiple devices are used concurrently. Moving to row-level sync requires soft deletes (tombstones), otherwise, a row deleted on Device A will be resurrected by Device B.
Optional Auth / Local-First	A, B, C	The app must function fully without a network request. The authProvider should default to a "Guest/Local" state. Sign-up is simply attaching an identity to the existing local SQLite DB.
Wipe Local DB on Sign-Out	A, B, C	On a shared device, signing out must DELETE FROM all tables to prevent the next user from seeing or merging the previous user's data.
Argon2id for Passwords	A, B, C	Argon2id is the current OWASP/NIST standard for password hashing, superior to bcrypt for resisting GPU/ASIC cracking.
2. Where the Models DISAGREE
Topic	Model A (Pragmatic)	Model B (Security/Cloud)	Model C (Local-First Purist)	Why They Differ
Auth Method	Email + Password	Magic Links (Email only)	Email + Password	Model B wants to avoid password reset/storage logic completely. Models A/C recognize that gym connectivity is often poor; waiting for an email to log in while standing at the rack is terrible UX.
Token Model	Opaque Session IDs	JWTs (Access + Refresh)	Opaque Session IDs	Model B optimizes for stateless scaling. Models A/C note that with a single VPS and low API load (syncing only after workouts), DB lookups for opaque tokens are fast, simpler, and allow instant revocation.
Token Transport	Split: Cookies (Web) + Bearer (Mobile)	Bearer Tokens everywhere	Cookies everywhere	Web is same-origin (quadrille.app), making httpOnly cookies perfectly secure against XSS. Mobile doesn't use the DOM, so secure-storage Bearer tokens are standard.
Sync Evolution	Server-side Row-Level Merge	Client-side CRDTs	Delta Sync (Push only changes)	A wants the server to diff the JSON to keep the client dumb. B/C want the client to only send modified rows since last_sync to save bandwidth.
3. Unique Insights
Model A (Sign in with Apple Trap): If you implement Google or Apple OAuth, Apple's App Store Review Guidelines (4.8) strictly require you to implement Sign in with Apple. As a solo dev, managing Apple's convoluted OAuth keys is a massive headache. Stick strictly to Email + Password to completely bypass this App Store requirement.

Model B (Push Notification Fan-out): When User A finishes a workout on their Phone, the Phone pushes to the server. The server must push the rest-complete notification to all of User A's registered devices, except the device that originated the push, to avoid double-notifying the active device.

Model C (The "Guest Merge" Race Condition): If a user uses the app anonymously, then logs into an existing account, simply pushing their local DB might overwrite cloud data. The client must pull the cloud DB first, do a local row-level merge, and then push the combined result.

4. Comprehensive Analysis & Decisions
Auth Method: Email + Password. It is the most robust for low-connectivity environments, avoids App Store OAuth traps, and keeps you entirely self-hosted.
Token Model: Opaque session tokens (e.g., a 256-bit secure random string stored in Postgres). JWTs introduce unnecessary complexity (signing keys, refresh token rotation) for a solo-hosted app. Postgres can easily handle a session lookup for a few users.
Token Transport:

Web: httpOnly, Secure, SameSite=Lax cookies. This totally neutralizes XSS token theft.

Mobile: Bearer token in the Authorization header, stored via flutter_secure_storage.

FastAPI: The dependency injection should check the Cookie first, fallback to the Bearer header.
Sync Evolution: You must abandon whole-database LWW. With multiple devices, if the phone is offline, you edit a template on the web, then log a workout on the phone, the phone's next whole-DB push will erase the web's template edit. You must add deleted_at to all tables and implement Row-Level Last-Write-Wins based on updated_at.

5. Concrete Recommended Architecture
Server Schema Changes (PostgreSQL)
sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE sessions (
    token VARCHAR(64) PRIMARY KEY, -- Opaque token
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    device_name VARCHAR(255),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Modify existing tables
ALTER TABLE sync_state RENAME COLUMN account TO user_id;
ALTER TABLE sync_state ALTER COLUMN user_id TYPE UUID USING user_id::uuid;
-- Payload remains JSONB, but now represents the merged state of all rows.

ALTER TABLE push_subscriptions RENAME COLUMN account TO user_id;
ALTER TABLE push_subscriptions ALTER COLUMN user_id TYPE UUID USING user_id::uuid;
ALTER TABLE push_subscriptions ADD COLUMN device_id UUID; -- To prevent self-notifying
FastAPI Endpoints
POST /api/auth/register (creates user, hashes with passlib[argon2])

POST /api/auth/login (verifies hash, generates secrets.token_urlsafe(32), stores in sessions. Returns JSON with token for mobile, AND sets Set-Cookie for web).

POST /api/auth/logout (deletes session token).

POST /api/auth/reset-password (sends Mandrill SMTP email with a short-lived signed token).

GET /api/sync and POST /api/sync (protected by depends(get_current_user)).

Flutter / Riverpod Client Architecture
Auth State:

dart
// null = loading, User.guest() = offline/anonymous, User.authenticated() = logged in
final authProvider = StateNotifierProvider<AuthNotifier, UserState?>(...);
Routing: No hard route guards! go_router simply shows a "Sign In / Create Account" button in the Settings tab if the state is Guest. The app remains fully functional.

Local-First Merge Logic (The Core Algorithm):
When transitioning from Guest → Authenticated:

Fetch cloud JSON payload.

Iterate through every table/row in the cloud JSON.

For each row, look up the UUID in the local SQLite DB.

If Local updated_at > Cloud updated_at, keep Local.

If Cloud updated_at > Local updated_at, overwrite Local.

If UUID doesn't exist locally, insert it.

Push the newly merged SQLite DB back to the cloud.

Sign Out:

Call POST /api/auth/logout.

drift_db.customStatement('PRAGMA foreign_keys = OFF; DELETE FROM table1; ...')

Set authProvider back to Guest.

6. Phased Build & Migration Plan
This is designed for a solo developer to deploy without breaking the live app.

Phase 1: Soft Deletes & Row-Level Sync (Client & Server)
Client: Add deleted_at (nullable DateTime) to all Drift tables. Update your queries to WHERE deleted_at IS NULL.

Server: Update the /api/sync POST endpoint. Instead of blindly overwriting the JSONB payload, write a Python function that loads the old JSON, loads the new JSON, and merges them dictionary-by-dictionary, comparing updated_at for every UUID. Save the merged result.

Deploy: Ship this. The app still uses the single "default" token, but you are now immune to concurrent data loss.

Phase 2: Server Auth & Migration Setup
Server: Create the users and sessions tables.

Migration Script: Manually create a user for yourself in the DB (e.g., jacob@example.com). Write a SQL script that updates the sync_state and push_subscriptions rows where account = 'default' to user_id = <your_new_uuid>.

API Update: Update the API dependencies. If a request has the old environment bearer token, temporarily map it to your new user_id so your active mobile app doesn't immediately break.

Phase 3: Client Auth UI
Client: Build the Login/Signup screens in Flutter.

Secure Storage: Implement flutter_secure_storage to hold the session token on mobile.

Network Interceptor: Update your Dio/HTTP client to attach the Cookie (web) or Bearer token (mobile).

Deploy: Ship the mobile/web updates. Log into your account via the UI. Once logged in, the client will pull your existing data (mapped in Phase 2).

Phase 4: Clean Up & Hardening
Server: Remove the legacy "default" bearer token fallback from the API.

Rate Limiting: Add slowapi to limit /api/auth/login to 5 requests/minute per IP to prevent brute force.

Push Fan-out: Update the pywebpush logic to iterate through all push_subscriptions for the user_id and fire them, ensuring multi-device timers work correctly.