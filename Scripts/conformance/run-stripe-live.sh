#!/usr/bin/env bash
# Live Stripe conformance (preview-gated): settles a real test-mode PaymentIntent against
# api.stripe.com through StripeChargeVerifier + StripePaymentIntentClient. It mints a test Shared
# Payment Token via Stripe's test-helpers endpoint, so it requires MPP_STRIPE_LIVE_SK, a sk_test
# from a Stripe account enrolled in the SPT PRIVATE PREVIEW (the endpoint is unavailable otherwise).
#
#   MPP_STRIPE_LIVE_SK=sk_test_... Scripts/conformance/run-stripe-live.sh
#
# Skips (exit 0) when the key is absent. Pure Swift (no Node harness): Stripe has no keyless public
# sandbox, so unlike the Tempo live e2e this cannot be self-contained.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${MPP_STRIPE_LIVE_SK:-}" ]; then
  echo "==> MPP_STRIPE_LIVE_SK not set; skipping live Stripe conformance"
  exit 0
fi

echo "==> running the gated live Stripe conformance test against api.stripe.com"
cd "$REPO"
MPP_STRIPE_LIVE_SK="$MPP_STRIPE_LIVE_SK" swift test --filter StripeLiveConformanceTests
echo "==> live Stripe conformance PASSED"
