#!/usr/bin/env bash
# Prints the Claude Code connector's readEnvironment function for the given variable names, exactly as the app
# writes it when it installs the connector (ClaudeConnectorFiles.environmentReader, which a Swift test compares
# against this script). Claude Code requires each $.env.get to name its variable literally.
set -euo pipefail

keys=()
for key in "$@"; do
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && keys+=("$key")
done

printf 'async function readEnvironment($) {\n'
list=""
for key in ${keys[@]+"${keys[@]}"}; do list+="${list:+, }\"$key\""; done
printf '  const keys = [%s]\n' "$list"
printf '  try {\n'
printf '    const reads = await Promise.all([\n'
for key in ${keys[@]+"${keys[@]}"}; do printf '      $.env.get("%s").catch(() => undefined),\n' "$key"; done
printf '    ])\n'
printf '    return Object.fromEntries(keys.map((key, index) => [key, reads[index]]))\n'
printf '  } catch (err) {\n'
printf '    return {}\n'
printf '  }\n'
printf '}\n'
