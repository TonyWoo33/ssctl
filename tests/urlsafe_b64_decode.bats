#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../functions/utils.sh"
}

@test "decodes url-safe subscription snippet" {
    run urlsafe_b64_decode "c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2Y0dGemMzZHZjbVJBWlhoaGJYQnNaUzVqYjIwNk5EUXo"
    [ "$status" -eq 0 ]
    [ "$output" = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmRAZXhhbXBsZS5jb206NDQz" ]
}

@test "strips whitespace before decoding" {
    encoded=$'c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2Y0dGemMzZHZjbVJBWlhoaGJYQnNaUzVqYjIwNk5EUXo\n  '
    run urlsafe_b64_decode "$encoded"
    [ "$status" -eq 0 ]
    [ "$output" = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmRAZXhhbXBsZS5jb206NDQz" ]
}

@test "fails when data cannot be decoded" {
    run urlsafe_b64_decode "invalid@@@"
    [ "$status" -ne 0 ]
}
