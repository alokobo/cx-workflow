#!/usr/bin/env bash
# =====================================================================================================
# sca-resolver-shim.sh — se pasa al cx CLI como --sca-resolver cuando el resultado YA existe
# =====================================================================================================
# El cx CLI invoca:  <sca-resolver> offline -s <src> -n <proyecto> -r <tmp>.json [params]
# y luego solo lee <tmp>.json para empaquetarlo como .cxsca-results.json (ast-cli: runScaResolver /
# addScaResults). Este shim copia el JSON precalculado por resolve.sh (o restaurado de cache) al -r
# solicitado: cero re-resolucion, cero descargas en el paso del scan.
# =====================================================================================================
set -euo pipefail
src="${CX_SCA_PRECOMPUTED:-}"
out=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-r|--resolver-result-path) out="${2:-}"; shift 2 ;;
		*) shift ;;
	esac
done
[[ -n "${out}" ]] || { echo "[cx-one][shim] el CLI no envio -r" >&2; exit 2; }
[[ -s "${src}" ]] || { echo "[cx-one][shim] CX_SCA_PRECOMPUTED vacio o inexistente: ${src}" >&2; exit 3; }
cp "${src}" "${out}"
echo "[cx-one][shim] resultado SCA precalculado entregado al CLI ($(wc -c < "${out}") bytes)"
