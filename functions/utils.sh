#!/usr/bin/env bash

urlsafe_b64_decode(){
    local b64
    b64=$(printf '%s' "$1" | tr -d '\r\n ' | tr -- '-_' '+/')
    # Add padding if needed
    case $(( ${#b64} % 4 )) in
        2) b64+="==" ;;
        3) b64+="=" ;;
    esac
    if printf '%s' "$b64" | base64 -d 2>/dev/null; then
        return 0
    fi
    if printf '%s' "$b64" | openssl base64 -d -A 2>/dev/null; then
        return 0
    fi
    return 1
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
