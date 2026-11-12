# frozen_string_literal: true

require "rails_helper"

describe DiscourseBtcpay::BtcpayCheckoutController do
  fab!(:user)
  fab!(:group) { Fabricate(:group, name: "premium") }

  let(:checkout_response) do
    {
      id: "chk_1",
      invoiceId: "INV9",
      url: "https://btcpay.example.com/i/INV9",
      subscriber: { customer: { id: "cust_abc123" } }
    }
  end

  before do
    stub_request(:post, %r{https://btcpay\.example\.com/api/v1/plan-checkout/})
      .to_return(status: 200, body: { id: "chk_1", invoiceId: "INV9" }.to_json)

    SiteSetting.btcpay_enabled = true
    SiteSetting.btcpay_server_url = "https://btcpay.example.com"
    SiteSetting.btcpay_api_key = "key"
    SiteSetting.btcpay_store_id = "store"
    SiteSetting.btcpay_offering_id = "off-1"
    DiscourseBtcpay.set_plan_group("plan-1", "premium")
    DiscourseBtcpay.set_plan_group("plan-2", "vip")
  end

  def stub_offering
    stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
      .to_return(
        status: 200,
        body: {
          id: "off-1",
          plans: [
            { id: "plan-1", name: "Premium", price: "10", currency: "USD", recurringType: "Monthly" },
            { id: "plan-2", name: "VIP", price: "25", currency: "USD", recurringType: "Monthly" }
          ]
        }.to_json
      )
  end

  def subscribed_to(plan_id)
    DiscourseBtcpay.store_subscription(
      user.id,
      { "customer_id" => "cust_abc123", "plan_id" => plan_id, "status" => "active" }
    )
  end

  it "serves the pages so a direct visit does not 404" do
    ["/tickets", "/u/#{user.username}/billing"].each do |path|
      get path

      expect(response.status).to eq(200)
    end
  end

  it "404s the pages when the plugin is disabled" do
    SiteSetting.btcpay_enabled = false

    get "/tickets"

    expect(response.status).to eq(404)
  end

  it "requires a logged in user" do
    post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

    expect(response.status).to eq(403)
  end

  context "when logged in" do
    before { sign_in(user) }

    context "when subscriptions are closed" do
      before do
        SiteSetting.btcpay_plans_open = false
        stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
          .to_return(
            status: 200,
            body: { id: "off-1", plans: [{ id: "plan-1", name: "Premium", price: "10" }] }.to_json
          )
      end

      it "lists no plans and says they are closed" do
        get "/btcpay/plans.json"

        expect(response.parsed_body["plans"]).to eq([])
        expect(response.parsed_body["closed"]).to eq(true)
      end

      it "refuses a checkout" do
        post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

        expect(response.status).to eq(403)
        expect(response.parsed_body["error"]).to eq(
          I18n.t("discourse_btcpay.errors.plans_closed")
        )
      end

      it "still shows the plans to staff" do
        user.update!(admin: true)

        get "/btcpay/plans.json"

        expect(response.parsed_body["plans"].map { |p| p["plan_id"] }).to eq(["plan-1"])
      end
    end

    it "refuses when the offering is not configured" do
      SiteSetting.btcpay_offering_id = ""

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(503)
    end

    it "404s on an unmapped plan" do
      stub_offering

      post "/btcpay/checkout.json", params: { plan_id: "nope" }

      expect(response.status).to eq(404)
    end

    it "proceeds the checkout so the payer lands on the invoice, not BTCPay's Subscribe page" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.except(:invoiceId).to_json)
      proceed =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout/chk_1")
          .to_return(status: 200, body: { id: "chk_1", invoiceId: "INV42" }.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(proceed).to have_been_requested
      expect(response.parsed_body["invoice_id"]).to eq("INV42")
      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/INV42"
      )
    end

    context "when paying by card" do
      before do
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .to_return(status: 200, body: checkout_response.to_json)
      end

      it "opens the invoice on the Stripe payment method, without the modal" do
        SiteSetting.btcpay_card_payments = true

        post "/btcpay/checkout.json", params: { plan_id: "plan-1", payment_method: "card" }

        expect(response.status).to eq(200)
        expect(response.parsed_body["checkout_url"]).to eq(
          "https://btcpay.example.com/i/INV9/STRIPE"
        )
        expect(response.parsed_body["modal_url"]).to be_nil
      end

      it "ignores the card choice when card payments are off" do
        SiteSetting.btcpay_card_payments = false

        post "/btcpay/checkout.json", params: { plan_id: "plan-1", payment_method: "card" }

        expect(response.parsed_body["checkout_url"]).to eq("https://btcpay.example.com/i/INV9")
        expect(response.parsed_body["modal_url"]).to be_present
      end
    end

    it "reports a plan that credit already covered, with nothing to pay" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.except(:invoiceId).to_json)
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout/chk_1")
        .to_return(status: 200, body: { id: "chk_1", planStarted: true }.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.parsed_body["plan_started"]).to eq(true)
      expect(response.parsed_body["checkout_url"]).to be_nil
    end

    it "falls back to BTCPay's checkout page when proceeding fails" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.except(:invoiceId).to_json)
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout/chk_1").to_timeout

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(200)
      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/INV9"
      )
    end

    it "cooks plan descriptions so markdown renders" do
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: {
            id: "off-1",
            plans: [
              { id: "plan-1", name: "Premium", price: "10", description: "**bold** perk" }
            ]
          }.to_json
        )

      get "/btcpay/plans.json"

      expect(response.parsed_body["plans"].first["description_html"]).to include(
        "<strong>bold</strong>"
      )
    end

    it "prefers the plan's description for the viewer's locale" do
      SiteSetting.default_locale = "es"
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: {
            id: "off-1",
            plans: [
              {
                id: "plan-1",
                name: "Premium",
                price: "10",
                description: "Everything",
                metadata: { description_es: "Todo el foro" }
              }
            ]
          }.to_json
        )

      get "/btcpay/plans.json"

      expect(response.parsed_body["plans"].first["description"]).to eq("Todo el foro")
    end

    it "posts a store-scoped body to the top-level plan-checkout endpoint" do
      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req|
            body = JSON.parse(req.body)
            body["storeId"] == "store" && body["offeringId"] == "off-1" &&
              body["planId"] == "plan-1" &&
              body["invoiceMetadata"]["discourse_user_id"] == user.id.to_s
          }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
      expect(response.parsed_body["invoice_id"]).to eq("INV9")
      expect(response.parsed_body["modal_url"]).to eq(
        "https://btcpay.example.com/modal/btcpay.js"
      )
    end

    it "re-points a localhost checkout URL at the configured BTCPay host" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout").to_return(
        status: 200,
        body: checkout_response.merge(url: "http://localhost:23000/i/INV9").to_json
      )

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/INV9"
      )
    end

    it "leaves a correct checkout URL alone" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.parsed_body["checkout_url"]).to eq(
        "https://btcpay.example.com/i/INV9"
      )
    end

    it "remembers the BTCPay customer id for later lookups" do
      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(DiscourseBtcpay.get_subscription(user.id)["customer_id"]).to eq("cust_abc123")
    end

    it "sends a returning subscriber as the customer selector" do
      DiscourseBtcpay.store_subscription(user.id, { "customer_id" => "cust_abc123" })

      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req| JSON.parse(req.body)["customerSelector"] == "cust_abc123" }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(stub).to have_been_requested
    end

    it "upgrades with HardMigration so the new tier starts now" do
      Fabricate(:group, name: "vip")
      stub_offering
      subscribed_to("plan-1")

      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req| JSON.parse(req.body)["onPayBehavior"] == "HardMigration" }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-2" }

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested
    end

    it "refuses a downgrade" do
      Fabricate(:group, name: "vip")
      stub_offering
      subscribed_to("plan-2")

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(response.status).to eq(422)
      expect(response.parsed_body["error"]).to eq(
        I18n.t("discourse_btcpay.errors.downgrade_unsupported")
      )
    end

    it "renews the same plan without a migration behavior" do
      stub_offering
      subscribed_to("plan-1")

      stub =
        stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
          .with { |req| !JSON.parse(req.body).key?("onPayBehavior") }
          .to_return(status: 200, body: checkout_response.to_json)

      post "/btcpay/checkout.json", params: { plan_id: "plan-1" }

      expect(stub).to have_been_requested
    end

    it "exposes live payment progress on the status endpoint" do
      subscribed_to("plan-1")
      DiscourseBtcpay.store_payment_progress(
        user.id,
        { "invoice_id" => "INV9", "payments" => [{ "value" => "0.0004", "settled" => false }] }
      )
      stub_request(:post, "https://btcpay.example.com/api/v1/subscriber-portal")
        .to_return(status: 200, body: { url: "https://btcpay.example.com/portal/s" }.to_json)

      get "/btcpay/subscription.json"

      expect(response.parsed_body["payment_progress"]["invoice_id"]).to eq("INV9")
    end

    it "rate limits repeated checkout attempts" do
      RateLimiter.enable
      RateLimiter.new(user, "btcpay-checkout", 5, 1.minute).clear!
      RateLimiter.new(user, "btcpay-checkout-hourly", 20, 1.hour).clear!

      stub_request(:post, "https://btcpay.example.com/api/v1/plan-checkout")
        .to_return(status: 200, body: checkout_response.to_json)

      6.times { post "/btcpay/checkout.json", params: { plan_id: "plan-1" } }

      expect(response.status).to eq(429)
    ensure
      RateLimiter.disable
    end

    it "offers every plan in the offering, mapped by BTCPay metadata" do
      Fabricate(:group, name: "vip")
      DiscourseBtcpay.set_plan_group("plan-1", nil)
      DiscourseBtcpay.set_plan_group("plan-2", nil)
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: {
            id: "off-1",
            plans: [
              {
                id: "plan-2",
                name: "VIP",
                price: "25",
                currency: "USD",
                recurringType: "Monthly",
                metadata: { discourse_group: "vip" }
              }
            ]
          }.to_json
        )

      get "/btcpay/plans.json"

      plan = response.parsed_body["plans"].first
      expect(plan["plan_id"]).to eq("plan-2")
      expect(plan["label"]).to eq("VIP")
      expect(plan["group_name"]).to eq("vip")
    end

    it "hides plans that resolve to no group" do
      DiscourseBtcpay.set_plan_group("plan-1", nil)
      DiscourseBtcpay.set_plan_group("plan-2", nil)
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: { id: "off-1", plans: [{ id: "plan-9", name: "Orphan", price: "5" }] }.to_json
        )

      get "/btcpay/plans.json"

      expect(response.parsed_body["plans"]).to eq([])
    end

    it "lets an admin mapping override BTCPay metadata" do
      Fabricate(:group, name: "vip")
      DiscourseBtcpay.set_plan_group("plan-2", "premium")
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_return(
          status: 200,
          body: {
            id: "off-1",
            plans: [
              { id: "plan-2", name: "VIP", price: "25", metadata: { discourse_group: "vip" } }
            ]
          }.to_json
        )

      get "/btcpay/plans.json"

      plan = response.parsed_body["plans"].first
      expect(plan["group_name"]).to eq("premium")
      expect(plan["label"]).to eq("VIP")
    end

    it "prices plans from the offering and caches them" do
      stub =
        stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
          .to_return(
            status: 200,
            body: {
              id: "off-1",
              plans: [
                {
                  id: "plan-1",
                  name: "Premium",
                  price: "10",
                  currency: "USD",
                  recurringType: "Monthly"
                }
              ]
            }.to_json
          )

      2.times { get "/btcpay/plans.json" }

      plan = response.parsed_body["plans"].first
      expect(plan["price"]).to eq("10")
      expect(plan["currency"]).to eq("USD")
      expect(plan["interval"]).to eq("Monthly")
      expect(plan["group_name"]).to eq("premium")
      expect(stub).to have_been_requested.once
    end

    it "returns no plans rather than erroring when BTCPay is unreachable" do
      stub_request(:get, "https://btcpay.example.com/api/v1/stores/store/offerings/off-1")
        .to_timeout

      get "/btcpay/plans.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["plans"]).to eq([])
    end

    it "returns a real portal session url" do
      DiscourseBtcpay.store_subscription(
        user.id,
        { "customer_id" => "cust_abc123", "status" => "active" }
      )
      stub_request(:post, "https://btcpay.example.com/api/v1/subscriber-portal")
        .to_return(
          status: 200,
          body: { url: "https://btcpay.example.com/portal/sess_1" }.to_json
        )

      get "/btcpay/subscription.json"

      expect(response.parsed_body["portal_url"]).to eq(
        "https://btcpay.example.com/portal/sess_1"
      )
    end
  end
end
