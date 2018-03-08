#!/bin/bash

/etc/transmission/start.sh "$@" && \
  /opt/tinyproxy/start.sh
