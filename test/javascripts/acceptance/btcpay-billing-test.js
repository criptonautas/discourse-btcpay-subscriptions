import { currentURL, visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const PLANS = {
  plans: [
    {
      plan_id: "plan-1",
      label: "Premium",
      group_name: "premium",
      price: "10",
      currency: "USD",
      interval: "Monthly",
    },
  ],
};

function subscription(overrides = {}) {
  return {
    subscription: {
      plan_id: "plan-1",
      plan_name: "Premium",
      status: "active",
      phase: "Normal",
      period_end: "2026-11-01T00:00:00Z",
      ...overrides,
    },
    payments: [
      {
        invoice_id: "INV1",
        amount: "10",
        currency: "USD",
        payment_method: "XMR",
        status: "settled",
        paid_at: "2026-10-01T00:00:00Z",
      },
    ],
    payment_progress: null,
    portal_url: "https://btcpay.example.com/portal/s",
  };
}

acceptance("BTCPay | Billing page", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () => helper.response(subscription()));
  });

  test("shows the plan, the payment history and the portal link", async function (assert) {
    await visit("/u/eviltrout/billing");

    assert.dom(".btcpay-sub-card").hasClass("btcpay-status-active");
    assert
      .dom(".user-main > .about")
      .isNotVisible("the profile header steps aside on billing");
    assert.dom(".btcpay-payments-table tbody tr").exists({ count: 1 });
    assert.dom(".btcpay-payments-table tbody td:nth-child(3)").hasText("XMR");
    assert
      .dom(".btcpay-payments-table tbody td:nth-child(4)")
      .hasText("settled", "payment status is translated, not raw");
    assert.dom(".btcpay-portal-link").hasAttribute("target", "_blank");
    assert
      .dom(".btcpay-checkout-section")
      .doesNotExist("a subscriber is not offered the plans again");
  });
});

acceptance("BTCPay | Billing page during a trial", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response(
        subscription({ phase: "Trial", trial_end: "2026-10-05T00:00:00Z" })
      )
    );
  });

  test("surfaces the trial", async function (assert) {
    await visit("/u/eviltrout/billing");

    assert.dom(".btcpay-trial").exists();
    assert.dom(".btcpay-grace").doesNotExist();
  });
});

acceptance("BTCPay | Billing page in grace", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response(
        subscription({
          phase: "Grace",
          grace_period_end: "2026-10-05T00:00:00Z",
          needs_upgrade: true,
        })
      )
    );
  });

  test("warns that payment is overdue and that an upgrade is needed", async function (assert) {
    await visit("/u/eviltrout/billing");

    assert.dom(".btcpay-grace").exists();
    assert.dom(".btcpay-needs-upgrade").exists();
  });
});

acceptance("BTCPay | Billing page while a payment confirms", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response({ plans: [] }));
    server.get("/btcpay/subscription", () =>
      helper.response({
        subscription: null,
        payments: [],
        payment_progress: {
          invoice_id: "INV1",
          payments: [
            { id: "p1", value: "0.0004", method: "BTC", settled: false },
          ],
        },
        portal_url: null,
      })
    );
  });

  test("shows unconfirmed payment progress on the tickets page", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-progress").exists();
    assert.dom(".btcpay-progress-list li.pending").exists({ count: 1 });
  });
});

acceptance("BTCPay | Billing tab on another profile", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    // Answered so a failure here means the guard let the tab render, not that
    // a request went unstubbed. The endpoint only ever knows the viewer, so
    // rendering it under someone else's name would show the wrong person.
    server.get("/btcpay/subscription", () => helper.response(subscription()));
    server.get("/user_actions.json", () =>
      helper.response({ user_actions: [] })
    );
  });

  test("redirects away instead of showing the viewer's own billing", async function (assert) {
    await visit("/u/charlie/billing");

    assert.dom(".btcpay-user-billing").doesNotExist();
    assert.notStrictEqual(currentURL(), "/u/charlie/billing");
  });
});

acceptance("BTCPay | Billing tab without a subscription", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response({
        subscription: null,
        payments: [],
        payment_progress: null,
        portal_url: null,
      })
    );
  });

  test("offers the plans to subscribe to", async function (assert) {
    await visit("/u/eviltrout/billing");

    assert.dom(".btcpay-no-sub").exists();
    assert.dom(".btcpay-checkout-section .btcpay-plan").exists({ count: 1 });
    assert.dom(".btcpay-checkout-btn").exists();
  });
});
