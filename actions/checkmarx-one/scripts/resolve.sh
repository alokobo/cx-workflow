#!/usr/bin/env bash
# =====================================================================================================
# resolve.sh — UNA ejecucion de ScaResolver (offline) para TODOS los ecosistemas, con logs visibles.
# =====================================================================================================
# Por que fuera del cx CLI: "cx scan create --sca-resolver" ejecuta exactamente
#     ScaResolver offline -s <src> -n <proyecto> -r <tmp>.json <sca-resolver-params>
# descarta stderr (y stdout salvo --debug) y solo empaqueta el JSON como .cxsca-results.json.
# Ejecutarlo aqui da: (1) el log real en el job, (2) resumen por manifiesto, (3) el JSON reutilizable
# por fingerprint (cache) y (4) entregarlo al CLI con sca-resolver-shim.sh sin resolver dos veces.
#
# No hay pre-instalacion (npm ci / pip install / gradle dependencies / dotnet restore): ScaResolver ya
# invoca al gestor y, con lockfile, solo lo parsea. Esa era la doble descarga del esquema anterior.
#
# Salidas: result_file, cacheable (true si TODOS los manifiestos resolvieron), resolved_deps, failed
# =====================================================================================================
set -Eeuo pipefail
CX_STEP=resolve
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
state_load
load_secret_env
setup_ca

# --prepare-only (resolution-mode=cli): misma preparacion y parametros, pero ScaResolver lo ejecuta el
# cx CLI. Las reescrituras quedan aplicadas hasta cleanup.sh (el CLI resuelve dentro de scan create).
PREPARE_ONLY=false; [[ "${1:-}" == --prepare-only ]] && PREPARE_ONLY=true
SRC="${SOURCE_DIR:?}"
RESOLVER="${SCA_RESOLVER_BIN:?install-tools.sh resolver debe ejecutarse antes}"
RESULT_DIR="${CX_WORK}/result"; RESULT="${RESULT_DIR}/sca-result.json"
LOG_DIR="${CX_WORK}/sca-logs"; CONSOLE_LOG="${LOG_DIR}/scaresolver-console.log"
BACKUP_DIR="${CX_WORK}/backup"
rm -rf "${BACKUP_DIR}"   # backups de una corrida anterior ya fueron restaurados (trap/cleanup)
mkdir -p "${RESULT_DIR}" "${LOG_DIR}" "${BACKUP_DIR}"
rm -f "${RESULT}"

# ---------------------------------------------------------------- reescrituras TEMPORALES (siempre se restauran)
# Solo cuando hace falta: hosts legados en manifiestos (requirements --index-url, .npmrc del repo) y la
# distribucion del wrapper de Gradle. Se restauran en el trap, ANTES de que cx comprima el codigo.
RESTORE_LIST="${BACKUP_DIR}/restore.list"; : > "${RESTORE_LIST}"
backup_once() { local f="$1" b; b="${BACKUP_DIR}/$(rel "$f" | tr '/' '%')"; [[ -f "${b}" ]] || { cp -p "${f}" "${b}"; printf '%s\t%s\n' "${b}" "${f}" >> "${RESTORE_LIST}"; }; }
# shellcheck disable=SC2329  # invocada por trap EXIT (en --prepare-only la restauracion la hace cleanup.sh)
restore_all() {
	local b f
	while IFS=$'\t' read -r b f; do [[ -f "${b}" ]] && cp -p "${b}" "${f}" && rm -f "${b}"; done < "${RESTORE_LIST}"
	: > "${RESTORE_LIST}"
	# carpeta de configuracion generada: fuera ANTES del zip de SAST (aunque no tenga secretos)
	[[ -n "${CFG_DIR_GENERATED:-}" && -f "${CFG_DIR_GENERATED}/.cx-one-generated" ]] && rm -rf "${CFG_DIR_GENERATED}"
	# (node_modules creado para React Native no viaja: cx excluye node_modules por defecto)
	return 0
}
[[ "${PREPARE_ONLY}" == true ]] || trap restore_all EXIT

