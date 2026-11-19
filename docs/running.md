# Running CountOnce

How to run every part on a laptop, in containers, and how to deploy it.

## Run it on a laptop

Needs Node.js 22 or newer.

```
npm install
npm run db:local     # once: creates the local database
npm run dev          # then open http://localhost:8788
npm run check -- http://localhost:8788
```

The commands below that set a variable for one command (`NAME=value command`) are for bash. In
PowerShell set it first: `$env:COUNTONCE_STAFF_KEY="<key>"; npm run check`.

## The three rules

1. Never hand out stock that is not there.
2. Never count the same request twice: every request carries a `request_id`, and a movement sent
   again gets the first answer back.
3. Never order the same shortage twice: the database allows at most one open supplier order per item.

Request ids starting with `order-` are kept for deliveries of supplier orders, so a movement cannot use one.

**Visitors.** `POST /api/visitor` with `{"visitor": "<8 capital letters or digits>"}` creates that
visitor's three practice items, copies of the real ones (`DEMO-<id>P`, `G` and `T`), and
`GET /api/state?visitor=<id>` reads only those. Like every `DEMO-` item they need no key, stay out of
the real stock list and are deleted after a day.

**Staff key.** Once the secret `STAFF_KEY` is set on Cloudflare, changing real stock (a movement, a
supplier order, a delivery) needs it in the `x-staff-key` header. Demonstration items (`DEMO-...`) stay
open, so anyone can try the dashboard's two cases. Reading stock needs no key. For a laptop run, put
`STAFF_KEY=<key>` in a file `.dev.vars` (it is not committed), and give the same key to the checks:
`COUNTONCE_STAFF_KEY=<key> npm run check`. The dashboard asks for the key in a password field when Delivered
is pressed, and forgets it when the tab is closed.

## The staff app

```
cd app
flutter test
flutter build apk     # the Android app, using the live site; add --dart-define=API=<address> for another API
```

In a browser, the app has to come from the same address as the API: `npm run build:app` builds it into
`public/app/`, then `npm run dev` serves it at http://localhost:8788/app/. On the live site it is at `/app/`.
`npm run deploy` refuses to run until `build:app` has been run, so the app is never left out.
The build carries its own copy of Flutter's rendering engine and of the fallback fonts for scripts IBM Plex
does not cover (Arabic, emoji, Chinese and others; `app/tool/fetch_fallback_fonts.mjs`), and of the barcode
decoder that browsers without a built-in barcode reader use (`app/web/vendor/zxing-wasm`). The app makes no
requests to other sites, so it also starts and scans on networks that block Google or jsDelivr.
Enter your name and the staff key once; tap the name chip to change them. "Try it as a visitor" on
the sign-in screen works on the visitor's own demo items with no key, and adds a "No signal" switch
that makes the app behave exactly as with no network. In a browser, `/app/?visitor=<id>` opens visitor
mode on that visitor's items (the playground uses this). Every scan goes into a queue on the phone first, with its
request id made at the moment of the scan, and is sent from there, oldest first. With no network the
scans wait and are sent when it returns. A scan whose reply was lost is sent again with the same id,
and rule 2 counts it once.

## Run the Node-RED flows

Needs Node-RED 5 (`npm install -g node-red`, which needs Node.js 22.9 or newer) and two palette
packages, installed once into the Node-RED user folder (start `node-red` once first, so the folder exists):

```
cd ~/.node-red
npm install node-red-contrib-aedes@1.4.0 @flowfuse/node-red-dashboard@1.33.0
```

Three environment variables, set before starting Node-RED:

| Variable | What it is |
|---|---|
| `COUNTONCE_MQTT_PASSWORD` | Required. The broker asks for a login (user `countonce`), so nobody else on the network can send a fake stock message. 8 characters or more |
| `COUNTONCE_STAFF_KEY` | The API's staff key, so flow 2 can raise supplier orders |
| `COUNTONCE_API` | Optional. The API's address, for example `http://localhost:8788`. https://countonce.pages.dev when not set |

