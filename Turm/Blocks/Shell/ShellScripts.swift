import Foundation

enum ShellScripts {
    static let bash = #"""
        _turm_file=$TURM_CMD_FILE
        unset TURM_CMD_FILE
        _turm_home=$HOME
        if [ -r /etc/profile ]; then . /etc/profile; fi
        for _turm_f in "$_turm_home/.bash_profile" "$_turm_home/.bash_login" "$_turm_home/.profile" "$_turm_home/.bashrc"; do
          if [ -r "$_turm_f" ]; then . "$_turm_f"; break; fi
        done
        unset _turm_f _turm_home

        _turm_report_env() {
          local now encoded
          now=$(unset PWD OLDPWD _ SHLVL; export -p)
          if [[ -n $_turm_env_sent && $now == "$_turm_env_sent" ]]; then
            return
          fi
          _turm_env_sent=$now
          encoded=$(command env -0 | command base64)
          encoded=${encoded//[$'\n\r']/}
          if (( ${#encoded} > 0 && ${#encoded} <= 262144 )); then
            printf '\e]7777;E;%s\a' "$encoded"
          fi
        }
        _turm_prompt() {
          local code=$?
          if [[ -n $_turm_ran ]]; then
            if [[ -r $_turm_file ]]; then
              local last=$(HISTTIMEFORMAT= builtin history 1)
              if [[ $last == *"$_turm_file"* ]]; then
                builtin history -s "$(<"$_turm_file")"
              fi
              command rm -f "$_turm_file"
            fi
            _turm_report_env
            printf '\e]7777;P;%d;%s\a' "$code" "$PWD"
          else
            _turm_report_env
            printf '\e]7777;P;;%s\a' "$PWD"
          fi
          _turm_ran=
          return $code
        }
        _turm_quiet() {
          PS1=''
          PS2=''
        }
        _turm_arm() {
          _turm_quiet
          _turm_armed=1
        }
        _turm_debug() {
          if [[ -n $_turm_armed ]]; then
            _turm_armed=
            _turm_ran=1
            printf '\e]7777;C\a'
          fi
        }

        _turm_old=$(trap -p DEBUG)
        if [[ -n $_turm_old ]]; then
          eval "_turm_words=($_turm_old)"
          trap "_turm_debug; ${_turm_words[2]}" DEBUG
          unset _turm_words
        else
          trap '_turm_debug' DEBUG
        fi
        unset _turm_old

        if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
          PROMPT_COMMAND=(_turm_prompt "${PROMPT_COMMAND[@]}" _turm_arm)
        else
          PROMPT_COMMAND=$'_turm_prompt\n'"$PROMPT_COMMAND"$'\n_turm_arm'
        fi
        _turm_quiet
        """#

    static let fish = #"""
        function fish_prompt
        end
        function fish_right_prompt
        end
        function fish_mode_prompt
        end
        set -g fish_greeting
        set -g _turm_pending 1

        function _turm_preexec --on-event fish_preexec
            set -g _turm_ran 1
            printf '\e]7777;C\a'
        end

        function _turm_report_env
            set -l now (set -x | string match -rv '^(PWD|OLDPWD|_|SHLVL) ' | string collect)
            if set -q _turm_env_sent; and test "$now" = "$_turm_env_sent"
                return
            end
            set -g _turm_env_sent "$now"
            set -l encoded (command env -0 | command base64 | string join '')
            set -l size (string length -- "$encoded")
            if test $size -gt 0; and test $size -le 262144
                printf '\e]7777;E;%s\a' "$encoded"
            end
        end

        function _turm_prompt --on-event fish_prompt
            set -l code $status
            if set -q _turm_ran
                _turm_report_env
                printf '\e]7777;P;%d;%s\a' $code $PWD
                set -e _turm_ran
            else if set -q _turm_pending
                _turm_report_env
                printf '\e]7777;P;;%s\a' $PWD
            end
            set -e _turm_pending
        end
        """#
}
