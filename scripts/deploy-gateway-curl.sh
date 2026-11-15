#!/usr/bin/env bash
# Shared transport contract for every deploy-gateway request.
#
# The gateway lives on an untrusted multi-guest bridge. TLS encrypts payloads;
# the pinned SPKI authenticates the root broker even though its certificate is
# deliberately self-signed and private to this network.
#
# The endpoint is estate configuration, so this public repo never names it:
# DEPLOY_GATEWAY_URL comes from the bastion runner's environment, or from the
# gateway-url input of deploy-step / deploy.yml. Unset is refused like any
# other unusable endpoint.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo 'deploy-gateway-curl.sh must be sourced' >&2
  exit 2
fi

deploy_gateway_url=${DEPLOY_GATEWAY_URL:-}
readonly deploy_gateway_spki='sha256//jPu2mrBRf7Xw0N2KEcfknu81CiaLVLuvQutQEUl/KzM='
deploy_gateway_curl_args=()

case "$deploy_gateway_url" in
  '')
    echo 'deploy-gateway: DEPLOY_GATEWAY_URL is unset; the bastion runner (or the gateway-url input) must name the gateway endpoint' >&2
    return 78
    ;;
  http://127.0.0.1:*|http://localhost:*)
    # Hermetic local tests only. A non-loopback cleartext endpoint is refused.
    ;;
  https://*)
    deploy_gateway_curl_args=(
      --proto '=https'
      --tlsv1.2
      --insecure
      --pinnedpubkey "$deploy_gateway_spki"
    )
    ;;
  *)
    echo "deploy-gateway: refusing unauthenticated endpoint: $deploy_gateway_url" >&2
    return 78
    ;;
esac

deploy_gateway_curl() {
  command curl "${deploy_gateway_curl_args[@]}" "$@"
}
