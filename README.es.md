# discourse-btcpay-subscriptions

[![Linting and Tests](https://github.com/criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml/badge.svg)](https://github.com/criptonautas/discourse-btcpay-subscriptions/actions/workflows/plugin-linting-and-tests.yml)

[ENGLISH](README.md) | **ESPAÑOL**

Mantenido por Criptonautas. Sin afiliación ni respaldo de Discourse (Civilized Discourse Construction Kit, Inc.).

Integración de suscripciones de BTCPay Server para Discourse. Vende acceso a grupos con cualquier cripto que soporte BTCPay — BTC, XMR, LTC, Lightning — con precios fijados en moneda fiat. Autónomo: no necesita Stripe ni `discourse-subscriptions`.

## Arquitectura

```
El usuario pulsa "Pagar en cripto" en Discourse
    → Discourse crea el checkout con la API Greenfield de BTCPay
    → El usuario es redirigido a la página de pago de BTCPay
    → Paga → BTCPay liquida la factura
    → BTCPay dispara el webhook → Discourse añade al usuario al grupo
    → La tarea de reconciliación recupera los webhooks perdidos
```

BTCPay es el dueño del ciclo de vida de la suscripción. Discourse gestiona la pertenencia al grupo y muestra el estado.

## Requisitos

- Discourse 3.4+ (desarrollado y probado en CI contra `latest`; el frontend usa componentes `.gjs`, `discourse/truth-helpers` y `discourse-i18n`, que no existen en versiones anteriores)
- BTCPay Server 2.3+ (con la función de Suscripciones)
- Ambos en el mismo servidor (o accesibles entre sí por red)
- Nginx como proxy inverso con SSL válido

## Instalación

### 1. Instalar el plugin

Edita el `app.yml` de tu Discourse:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/criptonautas/discourse-btcpay-subscriptions.git
```

Reconstruye Discourse:

```bash
cd /var/discourse
./launcher rebuild app
```

### 2. Configurar BTCPay Server

1. Ve a **BTCPay Server → Tu tienda → Subscriptions**
2. Crea una **Offering** y uno o varios **Plans** con precio en fiat (p. ej. "Premium Mensual — 10 $/mes")
3. Anota el **Offering ID** y el **Plan ID** de cada plan — los planes viven dentro de una oferta
4. Ve a **Account → Manage Account → API Keys**
5. Crea una clave de API con estos permisos:
   - `btcpay.store.canviewofferings` — leer la oferta, sus planes y los suscriptores
   - `btcpay.store.canmanagesubscribers` — crear checkouts de plan y sesiones de portal
   - `btcpay.store.canviewinvoices` — leer las facturas liquidadas para el historial
   - `btcpay.store.canviewstoresettings` — panel de servidor/red en la página de admin
6. Ve a **Store Settings → Webhooks**
7. Crea un webhook:
   - **URL:** `https://tudiscourse.com/btcpay/webhook`
   - **Eventos:** `PlanStarted`, `SubscriberCreated`, `SubscriberActivated`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `SubscriberCharged`, `SubscriberCredited`, `SubscriberNeedUpgrade`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`
   - **Secreto:** genéralo y guárdalo — lo necesitas en los ajustes de Discourse
8. En **Checkout Appearance**, asegúrate de permitir las URLs de redirección

### 3. Configurar Discourse

Ve a **Admin → Ajustes** y busca `btcpay`:

| Ajuste | Valor |
|---------|-------|
| `btcpay_enabled` | ✓ |
| `btcpay_server_url` | `https://btcpay.tudominio.com` |
| `btcpay_api_key` | Tu clave de API Greenfield |
| `btcpay_store_id` | El ID de tu tienda de BTCPay |
| `btcpay_offering_id` | El ID de la oferta que contiene tus planes |
| `btcpay_webhook_secret` | El secreto del paso 7 |
| `btcpay_default_group` | Opcional: un grupo para todos los planes |
| `btcpay_send_email` | ✓ (evita que BTCPay pida el email) |
| `btcpay_anonymous_checkout` | Opcional: permitir comprar sin sesión |
| `btcpay_card_payments` | Opcional: añade un botón "Pagar con tarjeta" (requiere el plugin Stripe de BTCPay) |
| `btcpay_button_label` | vacío (usa la traducción) |
| `btcpay_card_button_label` | vacío (usa la traducción) |
| `btcpay_reconcile_interval_hours` | `4` |

**Los planes no necesitan configuración.** Todos los planes de la oferta se obtienen de BTCPay con su precio en vivo, y cada uno concede un grupo de Discourse resuelto en este orden:

1. **El grupo que elijas en Admin → Plugins → BTCPay** — cada fila de plan tiene un desplegable de grupos.
2. **`discourse_group` en los metadatos del plan en BTCPay** — defínelo en el plan y Discourse no necesita configuración alguna.
3. **`btcpay_default_group`** — un grupo para todos los planes que no tengan uno propio, que es todo lo que necesita un foro de un solo nivel.

Un plan que no resuelva a ningún grupo aparece con un aviso en la página de admin y no se pone a la venta.

**Descripciones por idioma.** Agrega `description_es`, `description_en` (cualquier código de idioma de Discourse) a los metadatos del plan en BTCPay y cada visitante ve la de su idioma; la descripción propia del plan queda como respaldo. Todas admiten Markdown.

### Insertar los planes en una publicación

Envuelve cualquier cosa en una publicación con el wrap del plugin y el selector de planes se renderiza ahí mismo, para quien lo lee y con su plan actual ya marcado:

```
[wrap=btcpay-plans][/wrap]
```

No hace falta nada más: ni ajuste ni componente de tema. El componente de
donaciones se encarga de los wraps `donate*` y este plugin de `btcpay-plans`,
así que nunca chocan y cualquiera de los dos funciona sin el otro.

El plugin no agrega ningún enlace a la barra lateral: enlaza `/tickets` donde
corresponda en tu foro, o inserta el selector en un tema fijado y olvídate de
la página.

### Personalizar los textos

Todos los textos visibles están traducidos (el plugin incluye inglés y español) y se pueden sobrescribir de dos formas:

- **Ajustes del sitio** para los textos principales: `btcpay_button_label`, `btcpay_card_button_label`, `btcpay_tickets_title`, `btcpay_tickets_intro`, `btcpay_billing_title`, `btcpay_billing_intro`, `btcpay_nav_label`. Si los dejas vacíos se usa la traducción del idioma de cada usuario; si los rellenas, ese texto se muestra a todo el mundo.
- **Admin → Personalizar → Texto** para cualquier otro texto, incluidas versiones por idioma. Busca `btcpay.` para ver todas las claves.

### 4. Configuración de Nginx

Si BTCPay y Discourse comparten servidor, no hace falta nada extra: el enrutado de Discourse ya sirve `/btcpay/`. Solo asegúrate de que ninguna regla existente bloquee esa ruta.

Usa siempre la URL pública (`https://tudiscourse.com/btcpay/webhook`) como destino del webhook, para que la validación HMAC viaje sobre SSL.

## Cómo funciona

### Eventos del webhook

| Evento de BTCPay | Acción del plugin |
|---|---|
| `PlanStarted` | Activa la suscripción y añade al usuario al grupo asignado |
| `SubscriberPhaseChanged` | Trial/Normal/Grace actualizan el registro; Expired retira el grupo |
| `SubscriberDisabled` | `Expired` → vencida, `Suspension` → cancelada; saca del grupo |
| `InvoiceProcessing` | Marca la suscripción como "pendiente" — todavía sin acceso |
| `InvoiceReceivedPayment` | Registra un pago sin confirmar para mostrar el progreso |
| `InvoicePaymentSettled` | Marca ese pago como confirmado |
| `InvoiceSettled` | Registra el pago (y concede acceso si se perdió `PlanStarted`) |
| `InvoiceExpired` | Limpia un registro `pending` — una factura impagada nunca da acceso |
| `InvoiceInvalid` | Marca "en disputa", mantiene el acceso y avisa al admin |
| `SubscriberCreated` | Guarda el customer id de BTCPay — sin conceder acceso |
| `SubscriberActivated` | Restaura el acceso tras levantar una suspensión |
| `SubscriberCharged` | Registra una renovación pagada con el saldo de BTCPay |
| `SubscriberCredited` | Registra una recarga de saldo en el historial |
| `SubscriberNeedUpgrade` | Marca la cuenta y avisa al admin por MP; no toca el acceso |

Tres eventos de factura de BTCPay no están en el swagger de Greenfield pero existen y aparecen en la interfaz de webhooks — el plugin los trata todos:

| Etiqueta en la interfaz | Tipo de evento | Qué hace el plugin |
|---|---|---|
| Invoice - Expired Paid Partial | `InvoiceExpiredPaidPartial` | Avisa al admin con el importe recibido y limpia el registro pendiente |
| Invoice - Paid Late | `InvoicePaidAfterExpiration` | Avisa al admin — la factura ya había vencido, BTCPay no concedió nada y el dinero está retenido |
| Invoice - Refund | `InvoiceRefund` | Avisa al admin con el id del pull payment; no toca el acceso al grupo |

Esa misma información llega además como banderas en los eventos documentados, y también se trata, sin duplicar avisos por factura:

| Caso | Bandera | Qué hace el plugin |
|---|---|---|
| Pago parcial | `InvoiceExpired.partiallyPaid` | El mismo aviso que `InvoiceExpiredPaidPartial`, enviado una sola vez |
| Pago tardío | `InvoiceReceivedPayment.afterExpiration` | Se guarda en el registro de progreso del pago |
| Pago de más | `InvoiceSettled.overPaid` | Avisa al admin para devolver la diferencia desde BTCPay |
| Marcado a mano | `InvoiceSettled.manuallyMarked` | Se registra en el log para poder rastrearlo |

Sin suscribir: `InvoiceCreated` (aún no hay nada que hacer) y `PaymentReminder` (BTCPay ya avisa al suscriptor por email).

### Pruebas, periodo de gracia y cambios de plan

- **Pruebas y gracia** vienen de la fase de la suscripción en BTCPay (`Trial`, `Normal`, `Grace`, `Expired`). La pestaña de facturación muestra "La prueba termina el …" y "Pago pendiente — el acceso continúa hasta el …"; el acceso solo se retira cuando BTCPay informa `Expired` o desactiva al suscriptor.
- **Progreso del pago**: los pagos on-chain tardan de minutos a horas, así que `InvoiceReceivedPayment` / `InvoicePaymentSettled` se reflejan en un registro temporal y se muestran en vivo — "0.0004 recibidos por BTC — sin confirmar" — en lugar de dejar al pagador sin información. Se limpia cuando la factura se liquida, vence o se invalida.
- **Mejoras de plan**: al elegir un plan más caro se crea el checkout con `onPayBehavior: HardMigration`, de modo que el nuevo plan empieza de inmediato y BTCPay reembolsa la parte no usada del anterior. El grupo nuevo se añade con `PlanStarted`.
- **Bajar de plan aún no está implementado**: el plan más barato se muestra pero no se puede seleccionar, y el servidor lo rechaza con 422 aunque se salte el cliente. Los precios se comparan con los de BTCPay, nunca con los del cliente.

### Mecanismos de seguridad

- **Validación HMAC** en cada webhook, con aviso tras fallos consecutivos
- **Validación de content-type** — solo se acepta `application/json`
- **Procesamiento idempotente** — las entregas duplicadas se ignoran
- **Límites de tasa** — 60 webhooks/min por IP, 5 checkouts/min y 20/hora por usuario
- **Reconciliación periódica** (`btcpay_reconcile_interval_hours`, 4 por defecto)
- **Mapeo por user_id** — inmune a los cambios de nombre de usuario
- **MP al admin** ante: fallos de HMAC, grupos inexistentes y disputas

### Flujo del usuario

1. El usuario abre `/tickets`, o una publicación con el selector de planes insertado
2. Elige un plan — el precio mostrado es el que cobra BTCPay, consultado en vivo y cacheado 10 minutos
3. Pulsa **Pagar en cripto** → el checkout de BTCPay se abre en un modal sobre la página; no sale de Discourse
4. Paga con cualquier método que acepte la tienda (BTC, XMR, LTC, Lightning…)
5. `InvoiceProcessing` marca la suscripción como pendiente; la página consulta el estado y muestra "Pago recibido" cuando `InvoiceSettled` concede el grupo
6. El estado y el historial de pagos están en la pestaña **Facturación** del perfil (`/u/<usuario>/billing`), enlazada desde el menú del perfil; sin suscripción activa esa pestaña ofrece los planes
7. Renovación: BTCPay envía el aviso → paga → mantiene el acceso. Impago: llega el webhook → sale del grupo

Si el script del modal no puede cargarse (CSP, host de BTCPay caído), el botón recurre a la redirección completa a BTCPay y de vuelta a `btcpay_redirect_after_checkout`.

## Esquema del PluginStore

```
# Todas las filas viven bajo plugin_name = "discourse-btcpay-subscriptions"

sub:{user_id}          → { customer_id, offering_id, plan_id, plan_name,
                           group_name, status, phase, auto_renew, period_end,
                           trial_end, grace_period_end, next_plan_id,
                           next_plan_name, next_plan_at, needs_upgrade,
                           updated_at }

payments:{user_id}     → [ { invoice_id, amount, currency, payment_method,
                             status, paid_at }, ... ] (últimas 100)

progress:{user_id}     → { invoice_id, payments: [ { id, value, method, status,
                           settled, after_expiration, received_at } ],
                           updated_at }   (se limpia al resolverse la factura)

processed_invoices     → [ "invoice_id", ... ] (últimas 1000, idempotencia de liquidación)

alerts                 → [ "partial:INV1", "over:INV2", ... ] (últimos 500, avisos únicos
                           al admin)

hmac_failures          → { count, last_at }

reconcile_last_run_at  → marca ISO8601 de la última pasada completa
reconcile_cursor       → clave por la que continúa la siguiente pasada ("" = inicio)
```

Para inspeccionarlas:

```sql
SELECT key, value FROM plugin_store_rows
WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

### Qué sale de tu foro

Cada checkout envía a BTCPay el **id de usuario y el nombre de usuario** de quien paga, y el id del plan, como metadatos de la factura y del suscriptor. Nada más — ni email, ni mensajes, ni IP. BTCPay devuelve un id de cliente, datos de plan y periodo, e importes de pago, que se guardan en el plugin store como se describe arriba. El único host externo contactado es el de `btcpay_server_url`.

### Comprar sin cuenta

Desactivado por defecto. Activa `btcpay_anonymous_checkout` y cualquier visitante sin sesión podrá comprar: BTCPay le pide el email en el checkout y, cuando el pago se liquida, Discourse **le envía una invitación con el grupo del plan**. Al aceptarla se crea su cuenta ya con acceso, y su suscripción se vincula sola.

Por qué una invitación y no crear la cuenta directamente: BTCPay no verifica que quien paga sea el dueño de la dirección que escribió. La invitación sí — el enlace solo funciona desde ese buzón — así que un pago nunca puede crear una cuenta con el email de otra persona ni llenar tu lista de usuarios.

Si la dirección ya pertenece a un miembro no se envía invitación: la suscripción se vincula a esa cuenta y el grupo se concede al momento.

A quien ya ha iniciado sesión no se le pregunta nada: su email de Discourse viaja con el checkout (`btcpay_send_email`, activo por defecto) y BTCPay se salta ese paso.

### Pago con tarjeta

Desactivado por defecto. Instala el [plugin Stripe](https://plugin-builder.btcpayserver.org/public/plugins/stripe-payments) en BTCPay, actívalo en la tienda y luego activa `btcpay_card_payments`. El checkout muestra un segundo botón, **Pagar con tarjeta**, junto al de cripto.

Los dos botones crean la misma factura de suscripción; el de tarjeta solo la abre en `/i/<factura>/STRIPE`, así BTCPay muestra primero el formulario de Stripe. Quien paga puede cambiar de método en esa página. El pago con tarjeta abre la página completa de BTCPay en lugar del overlay, que no permite elegir método. La liquidación, los webhooks y el acceso al grupo no cambian.

Las renovaciones siguen siendo una factura por periodo: la tarjeta no se guarda ni se cobra sola.

Las donaciones usan el mismo interruptor. `POST /btcpay/donate` con `payment_method: "card"` abre la factura TPV de la donación en Stripe del mismo modo, así que una donación con tarjeta llega al mismo webhook que una en cripto: suma al total de la recaudación y a la lista de quienes apoyan, y otorga la insignia de donante y los puntos. Una donación enviada por un Payment Link de Stripe directo esquiva BTCPay, y nada de eso le aplica.

### Donaciones

Desactivadas por defecto. Activa `btcpay_donations_enabled` y pon en `btcpay_pos_app_id` el id que aparece en la URL de tu app TPV (`/apps/<id>/pos`).

Cómo funciona: Discourse pide una factura a la app TPV enviando un order id que genera él mismo — `btcpay-donation:<user_id>:<nonce>`. BTCPay lo guarda en los metadatos de la factura, así que cuando llega `InvoiceSettled` la donación se atribuye al miembro correcto. **El order id nunca viene del navegador**, que es lo que impide que alguien acredite una donación a otra persona.

Endpoints para un theme component:

| Endpoint | Para qué |
|---|---|
| `POST /btcpay/donate` `{amount}` | Devuelve `{invoice_id, checkout_url, modal_url}`; con límite de tasa y sesión iniciada |
| `GET /btcpay/donations` | `{currency, total, count, supporters: [{username, avatar_template, amount, count}]}` para una barra de recaudación |

Se puede recompensar a quien dona:

- **Insignia** — elígela en Admin → Plugins → BTCPay; se concede con la primera donación liquidada.
- **Puntos** — pon en `btcpay_donation_points` los puntos por unidad donada. Necesita [discourse-gamification](https://github.com/discourse/discourse-gamification); si no está instalado, se ignora.

Las donaciones no conceden ningún grupo ni tocan las suscripciones.

### Membresía manual del grupo

Añadir a mano un usuario al grupo de un plan concede el acceso de inmediato — los grupos de Discourse son lo que protege el contenido, y el plugin nunca retira a un miembro del que no tiene registro. La reconciliación solo recorre sus propias suscripciones, así que a los miembros añadidos a mano no los toca nunca.

La contrapartida: la pestaña de facturación no le mostrará nada a ese usuario, porque no hay suscripción detrás. Usa la membresía manual para invitaciones y staff; usa un plan de BTCPay para todo lo que deba renovarse o caducar solo.

### Proxy inverso de BTCPay

Si el checkout acaba en `127.0.0.1` o `localhost`, BTCPay está generando los enlaces con el host que ve, no con el público. Dos cosas deben estar bien:

1. **BTCPay → Server Settings → Server URL** — ponlo como `https://btcpay.tudominio.com`. Es lo que BTCPay usa para redirecciones y enlaces de facturas.
2. **El proxy delante de BTCPay debe reenviar el host y el esquema originales.** Omitirlos es la causa habitual:

```nginx
location / {
    proxy_pass http://127.0.0.1:23000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
}
```

Si usas el docker-compose de BTCPay, define `BTCPAY_HOST` con el nombre público y deja que su nginx interno lo gestione — un segundo proxy por delante necesita las cabeceras de arriba.

Comprueba qué cree BTCPay, desde cualquier máquina:

```bash
curl -s -X POST https://btcpay.tudominio.com/api/v1/plan-checkout \
  -H "Authorization: token TU_API_KEY" -H "Content-Type: application/json" \
  -d '{"storeId":"STORE","offeringId":"OFFERING","planId":"PLAN"}' | grep -o '"url":"[^"]*"'
```

Si esa `url` contiene `127.0.0.1`, el problema está por completo en la configuración de BTCPay — Discourse solo lleva al pagador hasta allí.

## Actualizar, desactivar, desinstalar

**Actualizar:** `cd /var/discourse && ./launcher rebuild app` toma el último commit del plugin, igual que la instalación. No hay migraciones de base de datos ni ajustes o claves de almacenamiento renombrados, así que la actualización es en sitio y reversible volviendo a un commit anterior y reconstruyendo. Revisa [CHANGELOG.md](CHANGELOG.md) antes de actualizar.

**Desactivar:** apaga `btcpay_enabled`. El trabajo programado deja de actuar, los endpoints de webhook y checkout rechazan las peticiones y el JS no registra rutas ni enlaces. No se borra nada, y las membresías de grupo ya concedidas se mantienen — el acceso lo mandan los grupos de Discourse, no este plugin.

**Desinstalar:** quita el plugin de `app.yml` y reconstruye. **Los datos del plugin store se conservan a propósito** — suscripciones, historial de pagos e ids de cliente de BTCPay sobreviven a la desinstalación para no perder el historial de quienes ya pagaron. Para borrarlos deliberadamente:

```sql
DELETE FROM plugin_store_rows WHERE plugin_name = 'discourse-btcpay-subscriptions';
```

Los registros de un **usuario eliminado** se borran automáticamente cuando Discourse destruye la cuenta.

**Soporte:** abre una incidencia en https://github.com/criptonautas/discourse-btcpay-subscriptions/issues indicando las versiones de Discourse y BTCPay, las entradas relevantes de `/logs` (busca `DiscourseBtcpay`) y el registro de entregas del webhook en BTCPay.

## Resolución de problemas

**No llega el webhook:** revisa el registro de entregas en BTCPay y que la URL sea accesible.

**Fallos de HMAC:** comprueba que el secreto coincide exactamente en BTCPay y en Discourse, sin espacios.

**El usuario no entra al grupo:** mira `/logs` buscando `DiscourseBtcpay`. Verifica que el JSON de planes sea válido y que el grupo exista.

**La página de admin da 404:** la página de configuración está en **Admin → Plugins → BTCPay Subscriptions** (`/admin/plugins/discourse-btcpay-subscriptions`), no en `/admin/plugins/btcpay` — ese prefijo sirve solo los endpoints JSON del plugin. Un marcador antiguo a la ruta vieja dará 404.

**La página de admin dice "no está configurado del todo":** ahora enumera los ajustes que siguen vacíos. `btcpay_offering_id` es el que más se olvida — se añadió después de la primera versión. Si están todos rellenos y sigue quejándose, la página muestra el error de BTCPay: revisa `btcpay_server_url` y que la clave API tenga `canviewofferings`.

**El checkout sigue cayendo en localhost tras pulsar Subscribe:** corregido en el plugin — ahora Discourse continúa el checkout por su cuenta (`POST /api/v1/plan-checkout/{id}`) y lleva al pagador directo a la factura, sin pasar por la página Subscribe de BTCPay ni por su redirección. Si aun así ocurre, la URL de la factura se está construyendo mal: revisa **BTCPay → Server Settings → Server URL**.

**El checkout me lleva a localhost:** BTCPay construyó la URL con el host que cree tener. El plugin la reescribe hacia `btcpay_server_url` y deja un aviso en los logs, así que el pago funciona igualmente — pero corrige la causa en BTCPay:

- **BTCPay → Server Settings → Server URL** debe ser la URL pública HTTPS, no `localhost`.
- El proxy inverso delante de BTCPay debe reenviar el host y el esquema originales:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

Si lo que cae en localhost es el **retorno** tras pagar, entonces es el `DISCOURSE_HOSTNAME` (o `force_https`) de tu Discourse: ese enlace se construye con `Discourse.base_url`.

**Sincronización manual:** Admin → Plugins → BTCPay → botón "Sincronizar con BTCPay" (ignora el intervalo).

**Red equivocada:** la página de admin muestra la red que reporta BTCPay (mainnet / testnet) junto a la URL del servidor y la altura de la cadena. Se deduce de la punta de la cadena; "red desconocida" significa que BTCPay no devolvió estado de sincronización.

## Pruebas en testnet

Nada del plugin es específico de BTC: registra el método de pago que BTCPay indique como pagado, así que XMR, LTC, DOGE y Lightning funcionan igual. Testnet es simplemente un BTCPay corriendo sobre una cadena de prueba.

### 1. Consigue un BTCPay de testnet

Usa la demo pública (lo más rápido, sin instalación, se borra cada cierto tiempo):

- https://testnet.demo.btcpayserver.org — regístrate, crea una tienda y listo.

O levanta el tuyo en testnet/regtest:

```bash
git clone https://github.com/btcpayserver/btcpayserver-docker
cd btcpayserver-docker
export BTCPAY_HOST="btcpay.test.tudominio.com"
export NBITCOIN_NETWORK="testnet"          # o "regtest" para bloques instantáneos
export BTCPAYGEN_CRYPTO1="btc"
export BTCPAYGEN_CRYPTO2="xmr"             # añade más para probar multi-cripto
export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-s"
. ./btcpay-setup.sh -i
```

Sincronizar testnet tarda unas horas; regtest es instantáneo pero minas tú los bloques.

### 2. Configura la tienda

1. Tienda → Carteras → BTC → conecta una cartera con **tpub** (xpub de testnet) o deja que BTCPay genere una. Guarda la semilla.
2. Tienda → Suscripciones → crea una Oferta y un Plan con precio en **USD** (por ejemplo 10 USD/mes). Copia el Offering ID en `btcpay_offering_id` — los planes se obtienen automáticamente. BTCPay convierte de USD a cripto en el checkout con su proveedor de tasas — Discourse solo muestra la cifra en USD.
3. Cuenta → Claves API → crea una clave con `canviewofferings`, `canmanagesubscribers`, `canviewinvoices` y `canviewstoresettings`.

### 3. Apunta Discourse al servidor

Configura `btcpay_server_url` con el host de testnet, más la clave API, el store ID y las asignaciones de planes. **Admin → Plugins → BTCPay** muestra la etiqueta `TESTNET`, la versión de BTCPay, la altura de la cadena y los códigos de cripto que reporta el servidor — comprueba que diga testnet antes de seguir.

### 4. Haz alcanzables los webhooks

BTCPay tiene que llegar a tu Discourse por HTTPS. Para un Discourse local, haz un túnel:

```bash
cloudflared tunnel --url http://localhost:3000
# o: ngrok http 3000
```

Luego configura el host del túnel en Discourse y apunta el webhook de BTCPay a `https://<host-del-túnel>/btcpay/webhook` con los eventos `PlanStarted`, `SubscriberPhaseChanged`, `SubscriberDisabled`, `InvoiceProcessing`, `InvoiceReceivedPayment`, `InvoicePaymentSettled`, `InvoiceSettled`, `InvoiceExpired`, `InvoiceExpiredPaidPartial`, `InvoicePaidAfterExpiration`, `InvoiceInvalid`, `InvoiceRefund`.

### 5. Haz un pago

1. Abre `/tickets` en Discourse con un usuario normal (no admin).
2. Elige un plan → **Pagar en cripto** → se abre el modal de BTCPay sobre la página.
3. Paga desde una cartera de testnet. Monedas gratis:
   - BTC testnet3: https://coinfaucet.eu/en/btc-testnet/ o https://bitcoinfaucet.uo1.net
   - BTC signet: https://signetfaucet.com
   - LTC testnet: https://testnet-faucet.com/ltc-testnet
   - Monero stagenet: https://community.rino.io/faucet/stagenet/
   - regtest: `bitcoin-cli -regtest generatetoaddress 101 <dirección>` — sin faucet
4. Observa los estados: en cuanto la transacción entra en la mempool BTCPay dispara `InvoiceProcessing` → el plugin marca la suscripción como **pendiente** (aún sin grupo). Tras las confirmaciones `InvoiceSettled` registra el pago y `PlanStarted` concede el grupo; la página muestra "Pago recibido".

### 6. Verifica

```bash
# dentro del contenedor de Discourse
./launcher enter app
rails c
> DiscourseBtcpay.get_subscription(User.find_by(username: "tester").id)
> DiscourseBtcpay.get_payments(User.find_by(username: "tester").id)
```

El `payment_method` del pago es el que realmente lo liquidó (`BTC`, `XMR`, `BTC-LightningNetwork`…), no un BTC fijo.

Revisa también **BTCPay → Tienda → Webhooks → Entregas** buscando respuestas 200. Un 401 significa que el secreto no coincide; un 415, que se envió algo que no era `application/json`.

### 7. Prueba los caminos de fallo

| Escenario | Cómo provocarlo | Resultado esperado |
|---|---|---|
| Webhook perdido | Desactiva el webhook en BTCPay, paga y vuelve a activarlo | Admin → BTCPay → **Sincronizar con BTCPay** concede el grupo |
| Factura abandonada | Inicia un checkout y no pagues | Queda `pending` y pasa a `expired` con `InvoiceExpired` (o en 24 h por la reconciliación) |
| BTCPay caído | Detén el contenedor y pulsa Pagar | Mensaje de error en la página, sin escribir estado; la reconciliación reintenta la hora siguiente |
| Secreto incorrecto | Cambia `btcpay_webhook_secret` | 401 en el registro de entregas; tras 3 fallos, MP al admin |
| Reembolso | Marca una factura como inválida en BTCPay | Estado `disputed`, se mantiene el acceso, MP al admin |

## Desarrollo

Los tests se ejecutan en CI en cada push con el workflow oficial de plugins de Discourse (RuboCop, ESLint, Prettier, Stylelint, ember-template-lint y RSpec).

En local:

```bash
cd /var/discourse && ./launcher enter app
bundle exec rspec plugins/discourse-btcpay-subscriptions/spec

# Frontend (QUnit, necesita la app Ember construida)
bin/rake plugin:qunit['discourse-btcpay-subscriptions']
```

CI ejecuta ambos, contra `latest` y contra `stable`.

Linting del frontend (requiere Node 22+ y pnpm):

```bash
pnpm install && pnpm lint
```

## Traducciones

El plugin incluye inglés y español (`config/locales/{client,server}.{en,es}.yml`). Discourse elige el idioma según la preferencia de cada usuario.

## Licencia

MIT. Consulta [LICENSE](LICENSE).

Texto de este README bajo [CC BY-NC-SA 4.0](CC-BY-NC-SA-4.0.txt).
