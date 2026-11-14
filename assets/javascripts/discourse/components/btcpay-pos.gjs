import Component from "@glimmer/component";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";

// BTCPay Point of Sale in an iframe; sized in btcpay.scss.
// <BtcpayPos /> loads the POS mapped to the BTCPay root; @src picks another app.
export default class BtcpayPos extends Component {
  @service siteSettings;

  get src() {
    return this.args.src || this.siteSettings.btcpay_server_url;
  }

  <template>
    <iframe
      class="btcpay-pos"
      src={{this.src}}
      title={{i18n "btcpay.pos.title"}}
      allow="clipboard-write; payment"
      loading="lazy"
    ></iframe>
  </template>
}
