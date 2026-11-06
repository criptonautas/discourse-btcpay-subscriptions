# frozen_string_literal: true

module DiscourseBtcpay
  class BtcpayCheckoutController < ::ApplicationController
    requires_plugin DiscourseBtcpay::PLUGIN_NAME

    before_action :ensure_can_buy
    before_action :ensure_btcpay_configured

    # POST /btcpay/checkout
    # Body: { plan_id: "xxx", payment_method: "card" (optional) }
    def create
      # Anonymous buyers have no account to limit, so limit the address
      limit_key = current_user ? "btcpay-checkout" : "btcpay-checkout-#{request.ip}"
      RateLimiter.new(current_user, limit_key, 5, 1.minute).performed!
      RateLimiter.new(current_user, "#{limit_key}-hourly", 20, 1.hour).performed!

      plan_id = params.require(:plan_id)

      manager = BtcpaySubscriptionManager.new
      unless manager.group_for_plan(plan_id)
        return render json: { error: I18n.t("discourse_btcpay.errors.plan_not_found") }, status: :not_found
      end

      existing = current_user && DiscourseBtcpay.get_subscription(current_user.id)

      change = plan_change(existing, plan_id)
      if change == :downgrade
        return render json: {
          error: I18n.t("discourse_btcpay.errors.downgrade_unsupported")
        }, status: :unprocessable_entity
      end

      metadata = { discourse_plan_id: plan_id }

      if current_user
        metadata[:discourse_user_id] = current_user.id.to_s
        metadata[:discourse_username] = current_user.username
      else
        # BTCPay collects the email; the webhook turns it into an invite
        metadata[:discourse_anonymous] = "true"
      end

      api = BtcpayApi.new
      result =
        api.create_plan_checkout(
          plan_id: plan_id,
          # A returning subscriber keeps their BTCPay customer record
          customer_selector: existing && existing["customer_id"],
          subscriber_metadata: metadata,
          invoice_metadata: metadata,
          # Skips BTCPay's "what is your email?" step for a new subscriber
          new_subscriber_email: subscriber_email(existing),
          success_redirect_link: "#{Discourse.base_url}#{SiteSetting.btcpay_redirect_after_checkout}",
          # An upgrade should take effect now, refunding the unused remainder
          on_pay_behavior: change == :upgrade ? "HardMigration" : nil
        )

      remember_customer(result)

      # Take the checkout to its second stage here rather than making the
      # payer click "Subscribe" on BTCPay and follow BTCPay's own redirect.
      proceeded = proceed(api, result)
      invoice_id = proceeded["invoiceId"] || result["invoiceId"]

      if proceeded["planStarted"] && invoice_id.blank?
        # Covered by credit: nothing to pay, PlanStarted grants the group.
        return render json: { plan_started: true }
      end

      card = card_payment?

      checkout_url =
        if invoice_id.present?
          api.invoice_url(invoice_id, card ? DiscourseBtcpay::STRIPE_PAYMENT_METHOD : nil)
        else
          public_checkout_url(result["url"] || result["redirectUrl"])
        end

      unless checkout_url
        Rails.logger.error("DiscourseBtcpay: No checkout URL returned: #{result.inspect}")
        return render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") }, status: :bad_gateway
      end

      # invoice_id + modal_url let the client open BTCPay's overlay; the
      # checkout_url is the fallback when the modal script can't load.
      # The overlay can't be pointed at a payment method, so card goes
      # straight to the checkout page.
      render json: {
        checkout_url: checkout_url,
        invoice_id: invoice_id,
        modal_url: card ? nil : "#{SiteSetting.btcpay_server_url.chomp("/")}/modal/btcpay.js",
        plan_started: false
      }
    rescue RateLimiter::LimitExceeded
      render json: { error: I18n.t("discourse_btcpay.errors.rate_limited") }, status: :too_many_requests
    rescue BtcpayApi::ApiError => e
      Rails.logger.error("DiscourseBtcpay: Checkout creation failed: #{e.message}")
      render json: { error: I18n.t("discourse_btcpay.errors.checkout_failed") }, status: :bad_gateway
    end

    # GET /btcpay/subscription
    def status
      return render json: { subscription: nil, payments: [], portal_url: nil } unless current_user

      sub = DiscourseBtcpay.get_subscription(current_user.id)
      payments = DiscourseBtcpay.get_payments(current_user.id)

      progress = DiscourseBtcpay.get_payment_progress(current_user.id)

      if sub
        render json: {
          subscription: sub,
          payments: payments.last(20),
          payment_progress: progress,
          portal_url: portal_url(sub["customer_id"])
        }
      else
        render json: {
          subscription: nil,
          payments: [],
          payment_progress: progress,
          portal_url: nil
        }
      end
    end

    # GET /btcpay/plans
    # The offering is the catalogue: every plan BTCPay lists is offered, as
    # long as it resolves to a Discourse group.
    def plans
      plans =
        DiscourseBtcpay.remote_plans.filter_map do |plan|
          plan_id = plan["id"]
          group_name = DiscourseBtcpay.group_for_plan(plan_id, plan: plan)
          next if group_name.blank?

          # A "description_es" / "description_en" metadata key on the plan wins
          # for that locale; BTCPay's own description is the fallback.
          description =
            plan.dig("metadata", "description_#{I18n.locale}").presence ||
              plan["description"]

          {
            plan_id: plan_id,
            label: DiscourseBtcpay.label_for_plan(plan_id, plan: plan),
            group_name: group_name,
            price: plan["price"],
            currency: plan["currency"],
            interval: plan["recurringType"],
            description: description,
            # BTCPay stores the description as plain text; run it through
            # Discourse's own markdown + sanitizer so bold, links and lists work
            description_html: cooked(description),
            trial_days: plan["trialDays"]
          }
        end

      render json: { plans: plans }
    end

    private

    def card_payment?
      SiteSetting.btcpay_card_payments && params[:payment_method] == "card"
    end

    # :new, :renewal, :upgrade or :downgrade, decided on BTCPay's prices so a
    # crafted request cannot buy a cheaper tier as if it were an upgrade.
    def plan_change(existing, plan_id)
      return :new unless existing && existing["status"] == "active"

      current_plan_id = existing["plan_id"]
      return :renewal if current_plan_id == plan_id

      prices = DiscourseBtcpay.remote_plans.index_by { |p| p["id"] }
      current = prices[current_plan_id]
      wanted = prices[plan_id]
      return :new if current.nil? || wanted.nil?

      wanted["price"].to_f > current["price"].to_f ? :upgrade : :downgrade
    end

    # BTCPay may have created the customer during checkout; hold on to the id
    # so later lookups and renewals address the same subscriber.
    def remember_customer(result)
      return if current_user.blank?

      customer_id = result.dig("subscriber", "customer", "id")
      return if customer_id.blank?

      sub = DiscourseBtcpay.get_subscription(current_user.id) || {}
      return if sub["customer_id"] == customer_id

      DiscourseBtcpay.store_subscription(
        current_user.id,
        sub.merge("customer_id" => customer_id, "updated_at" => Time.now.iso8601)
      )
    end

    # Buying without an account is opt-in: it creates forum members from
    # payments, which is a policy decision, not a default.
    def ensure_can_buy
      return if current_user
      return if SiteSetting.btcpay_anonymous_checkout && action_name != "status"

      ensure_logged_in
    end

    def ensure_btcpay_configured
      unless SiteSetting.btcpay_enabled
        return render json: { error: I18n.t("discourse_btcpay.errors.not_enabled") }, status: :service_unavailable
      end

      unless BtcpayApi.new.configured?
        render json: { error: I18n.t("discourse_btcpay.errors.missing_config") },
               status: :service_unavailable
      end
    end

    # Only for a subscriber BTCPay does not know yet: an existing customer id
    # already carries whatever address they registered with.
    def subscriber_email(existing)
      return nil if current_user.blank?
      return nil if existing && existing["customer_id"].present?
      return nil unless SiteSetting.btcpay_send_email

      current_user.email
    end

    def cooked(text)
      return nil if text.blank?

      PrettyText.cook(text)
    end

    def proceed(api, result)
      checkout_id = result["id"]
      return {} if checkout_id.blank?

      api.proceed_plan_checkout(checkout_id)
    rescue BtcpayApi::ApiError => e
      # Fall back to BTCPay's own checkout page rather than failing the buy
      Rails.logger.warn("DiscourseBtcpay: Could not proceed checkout #{checkout_id}: #{e.message}")
      {}
    end

    # BTCPay builds these URLs from whatever host it thinks it is reachable at.
    # Behind a reverse proxy that does not forward Host/X-Forwarded-*, that is
    # "localhost", which is useless to the payer — so re-point the URL at the
    # configured server while keeping its path.
    def public_checkout_url(url)
      return url if url.blank?

      configured = URI.parse(SiteSetting.btcpay_server_url.chomp("/"))
      given = URI.parse(url)
      return url if given.host.blank? || given.host == configured.host

      Rails.logger.warn(
        "DiscourseBtcpay: BTCPay returned a checkout URL on #{given.host}; " \
        "rewriting to #{configured.host}. Check BTCPay's server URL and your proxy headers."
      )

      rebuilt = configured.dup
      rebuilt.path = given.path
      rebuilt.query = given.query
      rebuilt.fragment = given.fragment
      rebuilt.to_s
    rescue URI::InvalidURIError
      url
    end

    # A real portal session, not a guessed URL
    def portal_url(customer_id)
      return nil if customer_id.blank?

      BtcpayApi.new.portal_session(customer_id)["url"]
    rescue BtcpayApi::ApiError => e
      Rails.logger.warn("DiscourseBtcpay: Could not create portal session: #{e.message}")
      nil
    end
  end
end
