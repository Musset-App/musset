#!/usr/bin/env python3
"""Sets up Stripe for Musset Sync and writes the three secret files musset-api reads (server/README.md).

    python3 -I scripts/stripe-setup.py          asks for the Stripe secret key, without showing it

Run it once with a test key (sk_test_…) to try the whole path, then with the live key. It makes, or finds if they
are already there:
  - the product « Musset Sync » and its monthly price: 4.99 USD, 4.99 EUR in the euro area (lookup key below);
  - the webhook to musset-api, for the four events it listens to.
and writes stripe-secret-key, stripe-price-id and stripe-webhook-secret into build/stripe-secrets/ (ignored by git,
readable by you only). Nothing is printed of the key or of the webhook's secret. Copy the files to /etc/musset on the
server yourself; the Billing Portal is switched on in the Dashboard (Settings › Billing › Customer portal).
"""
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from base64 import b64encode
from pathlib import Path

API = os.environ.get("MUSSET_STRIPE_API", "https://api.stripe.com/v1").rstrip("/")
PUBLIC = os.environ.get("MUSSET_PUBLIC", "https://git.musset.app").rstrip("/")
WEBHOOK = f"{PUBLIC}/musset-api/stripe-webhook"
EVENTS = ["checkout.session.completed", "customer.subscription.created", "customer.subscription.updated",
          "customer.subscription.deleted"]
LOOKUP = "musset_sync_monthly"
OUT = Path(__file__).resolve().parent.parent / "build" / "stripe-secrets"


def stripe(key, method, path, form=None):
    data = urllib.parse.urlencode(form, doseq=True).encode() if form and method == "POST" else None
    url = API + path + ("?" + urllib.parse.urlencode(form, doseq=True) if form and method == "GET" else "")
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Authorization", "Basic " + b64encode(f"{key}:".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        message = (json.load(e).get("error") or {}).get("message", "")
        sys.exit(f"Stripe refused {method} {path}: {e.code} {message}")


def main():
    key = os.environ.get("STRIPE_SECRET_KEY") or getpass.getpass("Stripe secret key (sk_test_… or sk_live_…): ").strip()
    if not key.startswith(("sk_test_", "sk_live_", "rk_test_", "rk_live_")):
        sys.exit("That is not a Stripe secret key.")
    mode = "live" if "_live_" in key else "test"

    found = stripe(key, "GET", "/prices", {"lookup_keys[]": LOOKUP, "active": "true"})["data"]
    if found:
        price = found[0]
        print(f"Price: found {price['id']}")
    else:
        product = stripe(key, "POST", "/products", {"name": "Musset Sync"})
        price = stripe(key, "POST", "/prices", {
            "product": product["id"], "currency": "usd", "unit_amount": "499", "recurring[interval]": "month",
            "currency_options[eur][unit_amount]": "499", "lookup_key": LOOKUP})
        print(f"Price: made {price['id']} (4.99 USD, 4.99 EUR, monthly)")

    hooks = [h for h in stripe(key, "GET", "/webhook_endpoints", {"limit": "100"})["data"] if h["url"] == WEBHOOK]
    secret = None
    if hooks:
        print(f"Webhook: {WEBHOOK} is already there. Stripe shows its secret only once, when it is made:")
        print("  keep the stripe-webhook-secret you have, or delete the webhook in the Dashboard and run this again.")
    else:
        hook = stripe(key, "POST", "/webhook_endpoints", {"url": WEBHOOK, "enabled_events[]": EVENTS})
        secret = hook["secret"]
        print(f"Webhook: made, to {WEBHOOK}")

    OUT.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    files = {"stripe-secret-key": key, "stripe-price-id": price["id"]}
    if secret:
        files["stripe-webhook-secret"] = secret
    for name, value in files.items():
        f = OUT / name
        f.touch(mode=0o600)
        os.chmod(f, 0o600)
        f.write_text(value + "\n")
    print(f"\n{mode.capitalize()} mode. Wrote {', '.join(files)} in {OUT}")
    print("Next: copy them to /etc/musset on the server (root and the service only), then restart musset-api.")


if __name__ == "__main__":
    main()
