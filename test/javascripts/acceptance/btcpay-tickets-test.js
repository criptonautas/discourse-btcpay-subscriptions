import { click, visit } from "@ember/test-helpers";
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
      description_html: "<p><strong>Everything</strong> in the forum</p>",
    },
    {
      plan_id: "plan-2",
      label: "VIP",
      group_name: "vip",
      price: "25",
      currency: "USD",
      interval: "Monthly",
    },
  ],
};

function noSubscription(helper) {
  return helper.response({
    subscription: null,
    payments: [],
    payment_progress: null,
    portal_url: null,
  });
}

acceptance("BTCPay | Tickets page", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () => noSubscription(helper));
  });

  test("lists every plan the offering returned", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-plan").exists({ count: 2 });
    assert.dom(".btcpay-plans").exists("plans are grouped in a fieldset");
    assert
      .dom(".btcpay-plan:first-of-type .btcpay-plan__amount")
      .hasText("10 USD");
  });

  test("translates BTCPay's billing interval", async function (assert) {
    await visit("/tickets");

    assert
      .dom(".btcpay-plan:first-of-type .btcpay-plan__interval")
      .hasText("/ month");
  });

  test("shows the checkout button", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-checkout-btn").exists();
  });

  test("renders markdown in a plan description", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-plan__description strong").hasText("Everything");
  });

  test("says nothing about a subscription the user does not have", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-user-billing").doesNotExist();
  });
});

acceptance("BTCPay | Tickets page with a subscription", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () =>
      helper.response({
        subscription: {
          plan_id: "plan-2",
          plan_name: "VIP",
          status: "active",
          phase: "Normal",
        },
        payments: [],
        payment_progress: null,
        portal_url: null,
      })
    );
  });

  test("marks the current plan and blocks the cheaper one", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-plan.is-current").exists({ count: 1 });
    assert
      .dom(".btcpay-plan.is-blocked .btcpay-plan__note")
      .exists("a downgrade is shown but not selectable");
    assert.dom(".btcpay-plan.is-blocked .btcpay-plan__radio").isDisabled();
  });
});

acceptance("BTCPay | Tickets page when disabled", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: false });

  test("renders nothing to buy", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-checkout-section").doesNotExist();
  });
});

acceptance("BTCPay | Tickets page with card payments", function (needs) {
  needs.user();
  needs.settings({
    btcpay_enabled: true,
    btcpay_card_payments: true,
    btcpay_card_button_label: "abonar con tarjeta",
  });

  let checkoutBody;

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () => noSubscription(helper));
    server.post("/btcpay/checkout", (request) => {
      checkoutBody = new URLSearchParams(request.requestBody);
      return helper.response({ error: "stop here" }, 422);
    });
  });

  test("offers a card button that asks for a card checkout", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-card-btn").hasText("abonar con tarjeta");

    await click(".btcpay-plan:first-of-type .btcpay-plan__radio");
    await click(".btcpay-card-btn");

    assert.strictEqual(checkoutBody.get("plan_id"), "plan-1");
    assert.strictEqual(checkoutBody.get("payment_method"), "card");
  });
});

acceptance("BTCPay | Tickets page without card payments", function (needs) {
  needs.user();
  needs.settings({ btcpay_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/btcpay/plans", () => helper.response(PLANS));
    server.get("/btcpay/subscription", () => noSubscription(helper));
  });

  test("hides the card button", async function (assert) {
    await visit("/tickets");

    assert.dom(".btcpay-card-btn").doesNotExist();
  });
});
