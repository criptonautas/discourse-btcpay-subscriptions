import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import { eq, not, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { btcpayText } from "../lib/btcpay-text";

// The modal only tells us "closed", never "settled" — BTCPay decides that
// asynchronously once the payment confirms. So we ask our own endpoint.
const POLL_INTERVAL_MS = 10_000;
const POLL_LIMIT = 60;

// BTCPay's recurringType values; anything else shows as it comes
const INTERVALS = ["Monthly", "Quarterly", "Yearly", "Lifetime"];

function intervalLabel(interval) {
  return INTERVALS.includes(interval)
    ? i18n(`btcpay.checkout.intervals.${interval.toLowerCase()}`)
    : interval;
}

// Days per BTCPay interval, for the rough per-day price; Lifetime has none
const DAYS = { Monthly: 30, Quarterly: 91, Yearly: 365 };

// "quarterly (~2 per day)", or just the interval when there is no per-day
function cadenceLabel(plan) {
  if (!plan.interval) {
    return null;
  }

  const interval = intervalLabel(plan.interval);
  const days = DAYS[plan.interval];
  const perDay = parseFloat(plan.price) / days;
  if (!days || !(perDay > 0)) {
    return interval;
  }

  return i18n("btcpay.checkout.cadence", {
    interval,
    per_day: i18n("btcpay.checkout.per_day", {
      amount: perDay < 1 ? "<1" : `~${Math.round(perDay)}`,
    }),
  });
}

let modalScript = null;

function loadModalScript(url) {
  modalScript ||= new Promise((resolve, reject) => {
    // Injected from already-trusted code so strict-dynamic allows it; a
    // blocked or missing script rejects and we fall back to a redirect.
    const el = document.createElement("script");
    el.src = url;
    el.async = true;
    el.onload = resolve;
    el.onerror = () => {
      modalScript = null;
      reject(new Error("btcpay.js failed to load"));
    };
    document.head.appendChild(el);
  });

  return modalScript;
}

// btcpay.js exposes no stable close API across versions, so hide whatever it
// left behind before opening another one.
function closeModal() {
  window.btcpay?.hideFrame?.();
  document
    .querySelectorAll(".btcpay-modal, #btcpay, iframe[src*='/modal/']")
    .forEach((el) => el.remove());
}

export default class BtcpayCheckout extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked plans = [];
  @tracked loading = false;
  @tracked error = null;
  @tracked selectedPlan = null;
  @tracked settled = false;
  @tracked currentPlanId = null;
  @tracked currentPrice = null;
  @tracked progress = null;
  @tracked currentLoaded = false;
  @tracked closed = false;

  pollTimer = null;
  pollCount = 0;
  modalOpen = false;

  constructor() {
    super(...arguments);
    if (this.isVisible && !this.isAnonymous) {
      this.load();
    } else if (this.isVisible) {
      this.currentLoaded = true;
      this.loadPlans();
    }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.stopPolling();
    if (this.modalOpen) {
      closeModal();
      this.modalOpen = false;
    }
  }

  // Anonymous visitors see the plans and their prices — only the buy step
  // needs an account, and BTCPay never has to ask them anything.
  get isVisible() {
    return this.siteSettings.btcpay_enabled;
  }

  // On the billing tab the picker is an offer to subscribe, so it steps aside
  // for a subscriber — and stays away until we know, rather than flashing the
  // plans at someone who already has one.
  get isHidden() {
    return (
      this.args.onlyWithoutSubscription &&
      (!this.currentLoaded || this.currentPlanId)
    );
  }

  get shouldRender() {
    return this.isVisible && !this.isHidden;
  }

  get isAnonymous() {
    return !this.currentUser;
  }

  // Either they can pay as a guest, or they have to sign in first
  get needsLogin() {
    return this.isAnonymous && !this.siteSettings.btcpay_anonymous_checkout;
  }

  get loginUrl() {
    return getURL("/login");
  }

  get buttonLabel() {
    return btcpayText(
      this.siteSettings,
      "btcpay_button_label",
      "btcpay.checkout.default_label"
    );
  }

  get cardButtonLabel() {
    return btcpayText(
      this.siteSettings,
      "btcpay_card_button_label",
      "btcpay.checkout.card_label"
    );
  }

  // Each plan carries how it relates to what the user already has
  get offers() {
    return this.plans.map((plan) => {
      const isCurrent = plan.plan_id === this.currentPlanId;
      const cheaper =
        this.currentPrice !== null &&
        parseFloat(plan.price) < parseFloat(this.currentPrice);

      return {
        ...plan,
        cadenceLabel: cadenceLabel(plan),
        isCurrent,
        // Downgrades are a later feature; until then they are not selectable
        isBlocked: !isCurrent && cheaper,
        isUpgrade:
          !isCurrent &&
          this.currentPlanId &&
          parseFloat(plan.price) > parseFloat(this.currentPrice),
      };
    });
  }

  get selectable() {
    return this.offers.filter((o) => !o.isCurrent && !o.isBlocked);
  }

  async load() {
    await Promise.all([this.loadPlans(), this.loadCurrent()]);

    if (!this.selectedPlan && this.selectable.length === 1) {
      this.selectedPlan = this.selectable[0].plan_id;
    }
  }

  async loadPlans() {
    try {
      const result = await ajax("/btcpay/plans");
      this.plans = result.plans || [];
      this.closed = !!result.closed;
    } catch (e) {
      this.error = extractError(e);
    }
  }

  async loadCurrent() {
    try {
      const result = await ajax("/btcpay/subscription");
      this.progress = result.payment_progress;

      if (result.subscription?.status === "active") {
        this.currentPlanId = result.subscription.plan_id;
        this.currentPrice =
          this.plans.find((p) => p.plan_id === this.currentPlanId)?.price ??
          null;
      }
    } catch {
      // Not fatal — the user can still start a checkout.
    } finally {
      this.currentLoaded = true;
    }
  }

  @action
  selectPlan(planId) {
    this.selectedPlan = planId;
  }

  get closedText() {
    return btcpayText(
      this.siteSettings,
      "btcpay_closed_text",
      "btcpay.checkout.closed"
    );
  }

  get cardEnabled() {
    return this.siteSettings.btcpay_card_payments;
  }

  @action
  async checkout(paymentMethod) {
    // Guard the click itself: loading covers the request, modalOpen covers a
    // checkout already on screen.
    if (!this.selectedPlan || this.loading || this.modalOpen) {
      return;
    }

    this.loading = true;
    this.error = null;

    try {
      const result = await ajax("/btcpay/checkout", {
        type: "POST",
        data: {
          plan_id: this.selectedPlan,
          ...(paymentMethod === "card" && { payment_method: "card" }),
        },
      });

      // Credit covered it: the plan is already running, nothing to pay
      if (result.plan_started) {
        this.settled = true;
        await this.loadCurrent();
        return;
      }

      if (await this.openModal(result)) {
        return;
      }

      if (result.checkout_url) {
        window.location.href = result.checkout_url;
      } else {
        this.error = i18n("btcpay.checkout.failed");
      }
    } catch (e) {
      this.error = extractError(e, i18n("btcpay.checkout.failed"));
    } finally {
      this.loading = false;
    }
  }

  async openModal(result) {
    if (!result.invoice_id || !result.modal_url) {
      return false;
    }

    try {
      await loadModalScript(result.modal_url);
      if (!window.btcpay?.showInvoice) {
        return false;
      }

      // showInvoice appends a fresh overlay every call, so a second click
      // would stack a second BTCPay checkout on top of the first.
      closeModal();
      window.btcpay.showInvoice(result.invoice_id);
      this.modalOpen = true;
      this.startPolling();
      return true;
    } catch {
      return false;
    }
  }

  startPolling() {
    this.stopPolling();
    this.pollCount = 0;
    this.pollTimer = setInterval(() => this.pollStatus(), POLL_INTERVAL_MS);
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  async pollStatus() {
    this.pollCount++;
    if (this.pollCount > POLL_LIMIT) {
      this.stopPolling();
      return;
    }

    try {
      const result = await ajax("/btcpay/subscription");
      this.progress = result.payment_progress;

      if (result.subscription?.status === "active") {
        this.settled = true;
        this.progress = null;
        this.currentPlanId = result.subscription.plan_id;
        this.stopPolling();
        if (this.modalOpen) {
          closeModal();
          this.modalOpen = false;
        }
        this.args.onSettled?.();
      }
    } catch {
      // A failed poll is not a failed payment; the reconcile job is the net.
    }
  }

  <template>
    {{#if this.shouldRender}}
      <div class="btcpay-checkout-section">
        {{#if this.settled}}
          <div class="btcpay-settled alert alert-success">
            {{i18n "btcpay.checkout.settled"}}
          </div>
        {{/if}}

        {{#if this.progress}}
          <div class="btcpay-progress alert alert-info">
            <p class="btcpay-progress-headline">
              {{i18n "btcpay.checkout.waiting_payment"}}
            </p>
            <ul class="btcpay-progress-list">
              {{#each this.progress.payments as |payment|}}
                <li class={{if payment.settled "settled" "pending"}}>
                  {{i18n
                    "btcpay.checkout.received"
                    value=payment.value
                    method=payment.method
                  }}
                  —
                  {{if
                    payment.settled
                    (i18n "btcpay.checkout.confirmed")
                    (i18n "btcpay.checkout.unconfirmed")
                  }}
                </li>
              {{/each}}
            </ul>
          </div>
        {{/if}}

        {{#if this.offers.length}}
          <fieldset class="btcpay-plans">
            <legend class="btcpay-plans__legend">
              {{i18n "btcpay.checkout.choose_plan"}}
            </legend>

            {{#each this.offers as |plan|}}
              <label
                class="btcpay-plan
                  {{if (eq this.selectedPlan plan.plan_id) 'is-selected'}}
                  {{if plan.isCurrent 'is-current'}}
                  {{if plan.isBlocked 'is-blocked'}}"
              >
                <input
                  type="radio"
                  class="btcpay-plan__radio"
                  name="btcpay_plan"
                  value={{plan.plan_id}}
                  checked={{eq this.selectedPlan plan.plan_id}}
                  disabled={{or this.needsLogin plan.isCurrent plan.isBlocked}}
                  {{on "change" (fn this.selectPlan plan.plan_id)}}
                />

                <span class="btcpay-plan__body">
                  <span class="btcpay-plan__top">
                    <span class="btcpay-plan__art" aria-hidden="true">
                      <svg viewBox="0 0 96 56" focusable="false">
                        <path
                          d="M8 4h80a4 4 0 0 1 4 4v12a8 8 0 0 0 0 16v12a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V36a8 8 0 0 0 0-16V8a4 4 0 0 1 4-4z"
                          fill="currentColor"
                          opacity="0.15"
                        />
                        <path
                          d="M8 4h80a4 4 0 0 1 4 4v12a8 8 0 0 0 0 16v12a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V36a8 8 0 0 0 0-16V8a4 4 0 0 1 4-4z"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="2"
                        />
                        <path
                          d="M68 8v40"
                          stroke="currentColor"
                          stroke-width="2"
                          stroke-dasharray="3 4"
                        />
                        <path
                          d="M38 28l-4.7 2.5.9-5.3-3.8-3.7 5.3-.8L38 16l2.3 4.7 5.3.8-3.8 3.7.9 5.3z"
                          fill="currentColor"
                        />
                      </svg>
                    </span>

                    <span class="btcpay-plan__header">
                      {{! A label may only hold phrasing content, so no h3 }}
                      <span
                        class="btcpay-plan__name"
                        role="heading"
                        aria-level="3"
                      >{{plan.label}}</span>

                      {{#if plan.isCurrent}}
                        <span class="btcpay-plan__badge --current">
                          {{i18n "btcpay.checkout.current_plan"}}
                        </span>
                      {{else if plan.isUpgrade}}
                        <span class="btcpay-plan__badge --upgrade">
                          {{i18n "btcpay.checkout.upgrade"}}
                        </span>
                      {{/if}}
                    </span>
                  </span>

                  {{#if plan.description_html}}
                    <span class="btcpay-plan__description cooked">
                      {{htmlSafe plan.description_html}}
                    </span>
                  {{else if plan.description}}
                    <span class="btcpay-plan__description">
                      {{plan.description}}
                    </span>
                  {{/if}}

                  {{#if plan.trial_days}}
                    <span class="btcpay-plan__trial">
                      {{i18n
                        "btcpay.checkout.trial_days"
                        count=plan.trial_days
                      }}
                    </span>
                  {{/if}}

                  {{#if plan.isBlocked}}
                    <span class="btcpay-plan__note">
                      {{i18n "btcpay.checkout.downgrade_unavailable"}}
                    </span>
                  {{/if}}

                  {{#if plan.price}}
                    <span class="btcpay-plan__price">
                      <span class="btcpay-plan__amount">
                        {{plan.price}}
                        {{plan.currency}}
                      </span>
                      {{#if plan.cadenceLabel}}
                        <span class="btcpay-plan__cadence">
                          {{plan.cadenceLabel}}
                        </span>
                      {{/if}}
                    </span>
                  {{/if}}
                </span>
              </label>
            {{/each}}
          </fieldset>

          <div class="btcpay-checkout__actions">
            {{#if this.needsLogin}}
              <a
                href={{this.loginUrl}}
                class="btn btn-primary btcpay-checkout-btn"
              >
                {{i18n "btcpay.checkout.login_to_subscribe"}}
              </a>
            {{else}}
              <button
                type="button"
                class="btn btn-primary btcpay-checkout-btn"
                disabled={{or this.loading (not this.selectedPlan)}}
                {{on "click" (fn this.checkout "crypto")}}
              >
                {{if
                  this.loading
                  (i18n "btcpay.checkout.processing")
                  this.buttonLabel
                }}
              </button>

              {{#if this.cardEnabled}}
                <button
                  type="button"
                  class="btn btn-default btcpay-checkout-btn btcpay-card-btn"
                  disabled={{or this.loading (not this.selectedPlan)}}
                  {{on "click" (fn this.checkout "card")}}
                >
                  {{this.cardButtonLabel}}
                </button>
              {{/if}}
            {{/if}}
          </div>
        {{else}}
          <p class="btcpay-no-plans">
            {{if this.closed this.closedText (i18n "btcpay.checkout.no_plans")}}
          </p>
        {{/if}}

        {{#if this.error}}
          <div class="btcpay-error alert alert-error">{{this.error}}</div>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
