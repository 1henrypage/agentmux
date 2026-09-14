# agentmux hook merge. Input: a settings document (Claude settings.json or Codex hooks.json).
# Args: $tpl (template document), $hook (path replacing __HOOK__), $mode (install|uninstall),
#       $legacy ("1" also treats claude-tmux-state.sh entries as ours).
# Semantics: strip our entries from every event array, drop groups/arrays left empty, on
# install append the template's groups, delete .hooks when empty. Everything else untouched.

def ours:
  ((.command // "") | test("agentmux-hook"))
  or ($legacy == "1" and ((.command // "") | test("claude-tmux-state\\.sh")));

def strip_ours:
  if (.hooks | type) == "object" then
    .hooks |= (
      with_entries(
        .value |= (
          if type == "array" then
            map(if (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end)
            | map(select((.hooks | type) != "array" or (.hooks | length) > 0))
          else . end
        )
      )
      | with_entries(select((.value | type) != "array" or (.value | length) > 0))
    )
  else . end;

# .hooks stays in place (possibly empty) until the end so key order is preserved on install.
def prune:
  if (.hooks | type) == "object" and (.hooks | length) == 0 then del(.hooks) else . end;

def template:
  $tpl.hooks
  | with_entries(.value |= map(.hooks |= map(.command |= sub("__HOOK__"; $hook))));

def add_ours:
  reduce (template | to_entries[]) as $e (.; .hooks[$e.key] += $e.value);

strip_ours | if $mode == "install" then add_ours else . end | prune
