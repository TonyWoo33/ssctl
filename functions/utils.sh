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
