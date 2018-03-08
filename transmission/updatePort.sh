#!/bin/bash

# Source our persisted env variables from container startup
. /etc/transmission/environment-variables.sh

# Settings
_TRANSMISSION_PASSWD_FILE="/config/transmission-credentials.txt"

readarray -t _TRANSMISSION_AUTH_CONFIG < "${_TRANSMISSION_PASSWD_FILE}"
_TRANSMISSION_USERNAME="${_TRANSMISSION_AUTH_CONFIG[0]}"
_TRANSMISSION_PASSWD="${_TRANSMISSION_AUTH_CONFIG[1]}"

if [[ "${TRANSMISSION_PERSIST_PIA_PORT_ID,,}" == "true" ]]; then
  ## Persist across image rebuilds.
  _PIA_CLIENT_ID_FILE="/config/pia_client_id"
else
  _PIA_CLIENT_ID_FILE="/etc/transmission/pia_client_id"
fi

_TRANSMISSION_SETTINGS_FILE="${TRANSMISSION_HOME}/settings.json"

#
# First get a port from PIA
#

function piaNewClientID {
  head -n 100 /dev/urandom | sha256sum | tr -d " -" | tee "${_PIA_CLIENT_ID_FILE}"
}

## Only read client id if file exists.
if [[ -f "${_PIA_CLIENT_ID_FILE}" ]]; then
  _PIA_CLIENT_ID="$(< "${_PIA_CLIENT_ID_FILE}")"
fi

if [[ -z "${_PIA_CLIENT_ID}" ]]; then
  echo "Generating new client id for PIA"
  _PIA_CLIENT_ID=$(piaNewClientID)
fi

# Get the port
_PORT_ASSIGNMENT_URL="http://209.222.18.222:2000/?client_id=${_PIA_CLIENT_ID}"

## Try registration url 5 times with 5 second delay between each try. Should help deal with delay beteen login and registration working.
_PIA_CURL_EXIT_CODE=255
_COUNTER=1
until (( _PIA_CURL_EXIT_CODE == 0 )) || (( _COUNTER == 5 )); do
  if (( _PIA_CURL_EXIT_CODE != 255)); then
    sleep 5
  fi
  _PIA_RESPONSE="$(curl --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -s -f "${_PORT_ASSIGNMENT_URL}")"
  _PIA_CURL_EXIT_CODE="$?"
  ((_COUNTER++))
done

if [[ -z "${_PIA_RESPONSE}" ]]; then
  echo "Port forwarding is already activated on this connection, has expired, or you are not connected to a PIA region that supports port forwarding"
fi

# Check for curl error (curl will fail on HTTP errors with -f flag)
if (( _PIA_CURL_EXIT_CODE != 0 )); then
  echo "curl encountered an error looking up new port: ${_PIA_CURL_EXIT_CODE}"
  if (( _PIA_CURL_EXIT_CODE == 7 )); then
    exit 64
  fi
  exit 1
fi

# Check for errors in PIA response
## TODO: Convert to builtin grep
_PIA_ERROR="$(echo "${_PIA_RESPONSE}" | grep -oE "\"error\".*\"")"
if [[ -n "${_PIA_ERROR}" ]]; then
  echo "PIA returned an error: ${_PIA_ERROR}"
  exit 1
fi

# Get new port, check if empty
## TODO: Convert to builtin grep
_PIA_NEW_PORT=$(echo "${_PIA_RESPONSE}" | grep -oE "[0-9]+")
if [[ -z "${_PIA_NEW_PORT}" ]]; then
  echo "Could not find new port from PIA"
  exit 1
fi
echo "Got new port ${_PIA_NEW_PORT} from PIA"

#
# Now, set port in Transmission
#

# Check if transmission remote is set up with authentication
_AUTH_ENABLED=$(grep 'rpc-authentication-required\"' "${_TRANSMISSION_SETTINGS_FILE}" | grep -oE 'true|false')
if [[ "${_AUTH_ENABLED}" == "true" ]]; then
  echo "transmission auth required"
  _TRANSMISSION_AUTH="--auth ${_TRANSMISSION_USERNAME}:${_TRANSMISSION_PASSWD}"
else
  echo "transmission auth not required"
  _TRANSMISSION_AUTH=""
fi

# get current listening port
_TRANSMISSION_PEER_PORT=$(transmission-remote ${_TRANSMISSION_AUTH} -si | grep Listenport | grep -oE '[0-9]+')
if (( _PIA_NEW_PORT != _TRANSMISSION_PEER_PORT )); then
  if [[ "${ENABLE_UFW}" == "true" ]]; then
    echo "Update UFW rules before changing port in Transmission"

    echo "denying access to ${_TRANSMISSION_PEER_PORT}"
    _UFW_RESP="$(ufw deny "${_TRANSMISSION_PEER_PORT}" 2>&1)"
    if (( $? != 0 )); then
      echo "${_UFW_RESP}"
    fi
    echo "allowing ${_PIA_NEW_PORT} through the firewall"
    _UFW_RESP="$(ufw allow "${_PIA_NEW_PORT}" 2>&1)"
    if (( $? != 0 )); then
      echo "${_UFW_RESP}"
    fi
  fi

  transmission-remote ${_TRANSMISSION_AUTH} -p "${_PIA_NEW_PORT}"

  echo "Checking port..."
  sleep 10
  transmission-remote ${_TRANSMISSION_AUTH} -pt
else
  echo "No action needed, port hasn't changed"
fi
