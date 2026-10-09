#!/usr/bin/env bash
# =====================================================================================================
# scan.sh — cx scan create (SAST + SCA) con el resultado SCA precalculado y zip minimo de SAST
# =====================================================================================================
# Modos de SCA (CX_RESOLUTION_MODE):
#   prebuilt  (default) resultado de resolve.sh o de la cache -> --sca-resolver sca-resolver-shim.sh
#   cli       el CLI ejecuta ScaResolver (comportamiento clasico; usar solo para depurar / delta scan)
#   server    sin resolver local: Checkmarx One resuelve los manifiestos del zip (solo deps publicas)
# Autenticacion por variables de entorno (CX_BASE_URI, CX_TENANT, CX_CLIENT_ID/CX_CLIENT_SECRET o
# CX_APIKEY): nunca en la linea de comandos (visible en ps / logs).
# =====================================================================================================
set -Eeuo pipefail
CX_STEP=scan
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib.sh"
state_load

SRC="${SOURCE_DIR:?}"
CX="${CX_BIN:?install-tools.sh cx debe ejecutarse antes}"
REPORT_DIR="${CX_REPORT_DIR:-${CX_WORK}/reports}"; mkdir -p "${REPORT_DIR}"
[[ -n "${CX_APIKEY:-}" || ( -n "${CX_CLIENT_ID:-}" && -n "${CX_CLIENT_SECRET:-}" ) ]] || die "Faltan credenciales: CX_APIKEY o CX_CLIENT_ID + CX_CLIENT_SECRET"
[[ -n "${CX_BASE_URI:-}" && -n "${CX_TENANT:-}" ]] || die "Faltan CX_BASE_URI / CX_TENANT"

mode="${CX_RESOLUTION_MODE:-prebuilt}"
setup_ca               # cx (Go) usa SSL_CERT_FILE: bundle combinado, igual en todos los caminos
if [[ "${mode}" == cli ]]; then
	load_secret_env      # el CLI ejecuta ScaResolver dentro de este proceso
else
	# la carpeta de configuracion generada no debe llegar al zip (en modo cli la necesita el resolver del CLI)
	[[ -n "${CFG_DIR_GENERATED:-}" && -f "${CFG_DIR_GENERATED}/.cx-one-generated" ]] && rm -rf "${CFG_DIR_GENERATED}"
fi

# ---------------------------------------------------------------- tipos de scan
types="${CX_SCAN_TYPES:-sast,sca}"
if [[ "${SCA_PRESENT:-false}" != true && ",${types}," == *,sca,* ]]; then
	types="$(echo ",${types}," | sed 's/,sca,/,/' | sed 's/^,//; s/,$//')"
	log "Sin manifiestos de dependencias: se omite SCA (scan-types=${types})"
fi
[[ -n "${types}" ]] || die "scan-types quedo vacio"

# ---------------------------------------------------------------- SCA
ARGS=()
if [[ ",${types}," == *,sca,* ]]; then
	result="${CX_SCA_RESULT_FILE:-${CX_WORK}/result/sca-result.json}"
	case "${mode}" in
		prebuilt)
			if [[ -s "${result}" ]]; then
				export CX_SCA_PRECOMPUTED="${result}"
				chmod +x "${HERE}/sca-resolver-shim.sh"
				ARGS+=(--sca-resolver "${HERE}/sca-resolver-shim.sh")
				log "SCA: resultado precalculado ($(wc -c < "${result}") bytes, origen: ${CX_SCA_RESULT_ORIGIN:-resolve})"
			else
				warn "SCA: no hay resultado de ScaResolver; Checkmarx One resolvera los manifiestos en el servidor (dependencias privadas no se veran)."
			fi ;;
		cli)
			[[ -n "${SCA_RESOLVER_BIN:-}" ]] || die "resolution-mode=cli requiere ScaResolver instalado"
			ARGS+=(--sca-resolver "${SCA_RESOLVER_BIN}")
			# parametros armados por "resolve.sh --prepare-only" (mismos que en modo prebuilt)
			[[ -n "${CLI_RESOLVER_PARAMS:-}" ]] && ARGS+=(--sca-resolver-params "${CLI_RESOLVER_PARAMS}") ;;
		server) log "SCA: resolucion en el servidor (sin ScaResolver)" ;;
		*) die "resolution-mode invalido: ${mode}" ;;
	esac
fi