rewrite_hosts() {
	[[ -n "${CX_LEGACY_HOSTS:-}" ]] || return 0
	local pairs p from to f
	IFS=',' read -r -a pairs <<< "${CX_LEGACY_HOSTS}"
	while IFS= read -r f; do
		case "$(basename "${f}")" in requirements*.txt|requirement*.txt|.npmrc|.yarnrc|.yarnrc.yml|gradle-wrapper.properties|settings.xml) ;; *) continue ;; esac
		for p in "${pairs[@]}"; do
			p="${p//[[:space:]]/}"; from="${p%%=*}"; to="${p#*=}"
			[[ -n "${from}" && -n "${to}" && "${from}" != "${to}" ]] || continue
			if grep -q "${from}" "${f}"; then backup_once "${f}"; sed -i "s|${from}|${to}|g" "${f}"; log "host ${from} -> ${to} en $(rel "${f}") (temporal)"; fi
		done
	done < "${CX_WORK}/manifests.list"
}

rewrite_gradle_dist() {  # distributionUrl -> Artifactory (generic remote de services.gradle.org)
	[[ -n "${CX_GRADLE_DIST_BASE_URL:-}" ]] || return 0
	local f base="${CX_GRADLE_DIST_BASE_URL%/}"
	while IFS= read -r f; do
		[[ "$(basename "${f}")" == gradle-wrapper.properties ]] || continue
		grep -q 'services\.gradle\.org' "${f}" || continue
		backup_once "${f}"
		sed -i -E "s#^(distributionUrl=).*/(gradle-[^/]+\.zip)\$#\1${base//:/\\:}/\2#" "${f}"
		log "distributionUrl de $(rel "${f}") -> ${base} (temporal)"
	done < "${CX_WORK}/manifests.list"
}

# React Native / Expo: settings.gradle hace includeBuild(node_modules/@react-native/gradle-plugin). Sin ese
# directorio Gradle ni siquiera evalua el proyecto. Es el UNICO caso que requiere instalar JS, y se hace con
# node-linker=hoisted (pnpm) para que el plugin quede en la ruta que espera settings.gradle (sin symlinks).
prepare_react_native() {
	is_true "${CX_REACT_NATIVE_SUPPORT:-true}" || return 0
	local s dir root mgr
	while IFS= read -r s; do
		[[ "$(basename "${s}")" == settings.gradle* ]] || continue
		grep -qE 'node_modules/@react-native/gradle-plugin|react-native-gradle-plugin|com\.facebook\.react\.settings' "${s}" || continue
		dir="$(dirname "${s}")"; root="${dir}"
		while [[ "${root}" != "/" ]]; do
			[[ -f "${root}/pnpm-lock.yaml" ]] && { mgr=pnpm; break; }
			[[ -f "${root}/yarn.lock" ]] && { mgr=yarn; break; }
			[[ -f "${root}/package-lock.json" ]] && { mgr=npm; break; }
			[[ "${root}" == "${SRC}" ]] && { mgr=npm; break; }
			root="$(dirname "${root}")"
		done
		[[ -d "${root}/node_modules/@react-native/gradle-plugin" || -d "${root}/node_modules/react-native-gradle-plugin" ]] && continue
		log "React Native en $(rel "${dir}"): instalando dependencias JS (${mgr}, sin scripts) en $(rel "${root}")"
		case "${mgr}" in
			pnpm) (cd "${root}" && run_timeout 15m corepack pnpm install --frozen-lockfile --ignore-scripts --config.node-linker=hoisted --prefer-offline) ;;
			yarn) (cd "${root}" && run_timeout 15m yarn install --frozen-lockfile --ignore-scripts --prefer-offline 2>/dev/null || run_timeout 15m yarn install --immutable --mode=skip-build) ;;
			*)    (cd "${root}" && run_timeout 15m npm ci --ignore-scripts --prefer-offline --no-audit --no-fund) ;;
		esac || warn "No se pudieron instalar dependencias JS para $(rel "${dir}"); Gradle no podra evaluar settings.gradle."
		# Android: AGP exige un SDK para configurar; licencias aceptadas + ANDROID_HOME minimo
		if [[ -z "${ANDROID_HOME:-}" ]]; then
			export ANDROID_HOME="${CX_CACHE:-${HOME}/.cache/cx-one}/android-sdk"; export ANDROID_SDK_ROOT="${ANDROID_HOME}"
			mkdir -p "${ANDROID_HOME}/licenses"
			printf '\n24333f8a63b6825ea9c5514f83c2829b004d1fee\n8933bad161af4178b1185d1a37fbf41ea5269c55\nd56f5187479451eabf01fb78af6dfcb131a6481e\n' > "${ANDROID_HOME}/licenses/android-sdk-license"
		fi
	done < "${CX_WORK}/manifests.list"
}

