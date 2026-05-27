#!/bin/sh
# Claude Code statusLine script
# Shows: current directory, git branch, model name, context usage

input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Shorten home directory to ~
home="$HOME"
if [ -n "$home" ] && [ -n "$cwd" ]; then
  short_cwd=$(echo "$cwd" | sed "s|^$home|~|")
else
  short_cwd="$cwd"
fi

# Get git branch (skip optional locks)
branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null)
fi

# Build output parts
dir_part=""
[ -n "$short_cwd" ] && dir_part="$short_cwd"

branch_part=""
[ -n "$branch" ] && branch_part="[$branch]"

model_part=""
[ -n "$model" ] && model_part="$model"

ctx_part=""
if [ -n "$used_pct" ]; then
  ctx_part=$(printf "ctx:%.0f%%" "$used_pct")
fi

# Assemble line with separators
line=""
for part in "$dir_part" "$branch_part" "$model_part" "$ctx_part"; do
  if [ -n "$part" ]; then
    if [ -n "$line" ]; then
      line="$line | $part"
    else
      line="$part"
    fi
  fi
done

printf '%s\n' "$line"
