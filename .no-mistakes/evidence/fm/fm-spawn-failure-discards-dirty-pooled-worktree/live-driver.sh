#!/bin/bash
set -eu
ROOT=$PWD
E=/home/bd/.no-mistakes/evidence/01M4QT2HGXQTAS0N0MC48HMJWE
D=$ROOT/.test-tmp/live
mkdir -p "$D"
SOCK=$ROOT/.test-tmp/s
trap 'tmux -S "$SOCK" kill-server 2>/dev/null || true; rm -rf "$D"' EXIT
for mode in dirty clean; do
 H=$D/$mode/home
 P=$D/$mode/project
 bin/fm-lab-home.sh create "$H"
 mkdir -p "$P" "$H/data/live-$mode"
 printf 'codex\n' > "$H/config/crew-harness"
 printf '# Task\n## Captain\x27s intent\nTest abort preservation.\n## Firstmate spec\nExercise spawn.\n' > "$H/data/live-$mode/brief.md"
 git init -q -b main "$P"
 printf 'base\n' > "$P/file"
 printf 'root = "."\nmax_trees = 1\n' > "$P/treehouse.toml"
 git -C "$P" add .
 git -C "$P" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
 cat > "$D/$mode/shell" <<EOF
#!/bin/bash
if [[ \$PWD == *'/.treehouse/'* ]]; then
 if [ '$mode' = dirty ]; then
   printf 'staged survives\\n' > file
   git add file
   printf 'unstaged survives\\n' >> file
   printf 'untracked survives\\n' > untracked
 else
   git remote add origin 'file://$D/missing.git'
 fi
 printf '%s\\n' "\$PWD" > '$D/$mode/acquired'
fi
exec /bin/bash --noprofile --norc
EOF
 chmod +x "$D/$mode/shell"
 tmux -S "$SOCK" new-session -d -s "lab-$mode" -x 120 -y 40 -c "$ROOT" /bin/bash
 tmux -S "$SOCK" set-option -g default-command "env SHELL=$D/$mode/shell /bin/bash --noprofile --norc"
 T=$(tmux -S "$SOCK" display-message -p -t "lab-$mode" '#{socket_path},#{pid},0')
 set +e
 env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$H" TMUX="$T" FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh "live-$mode" "$P" --scout --backend tmux > "$E/live-$mode.log" 2>&1
 RC=$?
 set -e
 printf 'spawn exit=%s\n' "$RC" >> "$E/live-$mode.log"
 if [ -f "$D/$mode/acquired" ]; then
  W=$(cat "$D/$mode/acquired")
  { printf 'acquired=%s\n' "$W"; git -C "$W" status --short; if [ "$mode" = dirty ]; then cat "$W/file" "$W/untracked"; fi; (cd "$P"; treehouse status); } >> "$E/live-$mode.log" 2>&1
 fi
 cat "$E/live-$mode.log"
 tmux -S "$SOCK" kill-server
 done
