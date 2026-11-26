#!/usr/bin/env bash
# Regression: the yaml the bot was started with (--yaml, possibly outside the script
# directory, as in the shipped docker-compose example) must stay addressable from chat and
# from buttons; other yaml files keep the "plain name in the script directory" rule.
# Usage: bash tests/regress/bot-yaml-location.sh   (T_PGSQL_BIN overrides the script under test)
. "$(dirname "${BASH_SOURCE[0]}")/bot-lib.sh"

mkdir -p "$TMP/data" "$TMP/other"
write_jobs_yaml "$TMP/data/team.yaml"
write_jobs_yaml "$TMP/other/x.yaml"

# 1. Bot started with an absolute yaml path outside the script directory.
YAML_ARG="$TMP/data/team.yaml"
run_bot "$(msg 1 111 $CHAT '/backup team nightly'),$(msg 2 111 $CHAT '/backup team.yaml nightly'),$(msg 3 111 $CHAT "/backup $TMP/data/team.yaml nightly"),$(cb 4 111 $CHAT 'backup:nightly'),$(cb 5 111 $CHAT 'backup:team.yaml:nightly')"
[ "$(started)" = 5 ] && ok "own yaml reachable by base name, name without .yaml, exact path, and both callback forms" || nok "own yaml outside the script dir: only $(started) of 5 requests started"

# 2. Other yaml files outside the script directory are still refused; a plain name in the
#    script directory still works.
run_bot "$(msg 6 111 $CHAT "/backup $TMP/other/x.yaml nightly"),$(msg 7 111 $CHAT '/backup ../other/x nightly'),$(msg 8 111 $CHAT '/backup jobs nightly')"
[ "$(started)" = 1 ] && ok "other paths refused, plain name in the script dir accepted" || nok "expected exactly 1 started job, got $(started)"

# 3. Default layout (yaml in the script directory).
YAML_ARG=jobs
run_bot "$(msg 9 111 $CHAT '/backup jobs nightly'),$(msg 10 111 $CHAT '/backup jobs.yaml nightly'),$(msg 11 111 $CHAT "/backup $TMP/other/x.yaml nightly"),$(cb 12 111 $CHAT 'backup:nightly')"
[ "$(started)" = 3 ] && ok "default layout: names and short callback work, foreign path refused" || nok "default layout: expected 3 started jobs, got $(started)"

exit $fail
