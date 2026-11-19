import Foundation

public nonisolated enum ShellScripts {
    public static let bash = #"""
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
        _turm_drain() {
          [[ -t 0 ]] || return
          if (( BASH_VERSINFO[0] >= 4 )); then
            local junk
            while IFS= read -r -s -n 1 -t 0.001 junk; do :; done
          else
            local saved
            saved=$(command stty -g 2>/dev/null) || return
            command stty -icanon -echo min 0 time 0 2>/dev/null
            command dd bs=65536 count=1 >/dev/null 2>&1
            command stty "$saved" 2>/dev/null
          fi
        }
        _turm_emit() {
          # keys sent to a program that exited before reading them would land in the next command line
          _turm_drain
          if [[ -n $TURM_REMOTE ]]; then
            printf '\e]7777;R;%s;%s;%s\a' "$TURM_REMOTE" "$1" "$PWD"
          else
            printf '\e]7777;P;%s;%s\a' "$1" "$PWD"
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
              { command rm -f "$_turm_file"; } 2>/dev/null
            fi
            _turm_report_env
            _turm_emit "$code"
          else
            _turm_report_env
            _turm_emit ''
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
        if [[ -n $TURM_SSH_WRAPPER ]] && ! declare -F ssh >/dev/null && ! alias ssh >/dev/null 2>&1; then
          ssh() { "$TURM_SSH_WRAPPER" "$@"; }
        fi
        if [[ -n $TURM_REMOTE ]]; then
          _turm_kind=bash-legacy
          if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
            bind 'set enable-bracketed-paste on' 2>/dev/null && _turm_kind=bash
          fi
          printf '\e]7777;H;%s;%s;%s@%s\a' "$TURM_REMOTE" "$_turm_kind" "${USER:-$(id -un)}" "${HOSTNAME:-$(hostname)}"
          unset _turm_kind
        fi
        _turm_quiet
        """#

    public static let fish = #"""
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
                _turm_emit $code
                set -e _turm_ran
            else if set -q _turm_pending
                _turm_report_env
                _turm_emit ''
            end
            set -e _turm_pending
        end

        function _turm_emit
            if set -q TURM_REMOTE
                printf '\e]7777;R;%s;%s;%s\a' $TURM_REMOTE $argv[1] $PWD
            else
                printf '\e]7777;P;%s;%s\a' $argv[1] $PWD
            end
        end

        if set -q TURM_SSH_WRAPPER; and not functions -q ssh
            function ssh --wraps ssh
                $TURM_SSH_WRAPPER $argv
            end
        end
        if set -q TURM_REMOTE
            printf '\e]7777;H;%s;fish;%s@%s\a' $TURM_REMOTE (id -un) (hostname)
        end
        """#

    /// Sourced instead of the prompt hooks by the hidden zsh that answers completion requests.
    public static let zshCompletion = #"""
# Turm completion helper: runs the user's own completion system for one request at a time and prints the offers.
zmodload zsh/zutil
unsetopt beep
PROMPT='' RPROMPT='' PS2='' PROMPT_EOL_MARK=''
precmd_functions=() preexec_functions=() chpwd_functions=()
unset HISTFILE
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -C -d "${TURM_COMPLETION_DUMP:-${TMPDIR:-/tmp}/turm-zcompdump}" }

# compadd options that take a value, either joined to the letter or as the next word
typeset -g _turm_valued=PpSsiIWdJVXxrRMFOADE

compadd() {
  setopt localoptions extendedglob
  local -A opts
  local flags= word letters letter value
  local -i index=1
  while (( index <= $# )); do
    word=${@[index]}
    [[ $word == -- ]] && break
    [[ $word == -?* ]] || break
    letters=${word#-}
    while [[ -n $letters ]]; do
      letter=${letters[1]}
      letters=${letters[2,-1]}
      if [[ $_turm_valued == *$letter* ]]; then
        if [[ -n $letters ]]; then
          value=$letters
        else
          (( index++ ))
          value=${@[index]}
        fi
        opts[$letter]=$value
        letters=
      else
        flags+=$letter
      fi
    done
    (( index++ ))
  done
  # calls that only fill arrays or test matching are not offers
  if (( ${+opts[O]} || ${+opts[A]} || ${+opts[D]} )); then
    builtin compadd "$@"
    return $?
  fi
  local -a hits descriptions
  if (( ${+opts[d]} )); then
    if [[ ${opts[d]} == \(* ]]; then
      eval "descriptions=${opts[d]}"
    else
      descriptions=( "${(@P)opts[d]}" )
    fi
  fi
  builtin compadd -A hits -D descriptions "$@"
  local prefix="$IPREFIX${opts[P]-}${opts[p]-}" suffix="${opts[s]-}" terminator=' '
  (( ${+opts[S]} )) && terminator=${opts[S]}
  local quoted=1 file=0
  [[ $flags == *Q* ]] && quoted=0
  [[ $flags == *f* ]] && file=1
  local -i i
  local description kind
  for (( i = 1; i <= $#hits; i++ )); do
    description=${descriptions[i]-}
    # display strings look like "name  -- what it does"
    if [[ $description == (#b)(*[^ ])[[:space:]]##--[[:space:]]##(*) ]]; then
      description=$match[2]
    elif [[ $description == "$hits[i]" ]]; then
      description=
    fi
    kind=$terminator
    (( file )) && [[ -d $prefix$hits[i] ]] && kind=/
    print -rn -- $'\x1e'"$prefix$hits[i]$suffix"$'\x1f'"$description"$'\x1f'"$kind"$'\x1f'"$quoted"$'\x1f'"$file"$'\x1f'"${curtag-}"
  done
  (( $#hits ))
}

_turm_request() {
  local directory cursor line
  { IFS= read -r -d '' directory; IFS= read -r -d '' cursor; IFS= read -r -d '' line } < "$TURM_COMPLETION_REQUEST"
  builtin cd -q -- "$directory" 2>/dev/null
  BUFFER=$line
  CURSOR=$cursor
  print -rn -- $'\e]7778;B\a'
  zle _turm_complete 2>/dev/null
  print -rn -- $'\e]7778;E\a'
  BUFFER=''
  CURSOR=0
}
zle -C _turm_complete complete-word _main_complete
zle -N _turm_request
bindkey -e
bindkey '^X^T' _turm_request
print -rn -- $'\e]7778;R\a'
"""#

    /// Read by a hidden bash that answers completion requests.
    public static let bashCompletion = #"""
# Turm completion helper: answers NUL separated requests (directory, cursor, line) on stdin with the user's programmable completion.
unset HISTFILE
_turm_offer() {
  local word=$1 terminator=' '
  [[ -d $word ]] && terminator=/
  printf '\036%s\037%s\037%s\037%s\037%s\037' "$word" '' "$terminator" 1 1
}
_turm_complete() {
  local line=$1 cursor=$2 spec function cmd cur prev entry
  COMP_LINE=${line:0:cursor}
  COMP_POINT=${#COMP_LINE}
  COMP_WORDS=()
  read -r -a COMP_WORDS <<< "$COMP_LINE"
  [[ -z $COMP_LINE || $COMP_LINE == *[[:space:]] ]] && COMP_WORDS+=('')
  COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
  cmd=${COMP_WORDS[0]}
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=
  (( COMP_CWORD > 0 )) && prev=${COMP_WORDS[COMP_CWORD-1]}
  COMPREPLY=()
  if (( COMP_CWORD == 0 )); then
    while IFS= read -r entry; do COMPREPLY+=("$entry"); done < <(compgen -c -- "$cur" | sort -u)
  else
    spec=$(complete -p -- "$cmd" 2>/dev/null)
    if [[ -z $spec ]]; then
      if declare -F _comp_load >/dev/null 2>&1; then
        _comp_load -- "$cmd" >/dev/null 2>&1
      elif declare -F __load_completion >/dev/null 2>&1; then
        __load_completion "$cmd" >/dev/null 2>&1
      fi
      spec=$(complete -p -- "$cmd" 2>/dev/null)
    fi
    if [[ $spec =~ -F[[:space:]]+([^[:space:]]+) ]]; then
      function=${BASH_REMATCH[1]}
      "$function" "$cmd" "$cur" "$prev" >/dev/null 2>&1
    elif [[ -n $spec ]]; then
      spec=${spec#complete }
      spec=${spec% *}
      while IFS= read -r entry; do COMPREPLY+=("$entry"); done < <(eval "compgen $spec -- \"\$cur\"" 2>/dev/null)
    else
      while IFS= read -r entry; do COMPREPLY+=("$entry"); done < <(compgen -f -- "$cur")
    fi
  fi
  printf '\033]7778;B\007'
  for entry in "${COMPREPLY[@]}"; do _turm_offer "$entry"; done
  printf '\033]7778;E\007'
}
printf '\033]7778;R\007'
while IFS= read -r -d '' directory && IFS= read -r -d '' cursor && IFS= read -r -d '' line; do
  builtin cd -- "$directory" 2>/dev/null
  _turm_complete "$line" "$cursor"
done
"""#

    /// Read by a hidden fish that answers completion requests.
    public static let fishCompletion = #"""
# Turm completion helper: answers NUL separated requests (directory, cursor, line) on stdin with fish's own completion.
printf '\e]7778;R\a'
while read -lz directory; and read -lz cursor; and read -lz line
    builtin cd -- $directory 2>/dev/null
    printf '\e]7778;B\a'
    for entry in (complete -C -- (string sub -l $cursor -- $line))
        set -l parts (string split -m 1 \t -- $entry)
        set -l word $parts[1]
        set -l description ''
        set -q parts[2]; and set description $parts[2]
        set -l terminator ' '
        string match -q -- '*/' $word; and set terminator ''
        printf '\x1e%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f' $word $description $terminator 1 0
    end
    printf '\e]7778;E\a'
end
"""#

    public static let zsh: [(name: String, contents: String)] = [
        (".zshenv", """
        export TURM_INTEGRATION_DIR="$ZDOTDIR"
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        [[ -r "$_turm_home/.zshenv" ]] && source "$_turm_home/.zshenv"
        ZDOTDIR="$TURM_INTEGRATION_DIR"
        unset _turm_home

        """),
        (".zprofile", """
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        [[ -r "$_turm_home/.zprofile" ]] && source "$_turm_home/.zprofile"
        ZDOTDIR="$TURM_INTEGRATION_DIR"
        unset _turm_home

        """),
        (".zshrc", """
        _turm_home="${TURM_USER_ZDOTDIR:-$HOME}"
        HISTFILE="$_turm_home/.zsh_history"
        [[ -r "$_turm_home/.zshrc" ]] && source "$_turm_home/.zshrc"
        if [[ -n "$TURM_USER_ZDOTDIR" ]]; then
          ZDOTDIR="$TURM_USER_ZDOTDIR"
        else
          unset ZDOTDIR
        fi
        unset _turm_home TURM_USER_ZDOTDIR TURM_INTEGRATION_DIR
        if [[ -n $TURM_COMPLETION_HELPER ]]; then
          source "$TURM_COMPLETION_HELPER"
          return
        fi

        _turm_preexec() {
          _turm_ran=1
          printf '\\e]7777;C\\a'
        }
        _turm_report_env() {
          local name signature=
          for name in ${(k)parameters[(R)*export*]}; do
            case $name in
              PWD|OLDPWD|_|SHLVL) continue ;;
            esac
            signature+="$name=${(P)name}"$'\\0'
          done
          if [[ -n $_turm_env_sent && $signature == "$_turm_env_sent" ]]; then
            return
          fi
          _turm_env_sent=$signature
          local encoded
          encoded=$(command env -0 | command base64)
          encoded=${encoded//[$'\\n\\r']/}
          if (( ${#encoded} > 0 && ${#encoded} <= 262144 )); then
            printf '\\e]7777;E;%s\\a' "$encoded"
          fi
        }
        _turm_precmd() {
          local code=$?
          _turm_report_env
          # keys sent to a program that exited before reading them would land in the next command line
          while builtin read -t 0 -k 1 -s; do :; done
          if [[ -n $TURM_REMOTE ]]; then
            printf '\\e]7777;R;%s;%s;%s\\a' "$TURM_REMOTE" "${_turm_ran:+$code}" "$PWD"
          elif [[ -n $_turm_ran ]]; then
            printf '\\e]7777;P;%d;%s\\a' $code "$PWD"
          else
            printf '\\e]7777;P;;%s\\a' "$PWD"
          fi
          _turm_ran=
        }
        _turm_quiet() {
          PROMPT=''
          RPROMPT=''
        }
        PROMPT_EOL_MARK=''
        precmd_functions=(_turm_precmd $precmd_functions _turm_quiet)
        preexec_functions+=(_turm_preexec)
        if [[ -n $TURM_SSH_WRAPPER ]] && (( ! $+functions[ssh] && ! $+aliases[ssh] )); then
          ssh() { "$TURM_SSH_WRAPPER" "$@"; }
        fi
        if [[ -n $TURM_REMOTE ]]; then
          printf '\\e]7777;H;%s;zsh;%s@%s\\a' "$TURM_REMOTE" "${USER:-$(id -un)}" "${HOST:-$(hostname)}"
        fi
        _turm_quiet

        """),
    ]
}
