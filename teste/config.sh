#!/bin/sh
# Teste da config em Swift: compila o app com -D TESTE (o @main vira o de teste/config.swift) e roda. ~30 s.
cd "$(dirname "$0")/.." || exit 1
swiftc -swift-version 5 -parse-as-library -D TESTE FleetNotch.swift Ajustes.swift Assistente.swift Visual.swift teste/config.swift \
  -o "${TMPDIR:-/tmp}/frota-teste-config" && "${TMPDIR:-/tmp}/frota-teste-config"