On Windows: `setx COUNTONCE_MQTT_PASSWORD <password>` (and the others), then open a new terminal. On Linux
or macOS: `export COUNTONCE_MQTT_PASSWORD=<password>`.

Start it so the editor only answers on this computer (anyone who can open the editor can change the
flows): `node-red -D uiHost=127.0.0.1`. Open `http://localhost:1880`, import `nodered/flows.json` from
the menu (Import), and press Deploy. Three tabs appear:

| Tab | What it does |
|---|---|
| MQTT broker | An MQTT broker inside Node-RED, on port 1883, with a login |
| 1. Stock state | Every 15 seconds: reads the stock from the API and publishes each item's state (quantity, reorder point, low or not, its open order) to `countonce/stock/<item id>`, QoS 1, retained. Whether the API answered goes to `countonce/api` |
| 2. Supplier order and alert | For an item that is low and has no open order, asks the API for a supplier order, naming only the item. Alerts go to `countonce/alerts` and to the dashboard at `http://localhost:1880/dashboard` |

What gets alerted, each once: every open supplier order (also one raised by hand, or one whose reply
was lost), a problem raising an order (until it clears), the API stopping and starting to answer, and
a missing broker password.

The API, not the flow, decides whether to order and how much: it refuses with `not needed` when the
item is above its reorder point, and takes the quantity from the item's `reorder_qty`. So a stale or
fake message cannot order anything. (Someone with the broker password could still make a false alert
appear; the broker login is what stops that.)

## The load simulator

```
node sim/simulate.mjs http://localhost:8788                    # 8 phones, 25 scans each
node sim/simulate.mjs http://localhost:8788 --stop-after 60    # stops partway, like a crash
node sim/simulate.mjs http://localhost:8788 --resume           # starts again from where it stopped
node sim/simulate.mjs https://countonce.pages.dev --latency 20
```

Requests are sent twice, replies are lost, and some requests arrive late, at the rates given by
`--dup`, `--drop` and `--late`. At the end it checks that the server's stock is the starting stock plus
every applied scan once, and that the server holds exactly one applied ledger row for each applied
scan. It only uses its own demonstration item. `--seed` repeats the same scans and the same network
trouble; which scans find the stock gone can still differ, because the phones race each other.

## Run it all in containers

Put the two values in a file `.env` next to `docker-compose.yml` (it is not committed):

```
COUNTONCE_MQTT_PASSWORD=<password>
COUNTONCE_STAFF_KEY=<key>
```

Then `docker compose up --build` (always `--build` after a change, or the old images run). The API runs
in workerd, the open-source runtime that Cloudflare Workers use, with a SQLite file as its database;
Node-RED runs the same flows and starts once the API answers. The ports only answer on this computer.
The database lives inside the container, so a rebuild starts again from the three sample items.

## Deploy

```
npm run db:remote                       # first, whenever migrations/ has a new file
npx wrangler pages secret put STAFF_KEY --project-name countonce   # once
npm run build:app
npm run deploy
COUNTONCE_STAFF_KEY=<key> npm run check -- https://countonce.pages.dev
```

The site (Pages project `countonce`) and its D1 database (`countonce`) are on a Cloudflare account on
the Workers Free plan with no payment method, so at the daily limit the site stops with errors and
nothing can bill.

Apply the migrations before deploying: new code that reads a column the live database does not
have yet fails on every request. Deploying needs a Cloudflare login (`npx wrangler login`) and, when
the login has more than one account, `CLOUDFLARE_ACCOUNT_ID` set in the environment.

## Limits we know about

- There is one staff key for everyone, not a login per person, and the dashboard and the stock
  list are public. Fine for a course project, not for a real warehouse.
- Node-RED runs as one process on one computer. If it is off, no supplier orders are raised; the API and the staff
  app keep working.
- Node-RED reads the stock every 15 seconds, so an order is raised up to 15 seconds after the stock
  falls.
