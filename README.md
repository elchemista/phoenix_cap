# PhoenixCap

Tiny Phoenix-native verifier for the Cap widget.

I built this because I was tired of wiring the same reCAPTCHA-style flow into
Phoenix apps. Cap has a lovely widget and proof-of-work protocol, but for small
Phoenix projects I did not want to host the full standalone Cap service just to
protect a form. PhoenixCap keeps that path tiny: use the Cap frontend, verify it
inside Phoenix.

PhoenixCap gives you one endpoint plug and one verifier:

```elixir
# router.ex
forward "/cap", PhoenixCap.Plug
```

```elixir
# controller or LiveView action
with :ok <- PhoenixCap.verify(conn, params["cap-token"]) do
  # allow the action
else
  _ -> {:error, :captcha_failed}
end
```

No dashboard, site keys, stats, Redis, Docker, admin UI, Phoenix dependency, or
JSON dependency. Challenges and one-time verification tokens are stored in ETS.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `phoenix_cap` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_cap, "~> 0.1.0"}
  ]
end
```

## Widget

The upstream Cap widget files are included in this package under `assets/`, so
a Phoenix app can import the widget from its app asset bundle:

```js
import "../../deps/phoenix_cap/assets/cap.min.js";
```

Then point the widget at your forwarded Phoenix route:

```html
<cap-widget data-cap-api-endpoint="/cap/"></cap-widget>
```

When the widget is inside a form it injects a hidden `cap-token` input by
default.

PhoenixCap also vendors Cap's browser WASM package under `assets/wasm/`. If you
want the widget to load the bundled WASM instead of jsDelivr, copy the WASM file
into your Phoenix static assets and configure the URL before loading the widget:

```html
<script>
  window.CAP_CUSTOM_WASM_URL = "/cap_wasm_bg.wasm";
</script>
```

## Updating Cap Assets

To update the bundled widget and WASM files to the latest npm releases:

```bash
mix phoenix_cap.update_assets
```

To pin exact versions:

```bash
mix phoenix_cap.update_assets --widget 0.1.50 --wasm 0.0.7
```

The task writes `assets/VERSIONS` so releases can show exactly which Cap assets
are bundled.

## Config

PhoenixCap keeps JSON and token signing in your app. Configure the JSON library
you already use and a token module with the same API shape as `Phoenix.Token`:

```elixir
config :phoenix_cap,
  json_library: Jason,
  token_module: Phoenix.Token,
  token_salt: "phoenix-cap-token"
```

For `PhoenixCap.verify(conn, token)`, PhoenixCap uses
`conn.private[:phoenix_endpoint]` as the token context when available, so
`Phoenix.Token` works naturally inside Phoenix.

If you want `PhoenixCap.verify(token)` without passing a connection, configure
the token context explicitly:

```elixir
config :phoenix_cap,
  token_context: MyAppWeb.Endpoint
```

`token_salt` defaults to `"phoenix-cap-token"`. Changing it invalidates any
Cap verification tokens that have already been issued but not yet verified.

Custom token modules implement the same function shape:

```elixir
defmodule MyApp.CapToken do
  @behaviour PhoenixCap.Token

  def sign(context, salt, payload) do
    # return token string
  end

  def verify(context, salt, token, opts) do
    # return {:ok, payload} or {:error, reason}
  end
end
```

## Credits And License

PhoenixCap is released under the MIT License.

Huge thanks to Tiago and all contributors to the Cap project. This library only
exists because Cap already did the hard, thoughtful work: the widget, the
proof-of-work protocol, the solver, and the clean self-hosted CAPTCHA idea.
PhoenixCap is a small Phoenix-side adapter around that work, not a replacement
for it.

The bundled frontend widget files in `assets/` come from `@cap.js/widget`.
Cap is licensed under Apache-2.0; its license is included at
`assets/CAP_WIDGET_LICENSE`.