# ---------------------------------------------------------------- SAST: zip minimo
# cx solo excluye por defecto .vs,.vscode,.idea,node_modules (y SI sube .git). Se excluye lo que no es
# codigo fuente: VCS, binarios, artefactos de build, minificados y media. Patron = nombre de archivo/carpeta.
DEFAULT_FILTER='!.git,!.cxsca.configurations,!dist,!build,!target,!obj,!coverage,!.gradle,!.venv,!venv,!__pycache__,!*.min.js,!*.map,!*.jar,!*.war,!*.ear,!*.class,!*.zip,!*.tgz,!*.gz,!*.whl,!*.exe,!*.dll,!*.so,!*.dylib,!*.png,!*.jpg,!*.jpeg,!*.gif,!*.ico,!*.svg,!*.pdf,!*.mp4,!*.woff,!*.woff2,!*.ttf'
filter="${CX_FILE_FILTER:-${DEFAULT_FILTER}}"
[[ -n "${CX_FILE_FILTER_EXTRA:-}" ]] && filter="${filter},${CX_FILE_FILTER_EXTRA}"
ARGS+=(--file-filter "${filter}")

# Incremental en PRs: SAST solo re-analiza lo cambiado (el CLI cae a full si no hay base)
inc="${CX_SAST_INCREMENTAL:-auto}"
if [[ ",${types}," == *,sast,* ]]; then
	if [[ "${inc}" == true || ( "${inc}" == auto && "${GITHUB_EVENT_NAME:-}" == pull_request* ) ]]; then ARGS+=(--sast-incremental); fi
	[[ -n "${CX_SAST_PRESET:-}" ]] && ARGS+=(--sast-preset-name "${CX_SAST_PRESET}")
fi

branch="${CX_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}}"
[[ -n "${CX_PROJECT_TAGS:-}" ]]   && ARGS+=(--project-tags "${CX_PROJECT_TAGS}")
[[ -n "${CX_PROJECT_GROUPS:-}" ]] && ARGS+=(--project-groups "${CX_PROJECT_GROUPS}")
[[ -n "${CX_APPLICATION:-}" ]]    && ARGS+=(--application-name "${CX_APPLICATION}")
[[ -n "${CX_SCAN_TIMEOUT:-}" ]]   && ARGS+=(--scan-timeout "${CX_SCAN_TIMEOUT}")
is_true "${CX_DEBUG:-false}"      && ARGS+=(--debug)
scan_tags="github_run:${GITHUB_RUN_ID:-local},event:${GITHUB_EVENT_NAME:-manual}"
[[ -n "${CX_SCAN_TAGS:-}" ]] && scan_tags="${scan_tags},${CX_SCAN_TAGS}"
# argumentos libres del YAML del workflow que llama (fuente confiable); eval respeta comillas
if [[ -n "${CX_EXTRA_SCAN_ARGS:-}" ]]; then declare -a extra=(); eval "extra=(${CX_EXTRA_SCAN_ARGS})"; ARGS+=("${extra[@]}"); fi

group "cx scan create (${types})"
log "proyecto=${CX_PROJECT_NAME} rama=${branch} sca=${mode}"
set +e
( cd "${SRC}" && "${CX}" scan create \
	--project-name "${CX_PROJECT_NAME:?}" \
	--branch "${branch}" \
	-s "${SRC}" \
	--scan-types "${types}" \
	--agent "GitHub Actions" \
	--tags "${scan_tags}" \
	--report-format "${CX_REPORT_FORMATS:-json,sarif,markdown,summaryHTML}" \
	--output-path "${REPORT_DIR}" \
	--output-name cx_result \
	"${ARGS[@]}" ) 2>&1 | tee "${REPORT_DIR}/cx-console.log"
rc=${PIPESTATUS[0]}
set -e
endgroup

json="${REPORT_DIR}/cx_result.json"
scan_id=""
[[ -f "${json}" ]] && scan_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("scanID",""))' "${json}" 2>/dev/null || true)"
set_output scan_id "${scan_id}"
set_output report_dir "${REPORT_DIR}"
set_output cx_exit_code "${rc}"
[[ -f "${REPORT_DIR}/cx_result.md" ]] && cat "${REPORT_DIR}/cx_result.md" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[[ -n "${scan_id}" && -n "${CX_BASE_URI:-}" ]] && echo "Scan: ${CX_BASE_URI%/}/projects/ (scanID ${scan_id})" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [[ ${rc} -ne 0 ]]; then
	if [[ -f "${json}" ]]; then
		# el resultado (incluida la decision de "Break Build") lo define Checkmarx One; ver cx-console.log
		err "cx termino con exit ${rc}. Detalle en cx-console.log (artifact) y en Checkmarx One."
	else
		err "cx termino con exit ${rc} sin reportes (credenciales, red o error del scan). Reintentar con debug=true."
	fi
	exit "${rc}"
fi
log "Scan completado: ${scan_id}"
