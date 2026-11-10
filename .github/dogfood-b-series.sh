#!/usr/bin/env bash
# Temporary: runs DOGFOODING.md B1-B6 on a GitHub runner (16 GB RAM), because the
# basecamp 0.3.0 flake does not evaluate on a small dogfooding container and the
# logos binary cache is unreachable. Not for merge.
set -uo pipefail
LGS="$GITHUB_WORKSPACE/target/release/logos-scaffold"
OUT="$RUNNER_TEMP/b-out"; mkdir -p "$OUT"
M="$RUNNER_TEMP/modproj"
step() { echo; echo "################ $*"; }
run() { echo "\$ $*"; "$@"; local rc=$?; echo "exit=$rc"; return 0; }

step "module project from logos-module-builder 0.3.0 templates"
git clone -q --depth 1 --branch 0.3.0 https://github.com/logos-co/logos-module-builder "$RUNNER_TEMP/lmb"
mkdir -p "$M"; cp -r "$RUNNER_TEMP/lmb/templates/minimal-module" "$M/minimal"; cp -r "$RUNNER_TEMP/lmb/templates/ui-qml" "$M/ui"
cd "$M"
sed -i 's#github:logos-co/logos-module-builder"#github:logos-co/logos-module-builder/0.3.0"#' minimal/flake.nix ui/flake.nix
sed -i 's#logos-module-builder/0.3.0";#logos-module-builder/0.3.0";\n    minimal.url = "path:../minimal";#' ui/flake.nix
jq '.name="minimal_ui" | .dependencies=["minimal"]' ui/metadata.json > ui/m && mv ui/m ui/metadata.json
rm -f minimal/flake.lock ui/flake.lock
git init -q && git add -A && git -c user.email=ci@ci -c user.name=ci commit -qm modproj
cat ui/flake.nix

step "B1"
run "$LGS" init
git add -A && git -c user.email=ci@ci -c user.name=ci commit -qm init
run "$LGS" basecamp --help
"$LGS" basecamp docs | head
grep -n '^\[repos.basecamp.attr\]\|^\[basecamp.profiles' scaffold.toml || true
free -g
step "B1 basecamp setup #1"
/usr/bin/time -v "$LGS" basecamp setup 2>&1 | tail -40; echo "exit=${PIPESTATUS[0]}"
cp -r .scaffold/logs "$OUT/setup-logs" || true
run ls .scaffold/basecamp/profiles
run "$LGS" basecamp doctor
"$LGS" basecamp doctor --json | tee "$OUT/doctor1.json"; echo
step "B1 basecamp setup #2 (idempotent)"
time "$LGS" basecamp setup 2>&1 | tail -15
APP=$(readlink -f "$(find "$HOME/.cache/logos-scaffold/basecamp" -maxdepth 2 -name app-result | head -1)")
echo "APP=$APP"; ls "$APP" "$APP/bin"; ls -a "$APP/bin"; ls "$APP/modules" "$APP/plugins" 2>&1
step "B1 retired pin move-forward"
cp scaffold.toml /tmp/st.bak
sed -i '/^\[repos.basecamp\]/,/^\[/ s/^pin = .*/pin = "aa237766baf61404e12da86b7303cb41065464c9"/' scaffold.toml
sed -i '/^\[repos.lgpm\]/,/^\[/ s/^pin = .*/pin = "202af6fa0f0f4493bc59c8a609dff9326f78a18d"/' scaffold.toml
"$LGS" basecamp doctor | grep -i 'pin'
cp /tmp/st.bak scaffold.toml
step "B1 lgpm-only pin edit guard"
sed -i '/^\[repos.lgpm\]/,/^\[/ s/^pin = .*/pin = "202af6fa0f0f4493bc59c8a609dff9326f78a18d"/' scaffold.toml
run "$LGS" basecamp install
"$LGS" basecamp doctor | grep -i 'pin'
cp /tmp/st.bak scaffold.toml

step "B2 modules"
run "$LGS" basecamp modules
grep -n -A4 '^\[modules\.' scaffold.toml
cp scaffold.toml /tmp/after-modules.toml
run "$LGS" basecamp modules
diff /tmp/after-modules.toml scaffold.toml && echo "modules re-run byte-identical"
run "$LGS" basecamp modules --show
step "B2 install"
run "$LGS" basecamp install
ls .scaffold/logs/
run "$LGS" basecamp install --print-output 2>&1 | tail -20
run "$LGS" basecamp doctor
run "$LGS" basecamp paths alice
"$LGS" basecamp paths alice --json | tee "$OUT/paths-alice.json"; echo
cat >> scaffold.toml <<'EOF'

[basecamp.profiles.maker]
env_file = ".scaffold/basecamp/maker.env"
runtime_dir = "/tmp/lgs-maker"
log_file = ".scaffold/basecamp/profiles/maker/basecamp.log"

[basecamp.profiles.maker.env]
LOGOS_PROFILE_ROLE = "maker"
EOF
printf 'MAKER_ONLY=1\nLOGOS_PROFILE_ROLE=env-file\n' > .scaffold/basecamp/maker.env
"$LGS" basecamp paths maker --json | tee "$OUT/paths-maker.json"; echo

