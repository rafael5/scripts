#!/usr/bin/env bash
# Build + install the maintained ueberzugpp from source into ~/.local, and add
# a `ueberzug` shim so apt ranger 1.9.3 (which calls the command `ueberzug`)
# uses it. Local X11 Cinnamon desktop. Re-runnable. Run from a real terminal:
# network + sudo are required and are blocked inside Claude's sandbox.
set -euo pipefail

PREFIX="$HOME/.local"
SRC="$HOME/src/ueberzugpp"

echo "==> 1/4  apt build dependencies (needs sudo)"
# README deps (openssl, libvips, libsixel, chafa, tbb) + build basics + the
# X11 xcb headers the X11 canvas backend links against.
sudo apt-get update
sudo apt-get install -y \
  cmake build-essential git pkg-config \
  libssl-dev libvips-dev libsixel-dev libchafa-dev libtbb-dev \
  libxcb1-dev libxcb-image0-dev libxcb-res0-dev libxcb-shm0-dev

echo "==> 2/4  clone + build"
rm -rf "$SRC"
git clone --depth 1 https://github.com/jstkdng/ueberzugpp.git "$SRC"
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$SRC/build" -j"$(nproc)"

echo "==> 3/4  install into $PREFIX (no sudo)"
cmake --install "$SRC/build"

echo "==> 4/4  ueberzug shim for ranger 1.9.3"
# Only create the shim if `ueberzug` doesn't already resolve to ueberzugpp.
if ! command -v ueberzug >/dev/null 2>&1 || \
   ! readlink -f "$(command -v ueberzug)" | grep -qi ueberzugpp; then
  cat > "$PREFIX/bin/ueberzug" <<'SHIM'
#!/usr/bin/env bash
# Compat shim: ranger 1.9.3 invokes `ueberzug layer --silent`; hand it to the
# maintained ueberzugpp, which implements the legacy layer protocol.
exec ueberzugpp "$@"
SHIM
  chmod +x "$PREFIX/bin/ueberzug"
fi

hash -r
echo
echo "==> done. resolution check:"
echo "  ueberzugpp -> $(command -v ueberzugpp)"
echo "  ueberzug   -> $(command -v ueberzug)  (should be $PREFIX/bin, NOT /usr/bin)"
"$PREFIX/bin/ueberzugpp" --help >/dev/null 2>&1 \
  && echo "  ueberzugpp runs OK" \
  || echo "  NOTE: 'ueberzugpp --help' returned nonzero; check the build output above."
