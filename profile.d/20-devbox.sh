# /etc/profile.d/20-devbox.sh — login-shell defaults for the dev box.
# User-installed tools go on the volume and take precedence over the image's
# pinned copies: ~/.local/bin (Claude Code's native installer, pipx, uv) and
# ~/.npm-global/bin (npm install -g without sudo).
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH" ;;
esac
export PATH
