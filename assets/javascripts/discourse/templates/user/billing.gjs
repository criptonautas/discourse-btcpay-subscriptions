import bodyClass from "discourse/helpers/body-class";
import BtcpayCheckout from "../../components/btcpay-checkout";
import BtcpayPageHeader from "../../components/btcpay-page-header";
import BtcpaySubscriptionStatus from "../../components/btcpay-subscription-status";

export default <template>
  {{! The profile header pushes billing below the fold; the tabs stay }}
  {{bodyClass "btcpay-billing-route"}}
  <div class="btcpay-page btcpay-billing-page">
    <BtcpayPageHeader @page="billing" />
    <BtcpaySubscriptionStatus />
    <BtcpayCheckout @onlyWithoutSubscription={{true}} />
  </div>
</template>