# ---------------------------------------------------------------- parametros de ScaResolver
build_params() {
	PARAMS=(--log-level "${CX_RESOLVER_LOG_LEVEL:-Debug}" --logs-path "${LOG_DIR}")
	[[ -n "${CX_RESOLVER_TIMEOUT:-}" ]] && PARAMS+=(--resolver-timeout "${CX_RESOLVER_TIMEOUT}")
	[[ -n "${NETRC_FILE:-}" ]] && PARAMS+=(--netrc-path "${NETRC_FILE}")
	if [[ ",${ECOSYSTEMS}," == *,pip,* || ",${ECOSYSTEMS}," == *,uv,* ]]; then
		PARAMS+=(--python-version V3)
		[[ "${CX_PYTHON_PACKAGE_MANAGER:-pip}" == uv ]] && PARAMS+=(--python-package-manager uv)
	fi
	is_true "${CX_IGNORE_DEV_DEPS:-false}" && PARAMS+=(--ignore-dev-dependencies --ignore-test-dependencies)
	is_true "${CX_STRICT:-false}" && PARAMS+=(--break-on-manifest-failure)
	[[ -n "${CX_RESOLVER_EXCLUDES:-}" ]] && PARAMS+=(--excludes "${CX_RESOLVER_EXCLUDES}")
	# Parametros libres del usuario (p.ej. --gradle-exclude-scopes testCompileClasspath --maven-parameters "-P ci").
	# Vienen del YAML del workflow que llama (fuente confiable, no del contenido del PR); eval respeta comillas.
	if [[ -n "${CX_RESOLVER_EXTRA_PARAMS:-}" ]]; then
		local -a extra; eval "extra=(${CX_RESOLVER_EXTRA_PARAMS})"; PARAMS+=("${extra[@]}")
	fi
}

# ---------------------------------------------------------------- ejecucion
rewrite_hosts
rewrite_gradle_dist
[[ ",${ECOSYSTEMS}," == *,gradle,* ]] && prepare_react_native
build_params

if [[ "${PREPARE_ONLY}" == true ]]; then
	# el cx CLI parte --sca-resolver-params por espacios respetando comillas simples/dobles (parseArgs)
	cli=""; for a in "${PARAMS[@]}"; do [[ "${a}" =~ [[:space:]] ]] && a="\"${a}\""; cli+="${a} "; done
	state_set CLI_RESOLVER_PARAMS "${cli% }"
	log "Preparado para resolution-mode=cli: --sca-resolver-params '${cli% }'"
	exit 0
fi

