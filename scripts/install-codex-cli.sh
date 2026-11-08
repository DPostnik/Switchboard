#!/bin/zsh
# Install Switchboard's verified native CLI independently of ChatGPT desktop updates.
set -euo pipefail
version=0.160.0
case "$(uname -m)" in
  arm64) arch=arm64; triple=aarch64-apple-darwin ;;
  x86_64) arch=x64; triple=x86_64-apple-darwin ;;
  *) exit 1 ;;
esac
root="${SWITCHBOARD_DATA_ROOT:-$HOME/Library/Application Support/Switchboard}/agents/codex"
npm install --prefix "$root/$version" --ignore-scripts --no-audit --no-fund --save-exact \
  --registry https://registry.npmjs.org "@openai/codex@$version-darwin-$arch"
bin="$version/node_modules/@openai/codex/vendor/$triple/bin"
[[ "$(CODEX_HOME="$root" "$root/$bin/codex" --version)" == "codex-cli $version" ]]
# Never replace an actual directory at this location.
[[ ! -e "$root/bin" || -L "$root/bin" ]]
ln -sfn "$bin" "$root/bin"
