# Sourced in the selected Bash shell. Placeholders are replaced per job.
if [ "$$" != '__EXPECTED_PID__' ]; then
  printf 'Shell identity changed; reattach before running commands.\n' > __DIR__/stderr
  printf '125\n' > __DIR__/done.tmp
  command mv -- __DIR__/done.tmp __DIR__/done
  return 125
fi

# Capture distinct streams while showing both in the user's terminal.
# Job-specific names avoid overwriting ordinary shell variables.
exec {__VAR___out_fd}> >(command tee -- __DIR__/stdout)
__VAR___out_pid=$!
exec {__VAR___err_fd}> >(command tee -- __DIR__/stderr >&2)
__VAR___err_pid=$!
builtin source __DIR__/command.sh </dev/null >&$__VAR___out_fd 2>&$__VAR___err_fd
__VAR___rc=$?
exec {__VAR___out_fd}>&-
exec {__VAR___err_fd}>&-
wait "$__VAR___out_pid"
wait "$__VAR___err_pid"
printf '%s' "$PWD" > __DIR__/cwd
printf '%s\n' "$__VAR___rc" > __DIR__/done.tmp
command mv -- __DIR__/done.tmp __DIR__/done
unset __VAR___out_fd __VAR___err_fd __VAR___out_pid __VAR___err_pid __VAR___rc