group "ScaResolver offline (${ECOSYSTEMS})"
log "${RESOLVER} offline -s ${SRC} -n ${CX_PROJECT_NAME} -r ${RESULT} ${PARAMS[*]}"
start=$(date +%s); set +e
( cd "${SRC}" && run_timeout "${CX_RESOLVE_JOB_TIMEOUT:-45m}" "${RESOLVER}" offline -s "${SRC}" -n "${CX_PROJECT_NAME:?}" -r "${RESULT}" "${PARAMS[@]}" ) \
	> "${CONSOLE_LOG}" 2>&1
rc=$?; set -e
elapsed=$(( $(date +%s) - start ))
# Consola filtrada: lo util sin las miles de lineas Debug (el log completo queda como artifact)
grep -E 'Resolved [0-9]+ dependencies|Finished project scan|Error|ERROR|Failed|WARN|Warning|PrerequisiteFailed|No module named|SDK location|Could not resolve|E401|E403|401|403' \
	"${CONSOLE_LOG}" | grep -v 'Executing process' | tail -n 200 || true
endgroup

# ---------------------------------------------------------------- resumen por manifiesto
declare -a ROWS=() FAILED=()
total_deps=0
while IFS= read -r line; do
	if [[ "${line}" =~ Resolved\ ([0-9]+)\ dependencies\ for\ file\ (.+)\.\ \[Status=([A-Za-z]+)\] ]]; then
		n="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[2]}"; st="${BASH_REMATCH[3]}"
		f="${f#"${SRC}"/}"
		ROWS+=("| \`${f}\` | ${n} | ${st} |")
		total_deps=$(( total_deps + n ))
		# estados de error observados: PrerequisiteFailed, FailedToResolve, ... (cualquier *Fail*/Error/Timeout)
		[[ "${st}" =~ (Fail|Error|Timeout|Missing|Unsupported) ]] && FAILED+=("${f} [${st}]")
	fi
done < "${CONSOLE_LOG}"
finished="$(grep -Eo 'Finished project scan - \[dependencies=[0-9]+, files analyzed=[0-9]+\]' "${CONSOLE_LOG}" | tail -n1 || true)"

{
	echo "### Checkmarx One · resolucion SCA (${elapsed}s, exit ${rc})"
	if [[ ${#ROWS[@]} -gt 0 ]]; then echo "| Manifiesto | Dependencias | Estado |"; echo "|---|---|---|"; printf '%s\n' "${ROWS[@]}"; fi
	[[ -n "${finished}" ]] && echo "" && echo "\`${finished}\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

grep -q 'No module named virtualenv' "${CONSOLE_LOG}" && err "ScaResolver no pudo crear el virtualenv: falta el modulo 'virtualenv' en el python del runner."
grep -q 'SDK location not found' "${CONSOLE_LOG}" && warn "Proyecto Android sin SDK: definir ANDROID_HOME en la imagen del runner."

ok=false; [[ ${rc} -eq 0 && -s "${RESULT}" ]] && ok=true
cacheable=false; [[ "${ok}" == true && ${#FAILED[@]} -eq 0 ]] && cacheable=true

if [[ ${#FAILED[@]} -gt 0 ]]; then
	warn "Manifiestos sin resolver (${#FAILED[@]}): ${FAILED[*]}. Revisa el artifact cx-one-reports/sca-logs; el resultado NO se cachea."
fi
if [[ "${ok}" != true ]]; then
	msg="ScaResolver termino con exit ${rc} y/o sin resultado (${elapsed}s)."
	if is_true "${CX_STRICT:-false}"; then tail -n 60 "${CONSOLE_LOG}" >&2; die "${msg}"; fi
	warn "${msg} El scan continua: Checkmarx One analizara los manifiestos del zip en el servidor (sin dependencias privadas)."
fi

log "Resultado: ${RESULT} · dependencias=${total_deps} · manifiestos con error=${#FAILED[@]} · cacheable=${cacheable}"
state_set SCA_RESULT_OK "${ok}"
set_output result_file "${RESULT}"
set_output resolved "${ok}"
set_output cacheable "${cacheable}"
set_output resolved_deps "${total_deps}"
exit 0
