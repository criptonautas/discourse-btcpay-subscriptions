# frozen_string_literal: true

# name: discourse-btcpay-subscriptions
# about: BTCPay Server subscription integration for Discourse
# version: 1.0.0
# authors: Criptonautas
# url: https://github.com/criptonautas/discourse-btcpay-subscriptions
# required_version: 3.4.0

enabled_site_setting :btcpay_enabled

register_asset "stylesheets/btcpay.scss"

# Neither is in Discourse's default icon subset, so they have to be requested
# or the billing tab and the admin plugin list render a blank glyph. Plain core
# names, so an icon theme can redirect them to its own set.
register_svg_icon "ticket-simple"
register_svg_icon "bitcoin-sign"

# The location is the plugin directory name, so the admin plugin list links
# straight to our dashboard at /admin/plugins/discourse-btcpay-subscriptions.
add_admin_route "btcpay.admin.title", "discourse-btcpay-subscriptions"

after_initialize do
  module ::DiscourseBtcpay
    PLUGIN_NAME = "discourse-btcpay-subscriptions"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseBtcpay
    end

    def self.store_subscription(user_id, data)
      ::PluginStore.set(PLUGIN_NAME, "sub:#{user_id}", data)
    end

    def self.get_subscription(user_id)
      ::PluginStore.get(PLUGIN_NAME, "sub:#{user_id}")
    end

    def self.store_payments(user_id, payments)
      ::PluginStore.set(PLUGIN_NAME, "payments:#{user_id}", payments)
    end

    def self.get_payments(user_id)
      ::PluginStore.get(PLUGIN_NAME, "payments:#{user_id}") || []
    end

    PLANS_CACHE_TTL = 10.minutes

    # The offering is the catalogue: plans are read from BTCPay, not typed in
    # twice. Cached per store+offering so a busy page does not hammer it.
    def self.remote_plans(refresh: false)
      api = BtcpayApi.new
      return [] unless api.configured?

      key = "btcpay_plans_#{SiteSetting.btcpay_store_id}_#{SiteSetting.btcpay_offering_id}"
      ::Discourse.cache.delete(key) if refresh

      plans =
        ::Discourse.cache.fetch(key, expires_in: PLANS_CACHE_TTL) do
          begin
            api.plans
          rescue BtcpayApi::ApiError => e
            Rails.logger.warn("DiscourseBtcpay: Could not fetch plans from BTCPay: #{e.message}")
            nil
          end
        end

      plans.is_a?(Array) ? plans : []
    end

    def self.remote_plan(plan_id)
      remote_plans.find { |p| p["id"] == plan_id }
    end

    # A plan earns its Discourse group from, in order: a mapping an admin set
    # on the BTCPay page, `discourse_group` in the plan's own BTCPay metadata,
    # or the default group setting. No JSON to hand-write anywhere.
    def self.plan_groups
      ::PluginStore.get(PLUGIN_NAME, "plan_groups") || {}
    end

    def self.set_plan_group(plan_id, group_name)
      groups = plan_groups
      if group_name.blank?
        groups.delete(plan_id)
      else
        groups[plan_id] = group_name
      end
      ::PluginStore.set(PLUGIN_NAME, "plan_groups", groups)
    end

    def self.group_for_plan(plan_id, plan: nil)
      override = plan_groups[plan_id]
      return override if override.present?

      plan ||= remote_plan(plan_id)
      from_btcpay = plan&.dig("metadata", "discourse_group")
      return from_btcpay if from_btcpay.present?

      SiteSetting.btcpay_default_group.presence
    end

    def self.group_source(plan_id, plan: nil)
      return "admin" if plan_groups[plan_id].present?

      plan ||= remote_plan(plan_id)
      return "btcpay" if plan&.dig("metadata", "discourse_group").present?
      return "default" if SiteSetting.btcpay_default_group.present?

      nil
    end

    def self.label_for_plan(plan_id, plan: nil)
      plan ||= remote_plan(plan_id)
      plan&.dig("name").presence || plan_id
    end

    # The payment method id the BTCPay Stripe plugin registers. Opening an
    # invoice on it is how a card payment still runs through BTCPay.
    STRIPE_PAYMENT_METHOD = "STRIPE"

    DONATION_ORDER_PREFIX = "btcpay-donation"

    def self.donation_order_id(user_id)
      payload = "#{user_id}:#{SecureRandom.hex(8)}"
      "#{DONATION_ORDER_PREFIX}:#{payload}:#{donation_signature(payload)}"
    end

    # "btcpay-donation:<user_id>:<nonce>:<hmac>". The POS endpoint is public and
    # takes any orderId, so only the signature proves /donate issued it, with
    # the donor and the minimum it checked.
    def self.user_id_from_order(order_id)
      prefix, user_id, nonce, signature = order_id.to_s.split(":")
      return nil unless prefix == DONATION_ORDER_PREFIX && signature.present?
      return nil unless ActiveSupport::SecurityUtils.secure_compare(
        signature,
        donation_signature("#{user_id}:#{nonce}")
      )

      user_id.to_i.positive? ? user_id.to_i : nil
    end

    def self.donation_signature(payload)
      key = Rails.application.secret_key_base
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{DONATION_ORDER_PREFIX}:#{payload}")[0, 32]
    end

    def self.donation_recorded?(invoice_id)
      ::PluginStore.get(PLUGIN_NAME, "donation:#{invoice_id}").present?
    end

    # One row per invoice for the audit trail, one per donor for the totals.
    def self.record_donation(user_id:, invoice_id:, amount:, currency:)
      return if invoice_id.blank? || donation_recorded?(invoice_id)

      value = amount.to_f
      ::PluginStore.set(PLUGIN_NAME, "donation:#{invoice_id}", {
        "user_id" => user_id,
        "amount" => value,
        "currency" => currency,
        "paid_at" => Time.now.iso8601
      })

      return if user_id.blank?

      donor = ::PluginStore.get(PLUGIN_NAME, "donor:#{user_id}") || { "total" => 0, "count" => 0 }
      donor["total"] = donor["total"].to_f + value
      donor["count"] = donor["count"].to_i + 1
      donor["last_at"] = Time.now.iso8601
      ::PluginStore.set(PLUGIN_NAME, "donor:#{user_id}", donor)
    end

    def self.each_donor
      return enum_for(:each_donor) unless block_given?

      ::PluginStoreRow
        .where(plugin_name: PLUGIN_NAME)
        .where("key LIKE ?", "donor:%")
        .find_each do |row|
          data = JSON.parse(row.value) rescue next
          yield row.key.sub("donor:", "").to_i, data
        end
    end

    def self.donation_total
      each_donor.sum { |_user_id, data| data["total"].to_f }
    end

    # Badge handed to donors, chosen on the admin page
    def self.donor_badge_id
      ::PluginStore.get(PLUGIN_NAME, "donor_badge")
    end

    def self.set_donor_badge(badge_id)
      if badge_id.blank?
        ::PluginStore.remove(PLUGIN_NAME, "donor_badge")
      else
        ::PluginStore.set(PLUGIN_NAME, "donor_badge", badge_id.to_i)
      end
    end

    # Badge + leaderboard points, both optional and both no-ops when not set up
    def self.reward_donor(user, amount)
      grant_donor_badge(user)
      award_donation_points(user, amount)
    end

    def self.grant_donor_badge(user)
      badge_id = donor_badge_id
      return if badge_id.blank?

      badge = Badge.find_by(id: badge_id, enabled: true)
      return unless badge

      ::BadgeGranter.grant(badge, user)
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Could not grant donor badge: #{e.message}")
    end

    def self.award_donation_points(user, amount)
      points = (SiteSetting.btcpay_donation_points.to_i * amount.to_f).round
      return if points <= 0
      return unless defined?(::DiscourseGamification::GamificationScoreEvent)

      ::DiscourseGamification::GamificationScoreEvent.create!(
        user_id: user.id,
        date: Date.today,
        points: points,
        description: "BTCPay donation"
      )
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Could not award donation points: #{e.message}")
    end

    # A payment from someone with no account yet: remembered by email until
    # they accept the invite and an account exists to attach it to.
    def self.store_claim(email, data)
      ::PluginStore.set(PLUGIN_NAME, "claim:#{email.to_s.downcase}", data)
    end

    def self.get_claim(email)
      ::PluginStore.get(PLUGIN_NAME, "claim:#{email.to_s.downcase}")
    end

    def self.clear_claim(email)
      ::PluginStore.remove(PLUGIN_NAME, "claim:#{email.to_s.downcase}")
    end

    # Some facts reach us twice — BTCPay fires both InvoiceExpired and
    # InvoiceExpiredPaidPartial for one underpaid invoice — so alerts are
    # deduplicated by a key rather than sent per delivery.
    def self.first_alert?(key)
      seen = ::PluginStore.get(PLUGIN_NAME, "alerts") || []
      return false if seen.include?(key)

      ::PluginStore.set(PLUGIN_NAME, "alerts", (seen << key).last(500))
      true
    end

    # Live payment progress for the invoice a user is currently paying.
    # Short-lived: cleared once the invoice settles, expires or goes invalid.
    def self.store_payment_progress(user_id, progress)
      ::PluginStore.set(PLUGIN_NAME, "progress:#{user_id}", progress)
    end

    def self.get_payment_progress(user_id)
      ::PluginStore.get(PLUGIN_NAME, "progress:#{user_id}")
    end

    def self.clear_payment_progress(user_id)
      ::PluginStore.remove(PLUGIN_NAME, "progress:#{user_id}")
    end

    # One place that knows how subscription rows are stored, so the webhook,
    # the reconcile job and the admin list stop re-deriving it.
    # Ordered by key so a caller can resume from where it stopped.
    def self.each_subscription(after_key: nil, limit: nil)
      return enum_for(:each_subscription, after_key: after_key, limit: limit) unless block_given?

      scope = ::PluginStoreRow.where(plugin_name: PLUGIN_NAME).where("key LIKE ?", "sub:%")
      scope = scope.where("key > ?", after_key) if after_key.present?

      rows = limit ? scope.order(:key).limit(limit) : scope.order(:key)

      rows.each do |row|
        data = JSON.parse(row.value) rescue next
        yield row.key.sub("sub:", "").to_i, data, row.key
      end
    end

    def self.user_id_for_customer(customer_id)
      return nil if customer_id.blank?

      each_subscription do |user_id, data, _key|
        return user_id if data["customer_id"] == customer_id
      end
      nil
    end

    def self.processed_invoice?(invoice_id)
      processed = ::PluginStore.get(PLUGIN_NAME, "processed_invoices") || []
      processed.include?(invoice_id)
    end

    def self.mark_invoice_processed(invoice_id)
      processed = ::PluginStore.get(PLUGIN_NAME, "processed_invoices") || []
      return if processed.include?(invoice_id)
      processed << invoice_id
      # Keep last 1000 to prevent unbounded growth
      processed = processed.last(1000)
      ::PluginStore.set(PLUGIN_NAME, "processed_invoices", processed)
    end

    def self.delivery_processed?(delivery_id)
      (::PluginStore.get(PLUGIN_NAME, "processed_deliveries") || []).include?(delivery_id)
    end

    def self.mark_delivery_processed(delivery_id)
      processed = ::PluginStore.get(PLUGIN_NAME, "processed_deliveries") || []
      return if processed.include?(delivery_id)
      # shortcut: keeps the last 5000, so a far older capture still replays;
      # move to a table if that ever matters.
      ::PluginStore.set(PLUGIN_NAME, "processed_deliveries", (processed << delivery_id).last(5000))
    end

    def self.log_hmac_failure
      failures = ::PluginStore.get(PLUGIN_NAME, "hmac_failures") || { count: 0, last_at: nil }
      failures[:count] += 1
      failures[:last_at] = Time.now.iso8601
      ::PluginStore.set(PLUGIN_NAME, "hmac_failures", failures)

      if failures[:count] >= 3
        notify_admin(:hmac_failures, count: failures[:count])
        failures[:count] = 0
        ::PluginStore.set(PLUGIN_NAME, "hmac_failures", failures)
      end
    end

    def self.reset_hmac_failures
      ::PluginStore.set(PLUGIN_NAME, "hmac_failures", { count: 0, last_at: nil })
    end

    # key → discourse_btcpay.alerts.<key>.{subject,body}, rendered in the
    # recipient admin's locale rather than hardcoded English.
    def self.notify_admin(key, **args)
      with_admin_locale do |admin|
        deliver_admin_message(
          admin,
          I18n.t("discourse_btcpay.alerts.#{key}.subject"),
          I18n.t("discourse_btcpay.alerts.#{key}.body", **args)
        )
      end
    end

    def self.with_admin_locale
      admin = User.where(admin: true).where("id > 0").order(:id).first
      return unless admin

      I18n.with_locale(admin.effective_locale) { yield admin }
    rescue => e
      Rails.logger.error("DiscourseBtcpay: Failed to notify admin: #{e.message}")
    end

    def self.deliver_admin_message(admin, subject, body)
      SystemMessage.create_from_system_user(
        admin,
        :btcpay_admin_notification,
        subject: subject,
        body: body
      )
    end
  end

  require_relative "app/services/btcpay_api"
  require_relative "app/services/btcpay_subscription_manager"
  require_relative "app/controllers/btcpay_pages_controller"
  require_relative "app/controllers/btcpay_webhook_controller"
  require_relative "app/controllers/btcpay_checkout_controller"
  require_relative "app/controllers/btcpay_donations_controller"
  require_relative "app/controllers/admin/btcpay_admin_controller"
  require_relative "app/jobs/scheduled/btcpay_reconcile"

  # Routes
  DiscourseBtcpay::Engine.routes.draw do
    post "/webhook" => "btcpay_webhook#handle"
    post "/checkout" => "btcpay_checkout#create"
    get "/subscription" => "btcpay_checkout#status"
    get "/plans" => "btcpay_checkout#plans"
    post "/donate" => "btcpay_donations#create"
    get "/donations" => "btcpay_donations#index"
  end

  Discourse::Application.routes.append do
    mount DiscourseBtcpay::Engine, at: "/btcpay"

    # Server-side entry points for the client-side pages
    get "/tickets" => "discourse_btcpay/btcpay_pages#index"
    get "/u/:username/billing" => "discourse_btcpay/btcpay_pages#index",
        :constraints => {
          username: RouteFormat.username,
        }

    # JSON only. The admin page itself is an Ember route under
    # adminPlugins.show, so no HTML route may live at this prefix.
    scope "/admin/plugins/btcpay", constraints: StaffConstraint.new, defaults: { format: :json } do
      get "/status" => "discourse_btcpay/admin/btcpay_admin#index"
      get "/subscriptions" => "discourse_btcpay/admin/btcpay_admin#subscriptions"
      post "/plan_group" => "discourse_btcpay/admin/btcpay_admin#plan_group"
      post "/donor_badge" => "discourse_btcpay/admin/btcpay_admin#donor_badge"
      post "/sync" => "discourse_btcpay/admin/btcpay_admin#sync"
    end
  end

  # Someone who paid before having an account: attach the subscription once the
  # account proves it owns the email, whether they arrived by invite or signed
  # up directly. Before that, anyone who knew the address could claim it.
  attach_claim = ->(user) do
    claim = DiscourseBtcpay.get_claim(user.email)
    next unless claim

    DiscourseBtcpay::BtcpaySubscriptionManager.new.activate(
      user_id: user.id,
      customer_id: claim["customer_id"],
      plan_id: claim["plan_id"]
    )
    DiscourseBtcpay.clear_claim(user.email)
  end

  # Already active at creation means the email was verified upstream (OAuth, SSO)
  on(:user_created) { |user| attach_claim.call(user) if user.active? }
  on(:user_confirmed_email) { |user, _scope| attach_claim.call(user) }

  # Plugin-store rows are keyed by user id, so they would outlive the account.
  on(:user_destroyed) do |user|
    %w[sub payments progress].each do |prefix|
      PluginStore.remove(DiscourseBtcpay::PLUGIN_NAME, "#{prefix}:#{user.id}")
    end
  end

  # Add BTCPay tab to user preferences
  add_to_serializer(
    :current_user,
    :btcpay_subscription,
    include_condition: -> { SiteSetting.btcpay_enabled }
  ) do
    sub = DiscourseBtcpay.get_subscription(object.id)
    return nil unless sub
    {
      status: sub["status"],
      plan_name: sub["plan_name"],
      period_end: sub["period_end"]
    }
  end
end
