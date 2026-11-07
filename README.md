# discourse-btcpay-subscriptions

[![Linting and Tests](https://github.com/criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml/badge.svg)](https://github.com/criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml)

**ENGLISH** | [ESPAÑOL](README.es.md)

Maintained by Criptonautas. Not affiliated with or endorsed by Discourse (Civilized Discourse Construction Kit, Inc.).

BTCPay Server subscription integration for Discourse. Sells group access for any crypto BTCPay supports — BTC, XMR, LTC, Lightning — with prices set in fiat. Self-contained: no Stripe and no `discourse-subscriptions` needed.

## Architecture

```
User clicks "Pay with crypto" on Discourse
    → Discourse creates checkout via BTCPay Greenfield API
    → User redirected to BTCPay checkout page
    → User pays → BTCPay settles invoice
    → BTCPay fires webhook → Discourse adds user to group
    → Reconciliation cron catches any missed webhooks (interval is a setting)
```

BTCPay owns the subscription lifecycle. Discourse manages group membership and displays status.

## Requirements

- Discourse 3.4+ (developed and CI-tested against `latest`; the frontend uses `.gjs` components, `discourse/truth-helpers` and `discourse-i18n`, none of which exist on older lines)
- BTCPay Server 2.3+ (with Subscriptions feature)
- Both on the same server (or network-accessible to each other)
- Nginx reverse proxy with valid SSL

## Installation

### 1. Install the plugin

Edit your Discourse `app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/criptonautas/discourse-btcpay-subscriptions.git
```

Rebuild Discourse:

```bash
cd /var/discourse
./launcher rebuild app
```

### 2. Configure BTCPay Server

1. Go to **BTCPay Server → Your Store → Subscriptions**
2. Create an **Offering** and one or more **Plans** priced in fiat (e.g., "Premium Monthly — $10/mo")
3. Note the **Offering ID** and the **Plan ID** of each plan — plans live inside an offering
4. Go to **Account → Manage Account → API Keys**
5. Create an API key with these permissions:
   - `btcpay.store.canviewofferings` — read the offering and its plans, read subscribers
   - `btcpay.store.canmanagesubscribers` — create plan checkouts and portal sessions
   - `btcpay.store.canviewinvoices` — read settled invoices for the payment history
   - `btcpay.store.canviewstoresettings` — server/network panel in the Discourse admin page
6. Go to **Store Settings → Webhooks**
7. Create a webhook:
   - **URL:** `https://yourdiscourse.com/btcpay/webhook`
   - **Events:** `PlanStarted`, `SubscriberCreated`, `SubscriberActivated`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `SubscriberCharged`, `SubscriberCredited`, `SubscriberNeedUpgrade`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`
   - **Secret:** Generate and save this — you'll need it for Discourse settings
8. Under **Checkout Appearance**, ensure redirect URLs are allowed

### 3. Configure Discourse

Go to **Admin → Settings** and search for `btcpay`:

| Setting | Value |
|---------|-------|
| `btcpay_enabled` | ✓ |
| `btcpay_server_url` | `https://btcpay.yourdomain.com` |
| `btcpay_api_key` | Your Greenfield API key |
| `btcpay_store_id` | Your BTCPay Store ID |
| `btcpay_offering_id` | The Offering ID holding your plans |
| `btcpay_webhook_secret` | The secret from step 7 above |
| `btcpay_default_group` | Optional: one group for all plans |
| `btcpay_send_email` | ✓ (skips BTCPay's email prompt) |
| `btcpay_anonymous_checkout` | Optional: let logged-out visitors buy |
| `btcpay_card_payments` | Optional: add a "Pay with card" button (needs BTCPay's Stripe plugin) |
| `btcpay_button_label` | blank (uses the translation) |

**Plans need no configuration.** Every plan in the offering is fetched from BTCPay with its live price, and each one grants a Discourse group resolved in this order:

1. **The group you pick on Admin → Plugins → BTCPay** — each plan row has a group dropdown.
2. **`discourse_group` in the plan's own BTCPay metadata** — set it on the plan in BTCPay and Discourse needs no configuration at all.
3. **`btcpay_default_group`** — one group for every plan that has none of its own, which is all a single-tier forum needs.

A plan that resolves to no group is listed on the admin page with a warning and is not offered for sale.

**Descriptions per language.** Add `description_es`, `description_en` (any Discourse locale code) to the plan's BTCPay metadata and each viewer sees the one for their locale; the plan's own description is the fallback. Markdown works in all of them.

### Embedding the plans in a post

Wrap anything in a post with the plugin's own wrap and the plan picker renders inline, for the viewer, with their current plan already marked:

```
[wrap=btcpay-plans][/wrap]
```

Nothing else is needed — no setting, no theme component. The donations theme
component owns the `donate*` wraps, this plugin owns `btcpay-plans`, so the two
never collide and either can be installed without the other.

The plugin adds no sidebar link of its own: link `/tickets` wherever it belongs
on your forum, or embed the picker in a pinned topic and skip the page.

### Customising the text

Every user-facing string is translated (English and Spanish ship with the plugin) and can be overridden two ways:

- **Site settings** for the headline strings — `btcpay_button_label`, `btcpay_tickets_title`, `btcpay_tickets_intro`, `btcpay_billing_title`, `btcpay_billing_intro`, `btcpay_nav_label`. Leave one blank and the translation for each viewer's locale is used; fill it in and that exact text is shown to everyone.
- **Admin → Customize → Text** for anything else, including per-locale overrides. Search for `btcpay.` to find every key.

### 4. Nginx Configuration

If BTCPay and Discourse share a server, add to your Discourse nginx config:

```nginx
# BTCPay webhook endpoint — allow BTCPay to reach Discourse
# This is handled by Discourse's built-in routing, so no extra
# proxy_pass is needed. Just ensure the /btcpay/ path isn't
# blocked by any existing rules.

# If BTCPay is on a separate domain/port and needs to reach
# Discourse internally, you can add:
location /btcpay/webhook {
    proxy_pass http://unix:/var/discourse/shared/standalone/nginx.http.sock;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

If both services are behind the same nginx with valid SSL, webhooks from BTCPay to Discourse will work over `https://` using the public URL.

For same-server setups where BTCPay calls localhost, you may configure the webhook URL as `https://yourdiscourse.com/btcpay/webhook` (going through the public proxy) to ensure SSL is used for HMAC validation integrity.

## How It Works

### Webhook Events

| BTCPay Event | Plugin Action |
|---|---|
| `PlanStarted` | Activates the subscription, adds the user to the mapped group |
| `SubscriberPhaseChanged` | Trial/Normal/Grace update the record; Expired revokes the group |
| `SubscriberDisabled` | `Expired` → expired, `Suspension` → cancelled; removes from group |
| `InvoiceProcessing` | Marks the subscription "pending" — no group access yet |
| `InvoiceReceivedPayment` | Records an unconfirmed payment so the page can show progress |
| `InvoicePaymentSettled` | Flips that payment to confirmed |
| `InvoiceSettled` | Records the payment (and grants access if `PlanStarted` was missed) |
| `InvoiceExpired` | Clears a `pending` record — an unpaid invoice never grants access |
| `InvoiceInvalid` | Marks "disputed", keeps group access, notifies admin |
| `SubscriberCreated` | Records the BTCPay customer id — no access granted |
| `SubscriberActivated` | Restores access after an unsuspension |
| `SubscriberCharged` | Records a renewal paid from the subscriber's BTCPay credit |
| `SubscriberCredited` | Records a credit top-up in the payment history |
| `SubscriberNeedUpgrade` | Flags the account and PMs an admin; access untouched |

Three of BTCPay's invoice events are missing from the Greenfield swagger but do exist and appear in the webhook UI — the plugin handles all three:

| Webhook UI label | Event type | What the plugin does |
|---|---|---|
| Invoice - Expired Paid Partial | `InvoiceExpiredPaidPartial` | PMs an admin with the amount received; clears the pending record |
| Invoice - Paid Late | `InvoicePaidAfterExpiration` | PMs an admin — the invoice had expired, so BTCPay granted nothing and the money is sitting there |
| Invoice - Refund | `InvoiceRefund` | PMs an admin with the pull payment id; group access is left alone |

The same facts also arrive as flags on the documented events, and are handled there too, deduplicated per invoice so ticking both boxes does not double-alert:

| Fact | Flag | What the plugin does |
|---|---|---|
| Partial payment | `InvoiceExpired.partiallyPaid` | Same alert as `InvoiceExpiredPaidPartial`, sent once |
| Late payment | `InvoiceReceivedPayment.afterExpiration` | Stored on the payment progress entry |
| Overpayment | `InvoiceSettled.overPaid` | PMs an admin to refund the difference from BTCPay |
| Marked paid by hand | `InvoiceSettled.manuallyMarked` | Logged, so a manual settle is traceable |

Not subscribed: `InvoiceCreated` (nothing to do yet) and `PaymentReminder` (BTCPay emails the subscriber itself).

### Trials, grace periods and tier changes

- **Trials and grace** come from BTCPay's subscription phase (`Trial`, `Normal`, `Grace`, `Expired`). The billing tab shows "Trial ends …" during a trial and "Payment overdue — access continues until …" during grace; access is only revoked when BTCPay reports `Expired` or disables the subscriber.
- **Payment progress**: on-chain payments take minutes to hours, so `InvoiceReceivedPayment` / `InvoicePaymentSettled` are mirrored into a short-lived record and shown live on the page — "0.0004 received via BTC — unconfirmed" — instead of leaving the payer staring at nothing. It is cleared when the invoice settles, expires or is invalidated.
- **Upgrades**: a subscriber picking a more expensive plan gets a checkout with `onPayBehavior: HardMigration`, so the new tier starts immediately and BTCPay refunds the unused part of the old one. The new plan's group is added on `PlanStarted`.
- **Downgrades are not implemented yet**: the cheaper plan is shown but not selectable, and the server rejects it with 422 even if the client is bypassed. Prices are compared against BTCPay's own plan prices, never the client's.

### Safety Mechanisms

- **HMAC validation** on every webhook with consecutive-failure alerting
- **Idempotent processing** — duplicate invoice deliveries are safely ignored
- **Reconciliation cron** catches missed webhooks (`btcpay_reconcile_interval_hours`, default 4)
- **Rate limits** — 60 webhook deliveries/min per IP, 5 checkouts/min and 20/hour per user
- **user_id based mapping** — immune to Discourse username changes
- **Admin PMs** for: HMAC failures, missing groups, refund disputes

### User Flow

1. User opens `/tickets`, or a post with the plan picker embedded in it
2. Picks a plan — the price shown is the fiat price BTCPay charges, fetched live and cached for 10 minutes
3. Clicks **Pay with crypto** → BTCPay's checkout opens in a modal over the page; the user never leaves Discourse
4. Pays with any method the store accepts (BTC, XMR, LTC, Lightning, …)
5. `InvoiceProcessing` marks the subscription pending; the page polls and flips to "Payment received" once `InvoiceSettled` grants the group
6. Status and payment history live on the profile's **Billing** tab (`/u/<username>/billing`), linked from the profile nav; with no active subscription that tab offers the plans instead
7. On renewal: BTCPay sends the reminder → user pays → access continues. On lapse: webhook fires → user removed from group

If the modal script cannot load (CSP, offline BTCPay asset host), the button falls back to a full redirect to BTCPay and back to `btcpay_redirect_after_checkout`.

## PluginStore Schema

```
# All rows live under plugin_name = "discourse-btcpay-subscriptions"

sub:{user_id}          → { customer_id, offering_id, plan_id, plan_name,
                           group_name, status, phase, auto_renew, period_end,
                           trial_end, grace_period_end, next_plan_id,
                           next_plan_name, next_plan_at, needs_upgrade,
                           updated_at }

payments:{user_id}     → [ { invoice_id, amount, currency, payment_method,
                             status, paid_at }, ... ] (last 100)

progress:{user_id}     → { invoice_id, payments: [ { id, value, method, status,
                           settled, after_expiration, received_at } ],
                           updated_at }   (cleared when the invoice resolves)

processed_invoices     → [ "invoice_id", ... ] (last 1000, settlement idempotency)

alerts                 → [ "partial:INV1", "over:INV2", ... ] (last 500, one-shot
                           admin alerts)

hmac_failures          → { count, last_at }

reconcile_last_run_at  → ISO8601 timestamp of the last completed sweep
reconcile_cursor       → key the next reconcile tick resumes from ("" = start)
```

Inspect them with:

```sql
SELECT key, value FROM plugin_store_rows
WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

### What leaves your forum

Each checkout sends BTCPay the payer's **Discourse user id and username**, and the plan id, as invoice and subscriber metadata. Nothing else — no email, no posts, no IP. BTCPay returns a customer id, plan and period data, and payment amounts, which are stored in the plugin store as described above. The only external host contacted is the one in `btcpay_server_url`.

### Buying without an account

Off by default. Turn on `btcpay_anonymous_checkout` and a logged-out visitor can buy: BTCPay collects their email at checkout, and when the payment settles Discourse **sends them an invite carrying the plan's group**. Accepting it creates their account with access already granted, and their subscription attaches to it automatically.

Why an invite rather than creating the account outright: BTCPay does not verify that the payer owns the address they typed. An invite does — the link only works from that mailbox — so a payment can never mint an account for someone else's email, or spam your user list.

If the address already belongs to a member, no invite is sent: the subscription attaches to that account and the group is granted immediately.

For logged-in buyers nothing is asked at all — their Discourse email is sent with the checkout (`btcpay_send_email`, on by default), so BTCPay skips its email step.

### Paying by card

Off by default. Install the [Stripe plugin](https://plugin-builder.btcpayserver.org/public/plugins/stripe-payments) on BTCPay, enable it on the store, then turn on `btcpay_card_payments`. The checkout gets a second button, **Pay with card**, next to the crypto one.

Both buttons create the same subscription invoice; the card button only opens it at `/i/<invoice>/STRIPE`, so BTCPay shows the Stripe form first. The payer can still switch method on that page. Card checkouts open BTCPay's full page rather than the overlay, which cannot be pointed at a payment method. Settlement, webhooks and group access are unchanged.

Renewals are still one invoice per period: the card is not stored and charged automatically.

Donations use the same switch. `POST /btcpay/donate` with `payment_method: "card"` opens the donation's POS invoice on Stripe the same way, so a card donation reaches the same webhook as a crypto one: it counts toward the fundraising total and the supporter list, and earns the donor badge and points. A donation sent through a bare Stripe Payment Link bypasses BTCPay, and none of that applies to it.

### Donations

Off by default. Turn on `btcpay_donations_enabled` and set `btcpay_pos_app_id` to the id in your Point of Sale app's URL (`/apps/<id>/pos`).

How it works: Discourse asks the POS app for an invoice, passing an order id it generates itself — `btcpay-donation:<user_id>:<nonce>`. BTCPay stores that in the invoice metadata, so when `InvoiceSettled` arrives the donation is attributed to the right member. **The order id never comes from the browser**, which is what stops one member crediting a donation to another.

Endpoints for a theme component to call:

| Endpoint | Purpose |
|---|---|
| `POST /btcpay/donate` `{amount}` | Returns `{invoice_id, checkout_url, modal_url}`; rate limited, login required |
| `GET /btcpay/donations` | `{currency, total, count, supporters: [{username, avatar_template, amount, count}]}` for a fundraising bar |

Donors can be rewarded automatically:

- **Badge** — pick one on Admin → Plugins → BTCPay; granted on the first settled donation.
- **Points** — set `btcpay_donation_points` to the points awarded per unit donated. Requires [discourse-gamification](https://github.com/discourse/discourse-gamification); it is ignored when that plugin is absent.

Donations grant no group and never touch subscriptions.

### Manual group membership

Adding a user to a plan's group by hand grants access immediately — Discourse groups are what gate content, and the plugin never revokes a member it has no record for. The reconcile job only walks its own subscription records, so hand-granted members are left alone forever.

The flip side: the billing tab shows such a user nothing, because there is no subscription behind it. Use manual membership for comps and staff; use a BTCPay plan for anything that should renew or expire on its own.

### BTCPay reverse proxy

If checkout lands on `127.0.0.1` or `localhost`, BTCPay is generating links from the host it sees, not the public one. Two things must be right:

1. **BTCPay → Server Settings → Server URL** — set to `https://btcpay.yourdomain.com`. This is what BTCPay uses for redirects and invoice links.
2. **The proxy in front of BTCPay must forward the original host and scheme.** A proxy that omits these is the usual cause:

```nginx
location / {
    proxy_pass http://127.0.0.1:23000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
}
```

If you run BTCPay's own docker-compose, set `BTCPAY_HOST` to the public hostname and let its bundled nginx handle this — a second proxy in front of it needs the headers above.

Check what BTCPay believes, from any machine:

```bash
curl -s -X POST https://btcpay.yourdomain.com/api/v1/plan-checkout \
  -H "Authorization: token YOUR_API_KEY" -H "Content-Type: application/json" \
  -d '{"storeId":"STORE","offeringId":"OFFERING","planId":"PLAN"}' | grep -o '"url":"[^"]*"'
```

If that `url` contains `127.0.0.1`, the problem is entirely in BTCPay's configuration — Discourse only passes the payer along.

## Upgrading, disabling, removing

**Upgrade:** `cd /var/discourse && ./launcher rebuild app` picks up the latest commit of the plugin, exactly like the install. There are no database migrations and no renamed settings or storage keys, so upgrades are in place and reversible by checking out an older commit and rebuilding. Check [CHANGELOG.md](CHANGELOG.md) before upgrading.

**Disable:** turn off `btcpay_enabled`. The scheduled job stops doing work, the webhook and checkout endpoints refuse requests, and the JS never registers its routes or links. Nothing is deleted, and group memberships already granted stay as they are — Discourse groups are the source of truth for access, not this plugin.

**Remove:** delete the plugin from `app.yml` and rebuild. **Plugin-store data is kept on purpose** — subscription records, payment history and the BTCPay customer ids survive an uninstall so that reinstalling does not lose paid subscribers' history. To purge it deliberately:

```sql
DELETE FROM plugin_store_rows WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

Records belonging to a **deleted user** are removed automatically when Discourse destroys the account.

**Support:** open an issue at https://github.com/criptonautas/discourse-btcpay-subscriptions/issues with your Discourse and BTCPay versions, the relevant `/logs` entries (search `DiscourseBtcpay`), and the BTCPay webhook delivery log for the event in question.

## Troubleshooting

**Webhook not received:** Check BTCPay webhook delivery log. Ensure the URL is reachable. Test with `curl -X POST https://yourdiscourse.com/btcpay/webhook`.

**HMAC failures:** Verify the webhook secret matches exactly in both BTCPay and Discourse settings. No trailing spaces.

**User not added to group:** Check Discourse `/logs` for `DiscourseBtcpay` entries. Verify the plan mapping JSON is valid and the group exists.

**Admin page 404s:** the config page lives at **Admin → Plugins → BTCPay Subscriptions** (`/admin/plugins/discourse-btcpay-subscriptions`), not `/admin/plugins/btcpay` — that prefix serves the plugin's JSON endpoints only. A stale bookmark to the old path will 404.

**Admin page says "not fully configured":** it now lists the settings that are still blank. `btcpay_offering_id` is the one most often missed — it was added after the first release. If every setting is filled and it still complains, the page shows the BTCPay error instead: check `btcpay_server_url` and that the API key carries `canviewofferings`.

**Checkout still lands on localhost after clicking Subscribe:** fixed in the plugin — Discourse now proceeds the checkout itself (`POST /api/v1/plan-checkout/{id}`) and sends the payer straight to the invoice, so BTCPay's own Subscribe page and its redirect are never involved. If you still see it, the invoice URL itself is being built wrong: check **BTCPay → Server Settings → Server URL**.

**Checkout sends me to localhost:** BTCPay built the checkout URL from the host it believes it runs on. The plugin rewrites that URL to `btcpay_server_url` and logs a warning, so checkout still works — but fix the root cause in BTCPay:

- **BTCPay → Server Settings → Server URL** must be the public HTTPS URL, not `localhost`.
- The reverse proxy in front of BTCPay must forward the original host and scheme:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

If the **return** link after paying lands on localhost instead, that is Discourse's own `DISCOURSE_HOSTNAME` (or `force_https`) being wrong — the redirect is built from `Discourse.base_url`.

**Manual sync:** Admin → Plugins → BTCPay → "Sync with BTCPay" button (bypasses the interval).

**Wrong network:** the admin page shows a network label next to the server URL and chain height. BTCPay's API exposes no network field, so the label is **inferred from the chain tip** of BTC (or the first chain the server reports) — treat it as a sanity check, not an authority. "unknown" means BTCPay returned no sync status.

## Testing on testnet

Nothing in the plugin is BTC-specific: it reads whatever payment method BTCPay reports as paid, so XMR, LTC, DOGE and Lightning all work the same. Testnet is just a BTCPay server running on a test chain.

### 1. Get a testnet BTCPay

Either use the public demo (fastest, no setup, wiped periodically):

- https://testnet.demo.btcpayserver.org — register, create a store, done.

Or run your own on testnet/regtest:

```bash
git clone https://github.com/btcpayserver/btcpayserver-docker
cd btcpayserver-docker
export BTCPAY_HOST="btcpay.test.yourdomain.com"
export NBITCOIN_NETWORK="testnet"          # or "regtest" for instant blocks
export BTCPAYGEN_CRYPTO1="btc"
export BTCPAYGEN_CRYPTO2="xmr"             # add more to test multi-crypto
export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-s"
. ./btcpay-setup.sh -i
```

Testnet sync takes a few hours; regtest is instant but you mine your own blocks.

### 2. Set up the store

1. Store → Wallets → BTC → connect an existing wallet with a **tpub** (testnet xpub) or let BTCPay generate one. Save the seed.
2. Store → Subscriptions → create an Offering and a Plan priced in **USD** (e.g. 10 USD / month). Copy the Offering ID into `btcpay_offering_id` — the plans themselves are fetched automatically. BTCPay converts USD to crypto at checkout using its rate provider — Discourse only ever shows the USD figure.
3. Account → API Keys → create a key with `canviewofferings`, `canmanagesubscribers`, `canviewinvoices` and `canviewstoresettings`.

### 3. Point Discourse at it

Set `btcpay_server_url` to the testnet host, plus the API key, store ID and plan mappings. **Admin → Plugins → BTCPay** shows a `TESTNET` badge, the BTCPay version, the chain tip and the crypto codes the server reports — confirm it says testnet before you go further.

### 4. Make webhooks reachable

BTCPay must reach your Discourse over HTTPS. For a local dev Discourse, tunnel it:

```bash
cloudflared tunnel --url http://localhost:3000
# or: ngrok http 3000
```

Then in Discourse set `DISCOURSE_HOSTNAME`/`force_https` to the tunnel host, and point the BTCPay webhook at `https://<tunnel-host>/btcpay/webhook` with events `PlanStarted`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`.

### 5. Run a payment

1. Open `/tickets` on Discourse as a normal (non-admin) user.
2. Pick a plan → **Pay with crypto** → BTCPay's modal opens over the page.
3. Pay from a testnet wallet. Free coins:
   - BTC testnet3: https://coinfaucet.eu/en/btc-testnet/ or https://bitcoinfaucet.uo1.net
   - BTC signet: https://signetfaucet.com
   - LTC testnet: https://testnet-faucet.com/ltc-testnet
   - Monero stagenet: https://community.rino.io/faucet/stagenet/
   - regtest: `bitcoin-cli -regtest generatetoaddress 101 <addr>` — no faucet needed
4. Watch the states: as soon as the tx hits the mempool BTCPay fires `InvoiceProcessing` → the plugin marks the subscription **pending** (no group yet). After confirmations `InvoiceSettled` records the payment and `PlanStarted` grants the group; the page flips to "Payment received".

### 6. Verify

```bash
# in the Discourse container
./launcher enter app
rails c
> DiscourseBtcpay.get_subscription(User.find_by(username: "tester").id)
> DiscourseBtcpay.get_payments(User.find_by(username: "tester").id)
```

The payment record's `payment_method` is whatever settled it (`BTC`, `XMR`, `BTC-LightningNetwork`, …), not a hardcoded BTC.

Also check **BTCPay → Store → Webhooks → Deliveries** for 200 responses. A 401 there means the secret doesn't match; a 415 means something other than `application/json` was posted.

### 7. Test the failure paths

| Scenario | How to trigger | Expected |
|---|---|---|
| Missed webhook | Disable the webhook in BTCPay, pay, then re-enable | Admin → BTCPay → **Sync with BTCPay** grants the group |
| Abandoned invoice | Start a checkout, never pay | Stays `pending`, then `expired` on `InvoiceExpired` (or within 24h via reconcile) |
| BTCPay down | Stop the container, click Pay | Error message on the page, no state written, reconcile retries next hour |
| Bad secret | Change `btcpay_webhook_secret` | 401 in BTCPay delivery log; after 3 failures an admin PM |
| Refund | Mark an invoice invalid in BTCPay | Status `disputed`, group access kept, admin PM |

## Development

Tests run in CI on every push via the official Discourse plugin workflow (RuboCop, ESLint, Prettier, Stylelint, ember-template-lint, RSpec).

Locally:

```bash
cd /var/discourse && ./launcher enter app

# Backend
bundle exec rspec plugins/discourse-btcpay-subscriptions/spec

# Frontend (QUnit, needs a built Ember app)
bin/rake plugin:qunit['discourse-btcpay-subscriptions']
```

CI runs both, against `latest` and against `stable`.

Frontend linting (needs Node 22+ and pnpm):

```bash
pnpm install && pnpm lint
```

## Translations

English and Spanish ship with the plugin (`config/locales/{client,server}.{en,es}.yml`). Discourse picks the locale from each user's interface language.

## License

MIT. See [LICENSE](LICENSE).

Text of this README under [CC BY-NC-SA 4.0](CC-BY-NC-SA-4.0.txt).
