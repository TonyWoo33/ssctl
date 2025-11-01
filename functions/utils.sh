#!/usr/bin/env bash

# Helper for URL-safe base64 decoding
urlsafe_b64_decode(){
    local b64="$1"
    # Replace URL-safe chars with standard chars
    b64="${b64//_//}" # Remove padding
    b64="${b64//-/'+'}"
    b64="${b64//_/'/'}"
    # Add padding if needed
    case $(( ${#b64} % 4 )) in
        2) b64+="==" ;;
        3) b64+="=" ;;
    esac
    echo "$b64" | base64 -d 2>/dev/null || echo "$b64" | openssl base64 -d -A 2>/dev/null
}

# Helper for URL decoding
url_decode(){
    : "${*//%/\\x}"
    echo -e "${_//+/ }"
}

# Helper for URL encoding
url_encode(){
    local raw="$*"
    printf '%s' "$raw" | jq -sRr @uri
}

# Parse plugin-related query parameters from an ss:// URL query string.
# Usage: parse_plugin_params "query" plugin_var plugin_opts_var
parse_plugin_params(){
    local query="$1" out_plugin="$2" out_plugin_opts="$3"
    local plugin="" plugin_opts=""

    if [ -n "$query" ]; then
        local IFS='&'
        read -ra kv_pairs <<< "$query"
        for kv_pair in "${kv_pairs[@]}"; do
            [ -n "$kv_pair" ] || continue
            local key="${kv_pair%%=*}"
            local value=""
            if [[ "$kv_pair" == *=* ]]; then
                value="${kv_pair#*=}"
            fi
            value="$(url_decode "$value")"
            case "$key" in
                plugin)
                    plugin="${value%%;*}"
                    if [[ "$value" == *";"* ]]; then
                        plugin_opts="${value#*;}"
                    fi
                    ;;
                plugin_opts|plugin-opts)
                    if [ -n "$plugin_opts" ]; then
                        plugin_opts="${plugin_opts};${value}"
                    else
                        plugin_opts="$value"
                    fi
                    ;;
            esac
        done
    fi

    if [ -n "$out_plugin" ]; then
        printf -v "$out_plugin" '%s' "$plugin"
    fi
    if [ -n "$out_plugin_opts" ]; then
        printf -v "$out_plugin_opts" '%s' "$plugin_opts"
    fi
}