step "B2/B3 launch alice + bob on Xvfb"
Xvfb :99 -screen 0 1600x1000x24 & sleep 3; export DISPLAY=:99 QT_QPA_PLATFORM=xcb
xdpyinfo | head -2
timeout 150 "$LGS" basecamp launch alice > "$OUT/launch-alice.log" 2>&1 &
sleep 45
timeout 120 "$LGS" basecamp launch bob > "$OUT/launch-bob.log" 2>&1 &
sleep 45
head -30 "$OUT/launch-alice.log"; echo ...; head -15 "$OUT/launch-bob.log"
for p in alice bob; do
  echo "== $p launch.state"; cat .scaffold/basecamp/profiles/$p/launch.state
  pid=$(sed -n 's/^pid=//p' .scaffold/basecamp/profiles/$p/launch.state)
  kill -0 "$pid" && echo "$p running pid=$pid"
  tr '\0' '\n' < /proc/$pid/environ | grep -E 'XDG_|LOGOS_|^HOME=|TMPDIR' | sort
  ls .scaffold/basecamp/profiles/$p/
done
pgrep -fl LogosBasecamp; pgrep -a logos_host | cut -c1-150 | head
import -window root "$OUT/alice-bob.png" || true
echo "== sockets in project tree"; find .scaffold -type s | head
echo "== global Logos dirs touched?"; ls -la ~/.local/share/Logos 2>&1 | head -3

step "B4 clean-slate relaunch"
mkdir -p .scaffold/basecamp/profiles/alice/xdg-data/scratch
echo "marker-$(date -u +%s)" > .scaffold/basecamp/profiles/alice/xdg-data/scratch/marker.txt
echo "before:"; pgrep -l -f 'LogosBasecamp' ; OLD=$(sed -n 's/^pid=//p' .scaffold/basecamp/profiles/alice/launch.state)
timeout 90 "$LGS" basecamp launch alice > "$OUT/launch-alice-2.log" 2>&1 &
sleep 45
head -20 "$OUT/launch-alice-2.log"
test -e .scaffold/basecamp/profiles/alice/xdg-data/scratch/marker.txt && echo "REGRESSION: marker survived clean launch" || echo "OK: marker scrubbed"
kill -0 "$OLD" 2>/dev/null && echo "REGRESSION: old alice pid $OLD still alive" || echo "OK: old alice pid $OLD gone"
echo "after:"; pgrep -l -f 'LogosBasecamp'
run "$LGS" basecamp paths ../escape
run "$LGS" basecamp launch ../escape
step "B4 custom profile launch with --log-file"
timeout 60 "$LGS" basecamp launch maker --log-file "$RUNNER_TEMP/maker-override.log" > "$OUT/launch-maker.log" 2>&1 &
sleep 40
head -12 "$OUT/launch-maker.log"; ls -la "$RUNNER_TEMP/maker-override.log" /tmp/lgs-maker 2>&1 | head
mp=$(sed -n 's/^pid=//p' .scaffold/basecamp/profiles/maker/launch.state)
tr '\0' '\n' < /proc/$mp/environ 2>/dev/null | grep -E 'MAKER_ONLY|LOGOS_PROFILE_ROLE|TMPDIR|XDG_RUNTIME' | sort
sleep 30; pkill -f LogosBasecamp; pkill logos_host; sleep 3

step "B5 builds"
run "$LGS" basecamp build --variant all
run "$LGS" basecamp build --variant lgx --module minimal
run "$LGS" basecamp build --variant lgx-portable --module minimal_ui
run "$LGS" basecamp build --variant lgx --module nonexistent
run "$LGS" basecamp build-portable
find .scaffold/basecamp -maxdepth 3 \( -type f -o -type l \) | grep -v profiles | sort

step "B6 run"
timeout 90 "$LGS" basecamp run minimal_ui --host standalone > "$OUT/run-standalone.log" 2>&1; echo "exit=$?"
tail -25 "$OUT/run-standalone.log"
timeout 60 "$LGS" basecamp run minimal_ui > "$OUT/run-default.log" 2>&1; echo "exit=$?"; tail -8 "$OUT/run-default.log"
LGX=$(find .scaffold/basecamp -name '*.lgx' | head -1); echo "LGX=$LGX"
cp scaffold.toml /tmp/b6.bak
cp "$LGX" "$RUNNER_TEMP/prebuilt.lgx"
run "$LGS" basecamp modules --path "$RUNNER_TEMP/prebuilt.lgx"
diff /tmp/b6.bak scaffold.toml
PNAME=$(diff /tmp/b6.bak scaffold.toml | sed -n 's/^> \[modules\.\(.*\)\]$/\1/p' | head -1); echo "PNAME=$PNAME"
run "$LGS" basecamp run "${PNAME:-minimal}"
cp /tmp/b6.bak scaffold.toml
grep -n 'standalone_app' scaffold.toml || echo "no standalone_app key serialized"
echo "B-SERIES SCRIPT DONE"
