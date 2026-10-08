#!/usr/bin/env bash
# Regenerates priv/tailwind_data.etf and the test fixtures for the tailwindcss version in package.json.
set -euo pipefail
cd "$(dirname "$0")"
npm install --silent
version=$(node -p "require('./node_modules/tailwindcss/package.json').version")
mkdir -p src
for f in property-order.ts utilities.ts theme.ts utils/is-color.ts; do
  curl -sfL "https://raw.githubusercontent.com/tailwindlabs/tailwindcss/v${version}/packages/tailwindcss/src/$f" -o "src/$(basename "$f")"
done
node --max-old-space-size=6000 extract.mjs src /tmp/tailwind_data.term
elixir pack_data.exs /tmp/tailwind_data.term ../priv/tailwind_data.etf
fx=../test/fixtures
node fixtures.mjs $fx/default.css 4000 1 $fx/fx_default.term
node fixtures.mjs $fx/custom.css 2000 7 $fx/fx_custom.term
node fixtures.mjs $fx/prefix.css 1000 3 $fx/fx_prefix.term
node fixtures.mjs $fx/reset.css 5000 11 $fx/fx_reset.term
echo "regenerated for tailwindcss $version. Now run: mix test"
